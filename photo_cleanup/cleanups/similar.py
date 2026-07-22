"""Find visually similar photos via perceptual fingerprint matching.

Photos are bucketed by the first --bucket-prefix characters of their
fingerprint and compared only within each bucket. This makes scanning
tractable on large libraries but introduces a recall trade-off: two photos
whose fingerprints disagree in the first N characters will never be
compared, even if the rest of the fingerprint is identical. In practice,
perceptually similar photos almost always share a fingerprint prefix, but
if you want zero false negatives at the cost of O(n^2) runtime, pass
--bucket-prefix 0.
"""

from __future__ import annotations

from photo_cleanup import cli, common

DEFAULT_KEEPERS_ALBUM = "Similar Photos - Keepers"
DEFAULT_EXTRAS_ALBUM = "Similar Photos - Review Me"
DEFAULT_THRESHOLD = 70
DEFAULT_BUCKET_PREFIX = 4


def main(argv: list[str] | None = None) -> int:
    parser = cli.base_parser("Find similar-looking photos using Apple's perceptual fingerprints.")
    parser.add_argument(
        "--threshold",
        type=int,
        default=DEFAULT_THRESHOLD,
        help=f"Minimum similarity percent to group (default: {DEFAULT_THRESHOLD})",
    )
    parser.add_argument(
        "--bucket-prefix",
        type=int,
        default=DEFAULT_BUCKET_PREFIX,
        help=f"Fingerprint prefix length used to bucket comparisons. Smaller "
        f"is slower but loses fewer matches; 0 disables bucketing entirely "
        f"(O(n^2)). Default: {DEFAULT_BUCKET_PREFIX}",
    )
    parser.add_argument(
        "--keepers-album",
        default=DEFAULT_KEEPERS_ALBUM,
        help="Album name for the first photo from each similar group",
    )
    args = parser.parse_args(argv)

    ignore = common.load_ignore_albums(args.ignore_album)
    since, until = cli.resolve_date_range(args)
    photosdb = common.get_photosdb()
    photos, stats = common.get_candidate_photos(photosdb, ignore, since=since, until=until)

    print(f"Scanning {len(photos)} photos for similar matches...")
    print(common.format_skipped(stats))
    print(f"Similarity threshold: {args.threshold}%, bucket prefix: {args.bucket_prefix}\n")

    no_fp = sum(1 for p in photos if not p.fingerprint)
    similar_groups = common.group_similar_fingerprints(
        photos,
        args.threshold,
        args.bucket_prefix,
    )

    if not similar_groups:
        print("No similar photos found.")
        return 0

    keepers = [g[0] for g in similar_groups]
    extras = [p for g in similar_groups for p in g[1:]]

    common.print_summary("Similar photo groups found", extras)
    print(f"\nSimilar groups: {len(similar_groups)}")
    print(f"Keepers: {len(keepers)} ({common.total_size_mb(keepers):.1f} MB)")
    print(f"Extras to review: {len(extras)} ({common.total_size_mb(extras):.1f} MB)")
    if no_fp:
        print(f"Note: {no_fp} photos had no fingerprint and were skipped.")

    print("\nSample similar groups:")
    for group in similar_groups[:5]:
        fp = group[0].fingerprint
        print(f"\n  Group (fp {fp[:16]}...):")
        for p in group[:3]:
            when = p.date.strftime("%Y-%m-%d %H:%M") if p.date else "Unknown"
            print(f"    {when:16s}  {p.original_filename}")

    common.add_to_album(keepers, args.keepers_album, dry_run=args.dry_run, assume_yes=args.yes)
    common.add_to_album(
        extras, args.album_name or DEFAULT_EXTRAS_ALBUM, dry_run=args.dry_run, assume_yes=args.yes
    )
    print("\nCompare both albums in Photos. Delete similar alternatives you don't need.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
