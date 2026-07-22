"""Find photos with near-zero Apple curation score.

Photos that have not been scored by Apple yet (fresh imports, iCloud-only)
are explicitly excluded from the low-quality candidate set, so they never get
flagged for deletion just because no score has been assigned.
"""

from __future__ import annotations

from photo_cleanup import cli, common

DEFAULT_ALBUM = "Low Quality - Review Me"
DEFAULT_THRESHOLD = 0.01


def main(argv: list[str] | None = None) -> int:
    parser = cli.base_parser(
        "Find photos with Apple's overall curation score at or below threshold."
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=DEFAULT_THRESHOLD,
        help=f"Quality score cutoff (default: {DEFAULT_THRESHOLD})",
    )
    args = parser.parse_args(argv)

    ignore = common.load_ignore_albums(args.ignore_album)
    since, until = cli.resolve_date_range(args)
    photosdb = common.get_photosdb()
    photos, stats = common.get_candidate_photos(photosdb, ignore, since=since, until=until)

    print(f"Scanning {len(photos)} photos...")
    print(common.format_skipped(stats))

    unscored = sum(1 for p in photos if common.get_photo_score(p) is None)
    low_quality = [
        p for p in photos if (s := common.get_photo_score(p)) is not None and s <= args.threshold
    ]

    if unscored:
        print(f"Excluded {unscored} unscored photos (Apple has not rated them yet)")

    common.print_summary(f"Photos with score <= {args.threshold}", low_quality)
    common.add_to_album(
        low_quality,
        args.album_name or DEFAULT_ALBUM,
        dry_run=args.dry_run,
        assume_yes=args.yes,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
