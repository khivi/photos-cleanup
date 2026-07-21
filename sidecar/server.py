"""Local HTTP sidecar for the Tauri shell. Wraps the photo_cleanup engine.

The Tauri app spawns this on 127.0.0.1 and the webview talks to it directly.
ponytail: single cached PhotosDB — the load is slow (seconds on a big library)
so we do it once; add a /reload endpoint if the library changes mid-session.

The engine (photo_cleanup, osxphotos) is a dependency; we never edit its repo.
"""

from __future__ import annotations

import argparse
import functools

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from photo_cleanup import common

app = FastAPI(title="photo-cleanup sidecar")
# ponytail: allow-all CORS — this only ever listens on 127.0.0.1 for the webview.
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


@functools.lru_cache(maxsize=1)
def db():
    return common.get_photosdb()


@app.get("/health")
def health() -> dict:
    return {"ok": True}


@app.get("/stats")
def stats() -> dict:
    photos = db().photos()
    total_bytes = sum(p.original_filesize or 0 for p in photos)
    return {"count": len(photos), "size_gb": round(total_bytes / 1024**3, 1)}


def main() -> None:
    import uvicorn

    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
