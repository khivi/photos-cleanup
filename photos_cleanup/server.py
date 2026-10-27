"""Local server: serves the built UI (./ui) and the API on 127.0.0.1.

Wraps the photo_cleanup engine; the UI is same-origin, so no CORS.
ponytail: single cached PhotosDB + photo index — the load is slow (seconds on a
big library) so we do it once; restart the server to pick up library changes.

The engine (photo_cleanup) is vendored in-repo — see CLAUDE.md.
"""

from __future__ import annotations

import base64
import functools
import hashlib
import json
import math
import subprocess
import tempfile
import threading
from array import array
from datetime import UTC, datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from photo_cleanup import common
from photo_cleanup.cleanups.clusters import _score_for_sort

CLUSTER_WINDOW_S = 60  # the clusters cleanup's default
# Feature-print L2 distance below which two neighbouring shots count as repeats. Calibrated
# by eye on 40 real bursts: pairs <= 0.44 were the same shot; from 0.46 they were different
# photos (report pages, a different person, different medicine labels).
SIMILAR_MAX_DIST = 0.45

# Per-pass album names (engine convention: end with "Delete Me" / "Review Me").
ALBUMS = {
    "screenshots": "Screenshots - Delete Me",
    "low-quality": "Low Quality - Review Me",
    "utility": "Utility - Delete Me",
    "clusters": "Bursts - Delete Me",
}
# Not in common.CLEANUP_ALBUM_NAMES, so they count as user albums and the candidate
# filter skips their photos on every later run.
KEEP_ALBUMS = {
    "screenshots": "Screenshots - Keep",
    "low-quality": "Low Quality - Keep",
    "utility": "Utility - Keep",
    "clusters": "Bursts - Keep",
}
# Passes judged by the Foundation Models classifier (see verdict.swift).
VERDICT_KINDS = {"screenshots", "utility"}

UI_DIR = Path(__file__).with_name("ui")
CACHE_DIR = Path.home() / "Library/Caches/photos-cleanup"
VERDICT_SRC = Path(__file__).with_name("verdict.swift")
FEATUREPRINT_SRC = Path(__file__).with_name("featureprint.swift")
DECISIONS_LOG = "decisions.jsonl"  # user's final keep/delete per committed verdict photo
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
_classify: dict = {"pending": 0, "total": 0, "error": None}  # total: this run, for progress
_classify_lock = threading.Lock()
_classifier: threading.Thread | None = None
_queue: list = []  # photos waiting for the classifier thread, across passes
_inflight: set[str] = set()  # uuids queued or being judged; "pending" is its size
# Set at startup when the classifier can't run here; shown in the UI instead of verdicts.
_verdicts_off: str | None = None


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


def _pass_verdict(kind: str, v: dict | None) -> dict | None:
    """The verdict as a pass should use it."""
    # Real screenshots have their own pass, so in Utility "screenshot" is always a misread
    # camera photo (a hand, a dashboard); never preselect those for delete.
    if v is not None and kind == "utility" and v["kind"] == "screenshot" and not v["keep"]:
        return {**v, "keep": True}
    return v


def _parse_verdict(line: str) -> tuple[str, dict | None]:
    """One verdict.swift output line -> (uuid, verdict); None for errors (retried next run)."""
    uuid, _, rest = line.partition("\t")
    fields = rest.split("\t")
    if len(fields) != 3 or fields[0] == "ERR":
        return uuid, None
    kind, keep, reason = fields
    return uuid, {"keep": keep == "1", "kind": kind, "reason": reason}


def _image_path(p) -> str | None:
    return p.path or (p.path_derivatives[0] if p.path_derivatives else None)


def _swift_bin(src: Path) -> Path:
    exe = CACHE_DIR / src.stem
    if not exe.exists() or exe.stat().st_mtime < src.stat().st_mtime:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", str(src), "-o", str(exe)], check=True, capture_output=True)
    return exe


# ponytail: in-memory only; ~1.3k prints take ~10s, so a restart recomputes them.
_prints: dict[str, array | None] = {}  # None: a utility image, never grouped


