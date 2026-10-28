"""The Photos library, read and written through PhotoKit (photokit.swift).

Every library access goes through the long-running helper here; the server never touches
the library directly. Also the candidate filter and photo grouping the passes share.
"""

from __future__ import annotations

import json
import subprocess
import threading
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path

CACHE_DIR = Path.home() / "Library/Caches/photos-cleanup"
PHOTOKIT_SRC = Path(__file__).with_name("photokit.swift")
INFO_PLIST = Path(__file__).with_name("Info.plist")  # PhotoKit's permission prompt needs it

# Apple's smart albums: membership doesn't mean the user organised the photo.
DEFAULT_IGNORE_ALBUMS = frozenset(
    {
        "Screenshots",
        "Selfies",
        "Portrait",
        "Panoramas",
        "Live Photos",
        "Videos",
        "Slo-mo",
        "Bursts",
        "Time-lapse",
        "Recently Deleted",
        "Recents",
        "Hidden",
        "Imports",
        "Animated",
        "Long Exposure",
        "RAW",
        "Cinematic",
        "Spatial",
    }
)

# Review albums, so a photo in one still counts as a candidate. The last five come from the
# photo-cleanup command-line tool and may exist in libraries it was run on.
CLEANUP_ALBUM_NAMES = frozenset(
    {
        "Screenshots - Delete Me",
        "Low Quality - Delete Me",
        "Low Quality - Review Me",
        "Cluster Extras - Review Me",
        "Cluster Keepers",
        "Similar Photos - Keepers",
        "Similar Photos - Review Me",
        "Documents - Review Me",
    }
)

IGNORE_FILES = ("albums_ignore", "albums_ignore.local")

MIN_DATE = datetime(2000, 1, 1, tzinfo=UTC)


def swift_bin(src: Path, plist: Path | None = None) -> Path:
    """Compile a Swift helper into the cache dir on first use or when its source changes."""
    exe = CACHE_DIR / src.stem
    if not exe.exists() or exe.stat().st_mtime < src.stat().st_mtime:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        embed = ["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist"]
        extra = [*embed, "-Xlinker", str(plist)] if plist else []
        subprocess.run(
            ["swiftc", "-O", str(src), "-o", str(exe), *extra], check=True, capture_output=True
        )
    return exe


class PhotoKitError(RuntimeError):
    pass


class PhotoKit:
    """One photokit.swift process; requests are serialised (one JSON line each way)."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._proc: subprocess.Popen | None = None

    def call(self, req: dict) -> dict:
        with self._lock:
            if self._proc is None or self._proc.poll() is not None:
                exe = swift_bin(PHOTOKIT_SRC, INFO_PLIST)
                self._proc = subprocess.Popen(
                    [exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
                )
            self._proc.stdin.write(json.dumps(req) + "\n")
            self._proc.stdin.flush()
            line = self._proc.stdout.readline()
        if not line:
            raise PhotoKitError("the PhotoKit helper exited")
        out = json.loads(line)
        if "error" in out:
            raise PhotoKitError(out["error"])
        return out


photokit = PhotoKit()


@dataclass
class Photo:
    uuid: str
    date: datetime | None
    width: int
    height: int
    screenshot: bool
    live_photo: bool
    ismovie: bool
    favorite: bool
    albums: list[str] = field(default_factory=list)


def load_photos() -> list[Photo]:
    """Every photo and video in the user's own library (not iCloud Shared Albums)."""
    return [
        Photo(
            uuid=x["uuid"],
            date=datetime.fromtimestamp(x["date"], UTC) if x["date"] is not None else None,
            width=x["w"],
            height=x["h"],
            screenshot=x["shot"],
            live_photo=x["live"],
            ismovie=x["movie"],
            favorite=x["fav"],
            albums=x["albums"],
        )
        for x in photokit.call({"op": "list"})["photos"]
    ]


def _read_album_file(path: Path) -> set[str]:
    """Parse an album-name file: one per line, '#' starts a comment, blanks ignored."""
    if not path.is_file():
        return set()
    out: set[str] = set()
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.add(line)
    return out


def load_ignore_albums() -> frozenset[str]:
    """Albums whose membership doesn't protect a photo: defaults, review albums, and any
    listed in ./albums_ignore or ./albums_ignore.local (relative to the working directory).
    """
    user_albums: set[str] = set()
    for name in IGNORE_FILES:
        user_albums |= _read_album_file(Path.cwd() / name)
    return DEFAULT_IGNORE_ALBUMS | CLEANUP_ALBUM_NAMES | user_albums


def make_aware(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=UTC)
    return dt


def get_candidate_photos(
    photos,
    ignore_albums: frozenset[str],
    *,
    only_screenshots: bool = False,
    require_valid_date: bool = False,
) -> list:
    """Photos a pass may suggest: not favorited, not videos, not in any of the user's own
    albums. Screenshots appear only with only_screenshots, which returns nothing else.
    """
    out = []
    for p in photos:
        if p.screenshot != only_screenshots or p.ismovie or p.favorite:
            continue
        if set(p.albums) - ignore_albums:
            continue
        if require_valid_date and (p.date is None or make_aware(p.date) < MIN_DATE):
            continue
        out.append(p)
    return out


def group_by_time(photos, window_seconds: int, min_size: int) -> list[list]:
    """Group date-sorted photos: one joins the current group if taken within window_seconds
    of the previous photo. Groups smaller than min_size are dropped.
    """
    if not photos:
        return []
    window = timedelta(seconds=window_seconds)
    groups: list[list] = []
    current = [photos[0]]
    for p in photos[1:]:
        if make_aware(p.date) - make_aware(current[-1].date) <= window:
            current.append(p)
        else:
            if len(current) >= min_size:
                groups.append(current)
            current = [p]
    if len(current) >= min_size:
        groups.append(current)
    return groups
