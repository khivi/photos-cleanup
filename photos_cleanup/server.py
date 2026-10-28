"""Local server: serves the built UI (./ui) and the API on 127.0.0.1.

Every library access goes through library.py (PhotoKit); the UI is same-origin, so no CORS.
ponytail: the photo list is read once at startup; restart the server to pick up library
changes.
"""

from __future__ import annotations

import base64
import functools
import hashlib
import json
import math
import shutil
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

from photos_cleanup import library

CLUSTER_WINDOW_S = 60
# Feature-print L2 distance below which two neighbouring shots count as repeats. Calibrated
# by eye on 40 real bursts: pairs <= 0.44 were the same shot; from 0.46 they were different
# photos (report pages, a different person, different medicine labels).
SIMILAR_MAX_DIST = 0.45
# Vision aesthetics score at or below which a photo is suggested as low quality. Set by eye
# on the real library: <= -0.75 was almost all accidental shots (black frames, pocket blur,
# a finger over the lens); from about -0.7 up, dark or soft photos of people creep in.
LOW_QUALITY_MAX = -0.75

# Per-pass album names (engine convention: end with "Delete Me" / "Review Me").
ALBUMS = {
    "screenshots": "Screenshots - Delete Me",
    "low-quality": "Low Quality - Review Me",
    "utility": "Utility - Delete Me",
    "clusters": "Bursts - Delete Me",
}
# Not in library.CLEANUP_ALBUM_NAMES, so they count as user albums and the candidate
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
CACHE_DIR = library.CACHE_DIR
VERDICT_SRC = Path(__file__).with_name("verdict.swift")
DECISIONS_LOG = "decisions.jsonl"  # user's final keep/delete per committed verdict photo
# Keyed to the helper's source, so a prompt or kind-list change re-judges everything.
VERDICT_CACHE = f"verdicts-{hashlib.sha256(VERDICT_SRC.read_bytes()).hexdigest()[:8]}.jsonl"
# Keyed to the PhotoKit helper's source: its image sizes shape the prints and scores.
VISION_CACHE = f"vision-{hashlib.sha256(library.PHOTOKIT_SRC.read_bytes()).hexdigest()[:8]}.jsonl"
THUMB_DIR = CACHE_DIR / "thumbs"

app = FastAPI(title="photos-cleanup")
# Blocks DNS rebinding: an attacker domain resolved to 127.0.0.1 would otherwise be same-origin.
app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost"])

_MIN = datetime.min.replace(tzinfo=UTC)


@functools.lru_cache(maxsize=1)
def _all_photos() -> list:
    return library.load_photos()


# The photo list is read once and never sees album changes, so commits are tracked here.
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


def _add_to_album(photos, album: str) -> None:
    """Append photos to an album through PhotoKit: one call, no Apple Events."""
    try:
        library.photokit.call({"op": "add", "album": album, "uuids": [p.uuid for p in photos]})
    except library.PhotoKitError as e:
        if "access" in str(e):
            raise HTTPException(
                status_code=403,
                detail="Photos access is off. Turn it on for your terminal app in System "
                "Settings > Privacy & Security > Photos, then commit again.",
            ) from e
        raise HTTPException(status_code=500, detail=f"Adding to album failed: {e}") from e


# Vision analysis (feature print, isUtility, aesthetics score) for every candidate, computed
# once in the background and cached on disk. Bursts, Low quality and Utility all read it.
_vision_lock = threading.Lock()
_vision_state: dict = {"pending": 0, "total": 0, "error": None}
_vision_queue: list[str] = []
_vision_thread: threading.Thread | None = None


@functools.lru_cache(maxsize=1)
def _vision() -> dict[str, dict | None]:
    """uuid -> {"print": array, "utility": bool, "score": float}; None: no local image."""
    f = CACHE_DIR / VISION_CACHE
    out: dict[str, dict | None] = {}
    for line in f.read_text().splitlines() if f.exists() else []:
        out.update(_parse_vision(json.loads(line)))
    return out


def _parse_vision(r: dict) -> dict[str, dict | None]:
    if "error" in r:
        return {r["uuid"]: None}
    vec = array("f" if r["ptype"] == 1 else "d", base64.b64decode(r["print"]))
    return {r["uuid"]: {"print": vec, "utility": r["utility"], "score": r["score"]}}