def _feature_prints(photos) -> dict[str, array | None]:
    """uuid -> Vision feature print (None for utility images), computed for uncached photos."""
    todo = [p for p in photos if p.uuid not in _prints]
    # Smallest-first derivative: fast, and what SIMILAR_MAX_DIST was calibrated on.
    lines = [
        f"{p.uuid}\t{path}\n"
        for p in todo
        if (path := (p.path_derivatives[0] if p.path_derivatives else p.path))
    ]
    if lines:
        out = subprocess.run(
            [_swift_bin(FEATUREPRINT_SRC)], input="".join(lines), capture_output=True, text=True
        )
        for line in out.stdout.splitlines():
            uuid, kind, *data = line.split("\t", 2)
            if kind == "UTILITY":
                _prints[uuid] = None
            elif kind in ("1", "2"):
                _prints[uuid] = array("f" if kind == "1" else "d", base64.b64decode(data[0]))
    return _prints


def _split_similar(group: list, prints: dict[str, array | None]) -> list[list]:
    """Split a time-sorted burst wherever neighbouring shots stop looking alike."""
    runs, run = [], [group[0]]
    for a, b in zip(group, group[1:], strict=False):
        pa, pb = prints.get(a.uuid), prints.get(b.uuid)
        if pa is not None and pb is not None and math.dist(pa, pb) < SIMILAR_MAX_DIST:
            run.append(b)
        else:
            runs.append(run)
            run = [b]
    runs.append(run)
    return [r for r in runs if len(r) >= 2]


def _run_classifier(photos) -> None:
    verdicts = _verdicts()
    try:
        exe = _swift_bin(VERDICT_SRC)
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
                with _classify_lock:
                    _inflight.discard(uuid)
                    _classify["pending"] = len(_inflight)
            if proc.wait() != 0:
                err.seek(0)
                _classify["error"] = err.read().strip()[-300:] or f"exit {proc.returncode}"
    except subprocess.CalledProcessError as e:
        _classify["error"] = f"swiftc failed: {e.stderr.decode()[-300:]}"
    except OSError as e:
        _classify["error"] = str(e)
    finally:
        with _classify_lock:
            _inflight.difference_update(p.uuid for p in photos)  # ERR lines: retried next visit
            _classify["pending"] = len(_inflight)


def _drain_queue() -> None:
    global _classifier
    while True:
        with _classify_lock:
            if not _queue:
                # Cleared under the lock, so a request racing this exit starts a new thread.
                _classifier = None
                return
            batch = _queue[:]
            _queue.clear()
        _run_classifier(batch)


def _start_classifier(photos) -> None:
    """Queue unjudged photos; one thread judges them in order, whichever pass asked."""
    global _classifier
    with _classify_lock:
        if _verdicts_off:
            _classify.update(pending=0, total=0, error=_verdicts_off)
            return
        verdicts = _verdicts()
        todo = [
            p
            for p in photos
            if p.uuid not in verdicts and p.uuid not in _inflight and _image_path(p)
        ]
        if not todo:
            return
        total = len(todo) + (_classify["total"] if _inflight else 0)
        _queue.extend(todo)
        _inflight.update(p.uuid for p in todo)
        _classify.update(pending=len(_inflight), total=total, error=None)
        if _classifier is None:
            _classifier = threading.Thread(target=_drain_queue, daemon=True)
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


def _candidates(kind: str, threshold: float = 0.01) -> list:
    """A pass's photos, before any model judgement, minus those already filed."""
    photosdb = db()
    ignore = common.load_ignore_albums(None)
    if kind == "screenshots":
        photos, _ = common.get_candidate_photos(photosdb, ignore, only_screenshots=True)
    elif kind == "utility":
        # Screenshots have their own pass; the classifier's Vision step filters the rest.
        photos, _ = common.get_candidate_photos(photosdb, ignore)
        photos = [p for p in photos if _image_path(p)]
    elif kind == "clusters":
        photos, _ = common.get_candidate_photos(photosdb, ignore, require_valid_date=True)
    elif kind == "low-quality":
        photos, _ = common.get_candidate_photos(photosdb, ignore)
        photos = [
            p for p in photos if (s := common.get_photo_score(p)) is not None and s <= threshold
        ]
    else:
        raise HTTPException(status_code=404, detail="unknown cleanup kind")
    # Album membership comes from the startup snapshot; _committed covers this session's commits.
    filed = {ALBUMS[kind], KEEP_ALBUMS[kind]}
    return [p for p in photos if p.uuid not in _committed and filed.isdisjoint(p.albums)]


def _time_bursts(photos) -> list[list]:
    photos = sorted(photos, key=lambda p: common.make_aware(p.date))
    return common.group_by_time(photos, CLUSTER_WINDOW_S, 2)


