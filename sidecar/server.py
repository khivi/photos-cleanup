"""Local server: serves the built UI (./dist) and the API on 127.0.0.1.

Wraps the photo_cleanup engine; the UI is same-origin, so no CORS.
ponytail: single cached PhotosDB + photo index — the load is slow (seconds on a
big library) so we do it once; restart the server to pick up library changes.

The engine (photo_cleanup) is vendored in-repo — see CLAUDE.md.
"""

from __future__ import annotations

import argparse
import functools
import hashlib
import json
import subprocess
import tempfile
import threading
import webbrowser
from datetime import UTC, datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from photo_cleanup import common

# Per-pass album names (engine convention: end with "Delete Me" / "Review Me").
ALBUMS = {
    "screenshots": "Screenshots - Delete Me",
    "low-quality": "Low Quality - Review Me",
}
# Not in common.CLEANUP_ALBUM_NAMES, so they count as user albums and the candidate
# filter skips their photos on every later run.
KEEP_ALBUMS = {
    "screenshots": "Screenshots - Keep",
    "low-quality": "Low Quality - Keep",
}

CACHE_DIR = Path.home() / "Library/Caches/photos-cleanup"
VERDICT_SRC = Path(__file__).with_name("verdict.swift")
# Keyed to the helper's source, so a prompt or kind-list change re-judges everything.
VERDICT_CACHE = f"verdicts-{hashlib.sha256(VERDICT_SRC.read_bytes()).hexdigest()[:8]}.jsonl"

app = FastAPI(title="photos-cleanup")
# Blocks DNS rebinding: an attacker domain resolved to 127.0.0.1 would otherwise be same-origin.
app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost"])

_MIN = datetime.min.replace(tzinfo=UTC)


@functools.lru_cache(maxsize=1)
def db():
    return common.get_photosdb()


# The cached PhotosDB never sees album changes, so committed photos are tracked here.
_committed: set[str] = set()
_classify: dict = {"pending": 0, "error": None}
_classify_lock = threading.Lock()
_classifier: threading.Thread | None = None


@functools.lru_cache(maxsize=1)
def _verdicts() -> dict[str, dict]:
    """uuid -> {keep, kind, reason}, persisted so each screenshot is judged once."""
    f = CACHE_DIR / VERDICT_CACHE
    out: dict[str, dict] = {}
    if f.exists():
        for line in f.read_text().splitlines():
            v = json.loads(line)
            out[v.pop("uuid")] = v
    return out


def _parse_verdict(line: str) -> tuple[str, dict | None]:
    """One verdict.swift output line -> (uuid, verdict); None for errors (retried next run)."""
    uuid, _, rest = line.partition("\t")
    fields = rest.split("\t")
    if fields == ["SKIP"]:
        return uuid, {"keep": True, "kind": "picture", "reason": "Not a utility image"}
    if len(fields) != 3 or fields[0] == "ERR":
        return uuid, None
    kind, keep, reason = fields
    return uuid, {"keep": keep == "1", "kind": kind, "reason": reason}


def _image_path(p) -> str | None:
    return p.path or (p.path_derivatives[0] if p.path_derivatives else None)


def _verdict_bin() -> Path:
    exe = CACHE_DIR / "verdict"
    if not exe.exists() or exe.stat().st_mtime < VERDICT_SRC.stat().st_mtime:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["swiftc", "-O", str(VERDICT_SRC), "-o", str(exe)], check=True, capture_output=True
        )
    return exe


def _run_classifier(photos) -> None:
    verdicts = _verdicts()
    try:
        exe = _verdict_bin()
        # Temp files, not pipes, for stdin/stderr: a full pipe would deadlock the child.
        with (
            tempfile.TemporaryFile("w+") as inp,
            tempfile.TemporaryFile("w+") as err,
            (CACHE_DIR / VERDICT_CACHE).open("a") as cache,
        ):
            for p in photos:
                date = p.date.date().isoformat() if p.date else "unknown"
                inp.write(f"{p.uuid}\t{_image_path(p)}\t{date}\n")
            inp.seek(0)
            proc = subprocess.Popen([exe], stdin=inp, stdout=subprocess.PIPE, stderr=err, text=True)
            for line in proc.stdout:
                uuid, v = _parse_verdict(line.rstrip("\n"))
                if v is not None:
                    verdicts[uuid] = v
                    cache.write(json.dumps({"uuid": uuid, **v}) + "\n")
                    cache.flush()
                _classify["pending"] -= 1
            if proc.wait() != 0:
                err.seek(0)
                _classify["error"] = err.read().strip()[-300:] or f"exit {proc.returncode}"
    except subprocess.CalledProcessError as e:
        _classify["error"] = f"swiftc failed: {e.stderr.decode()[-300:]}"
    except OSError as e:
        _classify["error"] = str(e)
    finally:
        _classify["pending"] = 0


