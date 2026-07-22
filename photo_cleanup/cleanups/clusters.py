"""Group rapid-sequence photos and keep the highest-scored one per cluster."""

from __future__ import annotations

from photo_cleanup import cli, common

DEFAULT_KEEPERS_ALBUM = "Cluster Keepers"
DEFAULT_EXTRAS_ALBUM = "Cluster Extras - Review Me"
DEFAULT_WINDOW = 60
DEFAULT_MIN_SIZE = 3


def _score_for_sort(photo) -> float:
    """Sort unscored photos last — never let them out-rank a real score."""
    score = common.get_photo_score(photo)
    return score if score is not None else -1.0


def main(argv: list[str] | None = None) -> int:
    parser = cli.base_parser(
        "Group photos taken within --window seconds and keep the best per cluster."
    )
    parser.add_argument(
        "--window",
        type=int,
        default=DEFAULT_WINDOW,
        help=f"Cluster time window in seconds (default: {DEFAULT_WINDOW})",
    )
    parser.add_argument(
        "--min-size",
        type=int,
        default=DEFAULT_MIN_SIZE,
        help=f"Minimum photos per cluster (default: {DEFAULT_MIN_SIZE})",
    )
    parser.add_argument(
        "--keepers-album",
        default=DEFAULT_KEEPERS_ALBUM,
        help="Album name for the best photo from each cluster",
    )
    args = parser.parse_args(argv)

    ignore = common.load_ignore_albums(args.ignore_album)
    since, until = cli.resolve_date_range(args)
    photosdb = common.get_photosdb()
    photos, stats = common.get_candidate_photos(
        photosdb,
        ignore,
        require_valid_date=True,
        since=since,
        until=until,
    )
    photos.sort(key=lambda p: common.make_aware(p.date))

    print(f"Analyzing {len(photos)} photos for clusters...")
    print(common.format_skipped(stats))

    clusters = common.group_by_time(photos, args.window, args.min_size)
    print(f"Found {len(clusters)} clusters of {args.min_size}+ photos within {args.window}s")
    print(f"Total photos in clusters: {sum(len(c) for c in clusters)}")

    keepers = []
    extras = []
    for cluster in clusters:
        scored = sorted(cluster, key=_score_for_sort, reverse=True)
        keepers.append(scored[0])
        extras.extend(scored[1:])

    print(f"\nKeepers: {len(keepers)} ({common.total_size_mb(keepers):.1f} MB)")
    print(f"Extras to review: {len(extras)} ({common.total_size_mb(extras):.1f} MB)")

    print("\nSample clusters:")
    for cluster in clusters[:5]:
        scored = sorted(cluster, key=_score_for_sort, reverse=True)
        print(f"\n  {cluster[0].date.strftime('%Y-%m-%d %H:%M')} - {len(cluster)} photos:")
        for i, p in enumerate(scored):
            tag = "KEEP" if i == 0 else "    "
            score = common.get_photo_score(p)
            score_str = f"{score:.2f}" if score is not None else " n/a"
            print(f"    {tag} score={score_str} {p.original_filename}")

    if extras:
        common.add_to_album(keepers, args.keepers_album, dry_run=args.dry_run, assume_yes=args.yes)
        common.add_to_album(
            extras,
            args.album_name or DEFAULT_EXTRAS_ALBUM,
            dry_run=args.dry_run,
            assume_yes=args.yes,
        )
        print("Compare both albums in Photos. Delete extras you don't need.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