@app.get("/counts")
def counts() -> dict:
    """Photos per tab, or None where knowing it needs work not done yet."""
    out: dict[str, int | None] = {"all": len(_index()[0])}
    verdicts = _verdicts()
    for kind in ALBUMS:
        photos = _candidates(kind)
        if kind == "utility":
            judged = [verdicts[p.uuid] for p in photos if p.uuid in verdicts]
            done = len(judged) == len(photos)
            out[kind] = sum(v["kind"] != "picture" for v in judged) if done else None
        elif kind == "clusters":
            bursts = _time_bursts(photos)
            if all(p.uuid in _prints for g in bursts for p in g):
                out[kind] = sum(len(r) for g in bursts for r in _split_similar(g, _prints))
            else:
                out[kind] = None  # feature prints are computed on the first Bursts visit
        else:
            out[kind] = len(photos)
    return out


@app.get("/cleanup/{kind}")
def cleanup(kind: str, threshold: float = 0.01) -> dict:
    """Run a cleanup pass and return its candidate photos (newest-first)."""
    photos = _candidates(kind, threshold)
    if kind == "clusters":
        bursts = _time_bursts(photos)
        try:
            prints = _feature_prints([p for g in bursts for p in g])
        except (subprocess.CalledProcessError, OSError) as e:
            # Time alone groups different photos (a run of labels, report pages); show none.
            err = e.stderr.decode()[-300:] if isinstance(e, subprocess.CalledProcessError) else e
            return {
                "kind": kind,
                "count": 0,
                "groups": [],
                "classify": {"pending": 0, "error": str(err)},
            }
        groups = [run for g in bursts for run in _split_similar(g, prints)]
        out = []
        for g in reversed(groups):  # newest group first
            best = max(g, key=_score_for_sort)  # first max wins ties: earliest shot
            out.append({"photos": [_meta(p) for p in g], "best": best.uuid})
        return {
            "kind": kind,
            "count": sum(len(g["photos"]) for g in out),
            "groups": out,
            "classify": {"pending": 0, "error": None},
        }
    photos.sort(key=lambda p: common.make_aware(p.date) if p.date else _MIN, reverse=True)
    verdicts: dict[str, dict] = {}
    classify = {"pending": 0, "error": None}
    if kind in VERDICT_KINDS:
        _start_classifier(photos)
        verdicts, classify = _verdicts(), dict(_classify)
    if kind == "utility":
        # "picture" = Vision said not a utility image; unjudged photos appear once classified.
        photos = [
            p for p in photos if verdicts.get(p.uuid, {"kind": "picture"})["kind"] != "picture"
        ]
    return {
        "kind": kind,
        "count": len(photos),
        "photos": [
            {**_meta(p), "verdict": _pass_verdict(kind, verdicts.get(p.uuid))} for p in photos
        ],
        "classify": classify,
    }


def _log_decisions(kind: str, decided: list[tuple[str, str]]) -> None:
    """Append one line per committed photo that has a model verdict, to measure its accuracy."""
    verdicts = _verdicts()
    now = datetime.now(UTC).isoformat()
    lines = [
        json.dumps(
            {
                "uuid": u,
                "kind": kind,
                "verdict_kind": v["kind"],
                "verdict_keep": v["keep"],
                "decision": d,
                "ts": now,
            }
        )
        for u, d in decided
        if (v := _pass_verdict(kind, verdicts.get(u)))
    ]
    if lines:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        with (CACHE_DIR / DECISIONS_LOG).open("a") as f:
            f.write("\n".join(lines) + "\n")


@app.get("/verdict-stats")
def verdict_stats() -> dict:
    """Per pass: how many committed photos matched the model's verdict."""
    out: dict[str, dict] = {}
    f = CACHE_DIR / DECISIONS_LOG
    for line in f.read_text().splitlines() if f.exists() else []:
        r = json.loads(line)
        s = out.setdefault(r["kind"], {"agree": 0, "total": 0})
        s["total"] += 1
        s["agree"] += r["verdict_keep"] == (r["decision"] == "keep")
    return out


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
    if req.kind in VERDICT_KINDS:
        _log_decisions(
            req.kind,
            [(p.uuid, "delete") for p in doomed] + [(p.uuid, "keep") for p in kept],
        )
    return {"added": len(doomed), "album": album, "kept": len(kept), "keep_album": keep_album}


# Mounted last so the API routes above win; absent in a source checkout until `pnpm build`.
if UI_DIR.is_dir():
    app.mount("/", StaticFiles(directory=UI_DIR, html=True), name="ui")
