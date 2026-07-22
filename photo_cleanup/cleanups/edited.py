"""Find edited photo copies; flag them so originals can be kept."""

from __future__ import annotations

from photo_cleanup import cli, common

DEFAULT_KEEPERS_ALBUM = "Edited Copies - Keepers"
DEFAULT_EXTRAS_ALBUM = "Edited Copies - Review Me"


def main(argv: list[str] | None = None) -> int:
    parser = cli.base_parser("Find photos with adjustments (edited copies).")
    parser.add_argument(
        "--keepers-album", default=DEFAULT_KEEPERS_ALBUM, help="Album for unedited originals"
    )
    args = parser.parse_args(argv)

    ignore = common.load_ignore_albums(args.ignore_album)
    since, until = cli.resolve_date_range(args)
    photosdb = common.get_photosdb()
    photos, stats = common.get_candidate_photos(photosdb, ignore, since=since, until=until)

    print(f"Scanning {len(photos)} photos for edited copies...")
    print(common.format_skipped(stats))

    edited = [p for p in photos if p.hasadjustments]
    originals = [p for p in photos if not p.hasadjustments]

    if not edited:
        print("\nNo edited photos found.")
        return 0

    common.print_summary("Edited photo copies found", edited)
    print("\nBreakdown:")
    print(f"  Total scanned: {len(photos)}")
    print(f"  Originals: {len(originals)} ({common.total_size_mb(originals):.1f} MB)")
    print(f"  Edited copies: {len(edited)} ({common.total_size_mb(edited):.1f} MB)")

    print("\nSample edited photos:")
    for p in edited[:15]:
        when = p.date.strftime("%Y-%m-%d %H:%M") if p.date else "Unknown"
        print(f"  {when:16s}  {p.original_filename}")

    common.add_to_album(originals, args.keepers_album, dry_run=args.dry_run, assume_yes=args.yes)
    common.add_to_album(
        edited, args.album_name or DEFAULT_EXTRAS_ALBUM, dry_run=args.dry_run, assume_yes=args.yes
    )
    print("Compare both albums in Photos. Delete edited versions you don't need.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
