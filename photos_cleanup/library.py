"""Reading the Photos library through osxphotos: the candidate filter and photo helpers.

Originally the shared code of the photo-cleanup command-line tool; this app keeps only
what the server uses. Every osxphotos call lives here.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from pathlib import Path

import osxphotos

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


def get_photosdb() -> osxphotos.PhotosDB:
    return osxphotos.PhotosDB()


def get_candidate_photos(
    photosdb,
    ignore_albums: frozenset[str],
    *,
    only_screenshots: bool = False,
    require_valid_date: bool = False,
) -> list:
    """Photos a pass may suggest: not favorited, not videos, not in any of the user's own
    albums. Screenshots appear only with only_screenshots, which returns nothing else.
    """
    photos = []
    for p in photosdb.photos():
        if p.screenshot != only_screenshots or p.ismovie or p.favorite:
            continue
        if set(p.albums) - ignore_albums:
            continue
        if require_valid_date and (p.date is None or make_aware(p.date) < MIN_DATE):
            continue
        photos.append(p)
    return photos


def get_photo_score(photo) -> float | None:
    """Apple's overall curation score, or None if Apple has not scored the photo.

    None rather than 0: an unscored photo is typically a fresh import or iCloud-only and
    should not be treated as low quality.
    """
    s = photo.score
    return s.overall if s and s.overall is not None else None


def score_for_sort(photo) -> float:
    """Sort unscored photos last — never let them out-rank a real score."""
    score = get_photo_score(photo)
    return score if score is not None else -1.0


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


def add_to_album_applescript(photos, album_name: str) -> None:
    """Append photos to an album by driving Photos.app with AppleScript.

    Fallback for when the PhotoKit helper can't be built. Slow, and needs Automation access.
    """
    from osxphotos.photosalbum import PhotosAlbum

    # Batched (10 per Apple Event): one add per photo timed out the GUI commit on ~100 photos.
    PhotosAlbum(album_name).update(photos)