def _drain_vision() -> None:
    global _vision_thread
    while True:
        with _vision_lock:
            if not _vision_queue:
                _vision_thread = None  # under the lock, so a racing request starts a new one
                return
            # Stays queued until saved, so a request meanwhile doesn't queue it again.
            batch = _vision_queue[:100]
        try:
            results = library.photokit.call({"op": "vision", "uuids": batch})["results"]
        except (library.PhotoKitError, OSError, subprocess.CalledProcessError) as e:
            with _vision_lock:
                _vision_state.update(error=str(e), pending=0)
                _vision_queue.clear()
                _vision_thread = None
            return
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        with (CACHE_DIR / VISION_CACHE).open("a") as f:
            f.write("".join(json.dumps(r) + "\n" for r in results))
        with _vision_lock:
            for r in results:
                _vision().update(_parse_vision(r))
            del _vision_queue[: len(batch)]
            _vision_state["pending"] = len(_vision_queue)


def _start_vision(photos) -> dict:
    """Queue photos not yet analysed; returns the analysis progress for the UI."""
    global _vision_thread
    with _vision_lock:
        done, queued = _vision(), set(_vision_queue)
        todo = [p.uuid for p in photos if p.uuid not in done and p.uuid not in queued]
        if todo:
            total = len(todo) + (_vision_state["total"] if _vision_queue else 0)
            _vision_queue.extend(todo)
            _vision_state.update(pending=len(_vision_queue), total=total, error=None)
            if _vision_thread is None:
                _vision_thread = threading.Thread(target=_drain_vision, daemon=True)
                _vision_thread.start()
        return dict(_vision_state)


def _vision_score(p) -> float:
    """Aesthetics score; photos not analysed sort last, never out-ranking a real score."""
    v = _vision().get(p.uuid)
    return v["score"] if v else -2.0


def _split_similar(group: list, vision: dict[str, dict | None]) -> list[list]:
    """Split a time-sorted burst wherever neighbouring shots stop looking alike.

    Utility images (documents, labels) never join: different pages look alike to prints.
    """

    def vec(p):
        v = vision.get(p.uuid)
        return v["print"] if v and not v["utility"] else None

    runs, run = [], [group[0]]
    for a, b in zip(group, group[1:], strict=False):
        pa, pb = vec(a), vec(b)
        if pa is not None and pb is not None and math.dist(pa, pb) < SIMILAR_MAX_DIST:
            run.append(b)
        else:
            runs.append(run)
            run = [b]
    runs.append(run)
    return [r for r in runs if len(r) >= 2]


def _run_classifier(photos) -> None:
    verdicts = _verdicts()
    img_dir = Path(tempfile.mkdtemp(prefix="photos-cleanup-verdict-"))
    try:
        exe = library.swift_bin(VERDICT_SRC)
        # Temp files, not pipes, for stdin/stderr: a full pipe would deadlock the child.
        with (
            tempfile.TemporaryFile("w+") as inp,
            tempfile.TemporaryFile("w+") as err,
            (CACHE_DIR / VERDICT_CACHE).open("a") as cache,
        ):
            img_dir.mkdir(parents=True, exist_ok=True)
            for p in photos:
                path = img_dir / f"{p.uuid}.jpg"
                try:
                    library.photokit.call(
                        {"op": "image", "uuid": p.uuid, "size": 1024, "path": str(path)}
                    )
                except library.PhotoKitError:
                    continue  # no local image: left unjudged, retried on a later visit
                date = p.date.date().isoformat() if p.date else "unknown"
                inp.write(f"{p.uuid}\t{path}\t{date}\n")
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
    except (OSError, library.PhotoKitError) as e:
        _classify["error"] = str(e)
    finally:
        shutil.rmtree(img_dir, ignore_errors=True)
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
        todo = [p for p in photos if p.uuid not in verdicts and p.uuid not in _inflight]
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
    photos = list(_all_photos())
    photos.sort(key=lambda p: library.make_aware(p.date) if p.date else _MIN, reverse=True)
    return photos, {p.uuid: p for p in photos}


def _meta(p) -> dict:
    return {
        "uuid": p.uuid,
        "width": p.width,
        "height": p.height,
        "date": p.date.isoformat() if p.date else None,
        "is_video": p.ismovie,
    }


@app.get("/health")
def health() -> dict:
    return {"ok": True}


@app.get("/photos")
def photos() -> dict:
    items, _ = _index()
    return {"total": len(items), "photos": [_meta(p) for p in items]}


@app.get("/thumb/{uuid}")
def thumb(uuid: str):
    # Only known UUIDs reach the file path below, so the URL can't name another file.
    if uuid not in _index()[1]:
        raise HTTPException(status_code=404)
    path = THUMB_DIR / f"{uuid}.jpg"
    if not path.exists():
        THUMB_DIR.mkdir(parents=True, exist_ok=True)
        try:
            # 340px: the 170px grid cell on a 2x display.
            library.photokit.call({"op": "image", "uuid": uuid, "size": 340, "path": str(path)})
        except library.PhotoKitError as e:
            raise HTTPException(status_code=404) from e
    return FileResponse(path)


