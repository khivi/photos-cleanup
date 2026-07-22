"""Shared utilities for photo cleanup scripts."""

from __future__ import annotations

from collections import defaultdict
from datetime import UTC, datetime, timedelta
from pathlib import Path

import osxphotos

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

CLEANUP_ALBUM_NAMES = frozenset(
    {
        "Screenshots - Delete Me",
        "Low Quality - Review Me",
        "Cluster Extras - Review Me",
        "Cluster Keepers",
        "Similar Photos - Keepers",
        "Similar Photos - Review Me",
        "Edited Copies - Keepers",
        "Edited Copies - Review Me",
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


def load_ignore_albums(extra: list[str] | None = None) -> frozenset[str]:
    """Build the ignore set: defaults + cleanup names + cwd config files + extras.

    Reads ./albums_ignore (committed) and ./albums_ignore.local (gitignored)
    relative to the current working directory. Both are optional and additive.
    Extras (typically from --ignore-album CLI flags) merge on top.

    Prints a one-line summary when any user files were loaded so misconfig is
    visible.
    """
    user_albums: set[str] = set()
    loaded_summary: list[str] = []
    for name in IGNORE_FILES:
        from_file = _read_album_file(Path.cwd() / name)
        if from_file:
            user_albums |= from_file
            loaded_summary.append(f"{name} ({len(from_file)})")

    if extra:
        user_albums.update(extra)

    if loaded_summary:
        print(f"User-ignored albums: {', '.join(loaded_summary)}")

    return DEFAULT_IGNORE_ALBUMS | CLEANUP_ALBUM_NAMES | user_albums


def make_aware(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=UTC)
    return dt


def get_photosdb() -> osxphotos.PhotosDB:
    return osxphotos.PhotosDB()


def is_in_user_album(photo, ignore_albums: frozenset[str]) -> bool:
    return bool(set(photo.albums) - ignore_albums)


def get_candidate_photos(
    photosdb,
    ignore_albums: frozenset[str],
    *,
    include_movies: bool = False,
    include_screenshots: bool = False,
    only_screenshots: bool = False,
    only_live: bool = False,
    require_valid_date: bool = False,
    since: datetime | None = None,
    until: datetime | None = None,
):
    """Filter photos: not favorited, not in any user-created album, with type/date filters.

    When `since` or `until` is provided, photos with no date are excluded
    (counted under `skipped_date`); photos outside the range are excluded
    (counted under `skipped_out_of_range`).
    """
    if only_screenshots and include_screenshots:
        raise ValueError("only_screenshots and include_screenshots are mutually exclusive")

    has_date_range = since is not None or until is not None
    photos = []
    skipped_favs = 0
    skipped_albums = 0
    skipped_date = 0
    skipped_out_of_range = 0

    for p in photosdb.photos():
        if only_screenshots and not p.screenshot:
            continue
        if not only_screenshots and not include_screenshots and p.screenshot:
            continue
        if not include_movies and p.ismovie:
            continue
        if only_live and not p.live_photo:
            continue

        if p.favorite:
            skipped_favs += 1
            continue

        if is_in_user_album(p, ignore_albums):
            skipped_albums += 1
            continue

        if require_valid_date or has_date_range:
            if p.date is None or make_aware(p.date) < MIN_DATE:
                skipped_date += 1
                continue

        if has_date_range:
            photo_date = make_aware(p.date)
            if since is not None and photo_date < since:
                skipped_out_of_range += 1
                continue
            if until is not None and photo_date > until:
                skipped_out_of_range += 1
                continue

        photos.append(p)

    stats = {
        "skipped_favs": skipped_favs,
        "skipped_albums": skipped_albums,
        "skipped_date": skipped_date,
        "skipped_out_of_range": skipped_out_of_range,
    }
    return photos, stats


def format_skipped(stats: dict) -> str:
    """One-line summary of get_candidate_photos stats. Hides zero counts."""
    parts = [
        f"{stats['skipped_favs']} favorited",
        f"{stats['skipped_albums']} in user albums",
    ]
    if stats.get("skipped_date"):
        parts.append(f"{stats['skipped_date']} bad/missing dates")
    if stats.get("skipped_out_of_range"):
        parts.append(f"{stats['skipped_out_of_range']} outside date range")
    return f"Skipped: {', '.join(parts)}"


def total_size_mb(photos) -> float:
    return sum(p.original_filesize or 0 for p in photos) / 1024 / 1024


def get_photo_score(photo) -> float | None:
    """Apple's overall curation score, or None if Apple has not scored the photo.

    Returning None (rather than 0) lets callers distinguish "unscored" from
    "scored zero" — an unscored photo is typically a fresh import or
    iCloud-only and should not be treated as low quality.
    """
    s = photo.score
    return s.overall if s and s.overall is not None else None


def add_to_album(
    photos, album_name: str, *, dry_run: bool = False, assume_yes: bool = False
) -> bool:
    """Create or replace an album with the given photos.

    Raises on Photos API errors instead of swallowing them.
    """
    if not photos:
        print("No photos to add.")
        return False

    if dry_run:
        print(f"[dry-run] Would add {len(photos)} photos to album '{album_name}'")
        return False

    if not assume_yes:
        answer = input(
            f"\nCreate/update '{album_name}' album with {len(photos)} photos? (y/n): "
        ).lower()
        if answer != "y":
            return False

    from osxphotos.photosalbum import PhotosAlbum

    album = PhotosAlbum(album_name)
    existing = list(album.photos())
    if existing:
        album.album.remove(existing)
    for p in photos:
        album.add(p)
    print(f"Created '{album_name}' with {len(photos)} photos")
    return True


def print_summary(label: str, photos, extra_lines=None) -> None:
    print(f"\n{label}: {len(photos)}")
    print(f"Total size: {total_size_mb(photos):.1f} MB")
    if extra_lines:
        for line in extra_lines:
            print(line)


def hamming_distance(s1: str, s2: str) -> int:
    """Count differing positions in two equal-length strings.

    Raises ValueError on length mismatch — perceptual fingerprints are
    fixed-length per algorithm version, so a mismatch indicates a bug rather
    than a meaningful "totally different" comparison.
    """
    if len(s1) != len(s2):
        raise ValueError(f"length mismatch: {len(s1)} vs {len(s2)}")
    return sum(c1 != c2 for c1, c2 in zip(s1, s2, strict=True))


def fingerprint_similarity(fp1: str | None, fp2: str | None) -> float:
    """Similarity percentage 0-100 between two perceptual fingerprints.

    Returns 0 when either fingerprint is missing or they have differing
    lengths. Differing lengths are treated as "incomparable, assume different"
    rather than raising, since photos with no fingerprint are common in
    practice (e.g. very old or unprocessed library entries).
    """
    if not fp1 or not fp2 or len(fp1) != len(fp2):
        return 0
    return 100 * (1 - hamming_distance(fp1, fp2) / len(fp1))


def group_by_time(photos, window_seconds: int, min_size: int) -> list[list]:
    """Group time-sorted photos into clusters within a sliding window.

    A new photo joins the current cluster if its date is within
    window_seconds of the previous photo. Clusters smaller than min_size are
    discarded. Photos must be pre-sorted by date and must have non-None dates.
    """
    if not photos:
        return []
    window = timedelta(seconds=window_seconds)
    clusters: list[list] = []
    current = [photos[0]]
    for p in photos[1:]:
        if make_aware(p.date) - make_aware(current[-1].date) <= window:
            current.append(p)
        else:
            if len(current) >= min_size:
                clusters.append(current)
            current = [p]
    if len(current) >= min_size:
        clusters.append(current)
    return clusters


def group_similar_fingerprints(items, threshold_pct: int, bucket_prefix: int) -> list[list]:
    """Group items by perceptual-fingerprint similarity.

    Each item must have a `.fingerprint` attribute. Items without one are
    skipped. Only items sharing the first `bucket_prefix` characters are
    compared (set bucket_prefix=0 to compare all items, exhaustive O(n^2)).

    Within a bucket, the FIRST item is the pivot for each candidate group; an
    item joins the group if it meets `threshold_pct` similarity to the pivot.
    Items can only join one group — there is no transitive merging.
    """
    buckets: dict[str, list] = defaultdict(list)
    for item in items:
        fp = getattr(item, "fingerprint", None)
        if not fp:
            continue
        key = fp[:bucket_prefix] if bucket_prefix > 0 else ""
        buckets[key].append(item)

    groups: list[list] = []
    for bucket in buckets.values():
        claimed: set[int] = set()
        for i, pivot in enumerate(bucket):
            if id(pivot) in claimed:
                continue
            group = [pivot]
            for cand in bucket[i + 1 :]:
                if id(cand) in claimed:
                    continue
                if fingerprint_similarity(pivot.fingerprint, cand.fingerprint) >= threshold_pct:
                    group.append(cand)
                    claimed.add(id(cand))
            if len(group) > 1:
                groups.append(group)
                claimed.add(id(pivot))
    return groups