def _start_classifier(photos) -> None:
    global _classifier
    with _classify_lock:
        if _classifier is not None and _classifier.is_alive():
            return
        todo = [p for p in photos if p.uuid not in _verdicts() and _image_path(p)]
        if not todo:
            return
        _classify.update(pending=len(todo), error=None)
        _classifier = threading.Thread(target=_run_classifier, args=(todo,), daemon=True)
        _classifier.start()


@functools.lru_cache(maxsize=1)
def _index():
    """Newest-first photo list + uuid lookup, built once."""
    photos = db().photos()
    photos.sort(key=lambda p: common.make_aware(p.date) if p.date else _MIN, reverse=True)
    return photos, {p.uuid: p for p in photos}


def _meta(p) -> dict:
    return {
        "uuid": p.uuid,
        "filename": p.original_filename,
        "width": p.width,
        "height": p.height,
        "date": p.date.isoformat() if p.date else None,
        "is_video": p.ismovie,
        "size": p.original_filesize,
    }


@app.get("/health")
def health() -> dict:
    return {"ok": True}


@app.get("/stats")
def stats() -> dict:
    photos = db().photos()
    total_bytes = sum(p.original_filesize or 0 for p in photos)
    return {"count": len(photos), "size_gb": round(total_bytes / 1024**3, 1)}


@app.get("/photos")
def photos() -> dict:
    items, _ = _index()
    return {"total": len(items), "photos": [_meta(p) for p in items]}


@app.get("/thumb/{uuid}")
def thumb(uuid: str):
    _, by_uuid = _index()
    p = by_uuid.get(uuid)
    if p is None or not p.path_derivatives:
        raise HTTPException(status_code=404)
    # path_derivatives[-1] is the smallest derivative — right size for a grid thumb.
    return FileResponse(p.path_derivatives[-1])


@app.get("/cleanup/{kind}")
def cleanup(kind: str, threshold: float = 0.01) -> dict:
    """Run a cleanup pass and return its candidate photos (newest-first)."""
    photosdb = db()
    ignore = common.load_ignore_albums(None)
    if kind == "screenshots":
        photos, _ = common.get_candidate_photos(photosdb, ignore, only_screenshots=True)
    elif kind == "low-quality":
        photos, _ = common.get_candidate_photos(photosdb, ignore)
        photos = [
            p for p in photos if (s := common.get_photo_score(p)) is not None and s <= threshold
        ]
    else:
        raise HTTPException(status_code=404, detail="unknown cleanup kind")
    # Album membership comes from the startup snapshot; _committed covers this session's commits.
    filed = {ALBUMS[kind], KEEP_ALBUMS[kind]}
    photos = [p for p in photos if p.uuid not in _committed and filed.isdisjoint(p.albums)]
    photos.sort(key=lambda p: common.make_aware(p.date) if p.date else _MIN, reverse=True)
    verdicts: dict[str, dict] = {}
    classify = {"pending": 0, "error": None}
    if kind == "screenshots":
        _start_classifier(photos)
        verdicts, classify = _verdicts(), dict(_classify)
    return {
        "kind": kind,
        "count": len(photos),
        "photos": [{**_meta(p), "verdict": verdicts.get(p.uuid)} for p in photos],
        "classify": classify,
    }


class CommitReq(BaseModel):
    kind: str
    uuids: list[str] = []
    keep: list[str] = []


@app.post("/commit")
def commit(req: CommitReq) -> dict:
    """File photos into this pass's Delete Me (uuids) and Keep (keep) albums. Never deletes."""
    album, keep_album = ALBUMS.get(req.kind), KEEP_ALBUMS.get(req.kind)
    if album is None or keep_album is None:
        raise HTTPException(status_code=404, detail="unknown cleanup kind")
    _, by_uuid = _index()
    doomed = [by_uuid[u] for u in req.uuids if u in by_uuid]
    kept = [by_uuid[u] for u in req.keep if u in by_uuid]
    if not doomed and not kept:
        raise HTTPException(status_code=400, detail="no matching photos")
    for photos, name in ((doomed, album), (kept, keep_album)):
        if photos:
            # assume_yes: no TTY here, the GUI already confirmed. Append: replacing
            # would drop earlier commits from the album.
            common.add_to_album(photos, name, assume_yes=True, replace=False)
    _committed.update(p.uuid for p in doomed + kept)
    return {"added": len(doomed), "album": album, "kept": len(kept), "keep_album": keep_album}


# Mounted last so the API routes above win; absent in dev (Vite serves the UI).
DIST = Path(__file__).resolve().parent.parent / "dist"
if DIST.is_dir():
    app.mount("/", StaticFiles(directory=DIST, html=True), name="ui")


def main() -> None:
    import uvicorn

    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    url = f"http://127.0.0.1:{args.port}/"
    print(url)
    if not args.no_browser:
        threading.Timer(1.0, webbrowser.open, args=[url]).start()
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
