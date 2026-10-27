"""Local server: serves the built UI (./dist) and the API on 127.0.0.1.

Wraps the photo_cleanup engine; the UI is same-origin, so no CORS.
ponytail: single cached PhotosDB + photo index — the load is slow (seconds on a
big library) so we do it once; add a /reload endpoint if the library changes.

The engine (photo_cleanup) is vendored in-repo — see CLAUDE.md.
"""

from __future__ import annotations

import argparse
import functools
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

app = FastAPI(title="photos-cleanup")
# Blocks DNS rebinding: an attacker domain resolved to 127.0.0.1 would otherwise be same-origin.
app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost"])

_MIN = datetime.min.replace(tzinfo=UTC)


# TODO(reload): add POST /reload to clear db()/_index() caches so the library
# re-reads mid-session without an app restart. If the ~316MB full re-parse on
# first request ever feels slow, persist a uuid-keyed index to disk and diff
# instead of re-reading everything.
@functools.lru_cache(maxsize=1)
def db():
    return common.get_photosdb()


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
    photos.sort(key=lambda p: common.make_aware(p.date) if p.date else _MIN, reverse=True)
    return {"kind": kind, "count": len(photos), "photos": [_meta(p) for p in photos]}


class CommitReq(BaseModel):
    kind: str
    uuids: list[str]


@app.post("/commit")
def commit(req: CommitReq) -> dict:
    """Move the given photos into this pass's review album (never deletes)."""
    album = ALBUMS.get(req.kind)
    if album is None:
        raise HTTPException(status_code=404, detail="unknown cleanup kind")
    _, by_uuid = _index()
    photos = [by_uuid[u] for u in req.uuids if u in by_uuid]
    if not photos:
        raise HTTPException(status_code=400, detail="no matching photos")
    # assume_yes=True: no TTY here; the caller (GUI) already confirmed.
    common.add_to_album(photos, album, dry_run=False, assume_yes=True)
    return {"added": len(photos), "album": album}


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