def _candidates(kind: str) -> list:
    """A pass's photos, before any model judgement, minus those already filed."""
    photos = _all_photos()
    ignore = library.load_ignore_albums()
    if kind == "screenshots":
        photos = library.get_candidate_photos(photos, ignore, only_screenshots=True)
    elif kind in ("utility", "low-quality"):
        photos = library.get_candidate_photos(photos, ignore)
    elif kind == "clusters":
        photos = library.get_candidate_photos(photos, ignore, require_valid_date=True)
    else:
        raise HTTPException(status_code=404, detail="unknown cleanup kind")
    # Album membership comes from the startup snapshot; _committed covers this session's commits.
    filed = {ALBUMS[kind], KEEP_ALBUMS[kind]}
    return [p for p in photos if p.uuid not in _committed and filed.isdisjoint(p.albums)]


def _analysed(kind: str, photos, threshold: float = LOW_QUALITY_MAX) -> tuple[list, dict]:
    """Narrow Utility and Low quality by the Vision analysis done so far, and its progress."""
    progress = _start_vision(photos)
    vision = _vision()
    if kind == "utility":
        photos = [p for p in photos if (v := vision.get(p.uuid)) and v["utility"]]
    elif kind == "low-quality":
        photos = [p for p in photos if (v := vision.get(p.uuid)) and v["score"] <= threshold]
    return photos, progress


def _time_bursts(photos) -> list[list]:
    photos = sorted(photos, key=lambda p: library.make_aware(p.date))
    return library.group_by_time(photos, CLUSTER_WINDOW_S, 2)


@app.get("/counts")
def counts() -> dict:
    """Photos per tab, or None where knowing it needs work not done yet."""
    out: dict[str, int | None] = {"all": len(_index()[0])}
    verdicts = _verdicts()
    for kind in ALBUMS:
        photos = _candidates(kind)
        if kind == "screenshots":
            out[kind] = len(photos)
            continue
        vision_done = all(p.uuid in _vision() for p in photos)
        photos, _ = _analysed(kind, photos)
        if not vision_done:
            out[kind] = None  # the background Vision analysis is still running
        elif kind == "utility":
            judged = [verdicts[p.uuid] for p in photos if p.uuid in verdicts]
            done = len(judged) == len(photos)
            out[kind] = sum(v["kind"] != "picture" for v in judged) if done else None
        elif kind == "clusters":
            out[kind] = sum(
                len(r) for g in _time_bursts(photos) for r in _split_similar(g, _vision())
            )
        else:
            out[kind] = len(photos)
    return out


@app.get("/cleanup/{kind}")
def cleanup(kind: str, threshold: float = LOW_QUALITY_MAX) -> dict:
    """Run a cleanup pass and return its candidate photos (newest-first)."""
    photos = _candidates(kind)
    progress = {"pending": 0, "total": 0, "error": None}
    if kind != "screenshots":
        photos, progress = _analysed(kind, photos, threshold)
    if kind == "clusters":
        groups = [run for g in _time_bursts(photos) for run in _split_similar(g, _vision())]
        out = []
        for g in reversed(groups):  # newest group first
            best = max(g, key=_vision_score)  # first max wins ties: earliest shot
            out.append({"photos": [_meta(p) for p in g], "best": best.uuid})
        return {
            "kind": kind,
            "count": sum(len(g["photos"]) for g in out),
            "groups": out,
            "classify": progress,
        }
    photos.sort(key=lambda p: library.make_aware(p.date) if p.date else _MIN, reverse=True)
    verdicts: dict[str, dict] = {}
    if kind in VERDICT_KINDS:
        _start_classifier(photos)
        verdicts = _verdicts()
        if not progress["pending"]:  # Vision first, then the model: one bar at a time
            progress = dict(_classify)
    if kind == "utility":
        # Unjudged photos appear once classified; "picture" means the model's own Vision
        # check said it isn't a utility image after all.
        photos = [
            p for p in photos if verdicts.get(p.uuid, {"kind": "picture"})["kind"] != "picture"
        ]
    return {
        "kind": kind,
        "count": len(photos),
        "photos": [
            {**_meta(p), "verdict": _pass_verdict(kind, verdicts.get(p.uuid))} for p in photos
        ],
        "classify": progress,
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
            _add_to_album(photos, name)
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
