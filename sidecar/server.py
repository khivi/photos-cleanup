"""Local HTTP sidecar for the Tauri shell. Wraps the photo_cleanup engine.

The Tauri app spawns this on 127.0.0.1 and the webview talks to it directly.
ponytail: single cached PhotosDB + photo index — the load is slow (seconds on a
big library) so we do it once; add a /reload endpoint if the library changes.

The engine (photo_cleanup, osxphotos) is a dependency; we never edit its repo.
"""

from __future__ import annotations

import argparse
import functools
from datetime import UTC, datetime

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from photo_cleanup import common
from pydantic import BaseModel

# Per-pass album names (engine convention: end with "Delete Me" / "Review Me").
ALBUMS = {
    "screenshots": "Screenshots - Delete Me",
    "low-quality": "Low Quality - Review Me",
}

app = FastAPI(title="photo-cleanup sidecar")
# ponytail: allow-all CORS — this only ever listens on 127.0.0.1 for the webview.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

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
def photos(offset: int = 0, limit: int = 100) -> dict:
    items, _ = _index()
    return {"total": len(items), "photos": [_meta(p) for p in items[offset : offset + limit]]}


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


def main() -> None:
    import uvicorn

    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
