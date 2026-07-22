"""Find screenshots not in any user album."""

from __future__ import annotations

from photo_cleanup import cli, common

DEFAULT_ALBUM = "Screenshots - Delete Me"


def main(argv: list[str] | None = None) -> int:
    parser = cli.base_parser("Find screenshots not organized into a user album.")
    args = parser.parse_args(argv)

    ignore = common.load_ignore_albums(args.ignore_album)
    since, until = cli.resolve_date_range(args)
    photosdb = common.get_photosdb()
    photos, stats = common.get_candidate_photos(
        photosdb,
        ignore,
        only_screenshots=True,
        since=since,
        until=until,
    )

    print(common.format_skipped(stats))
    common.print_summary("Screenshots NOT in any user album", photos)
    common.add_to_album(
        photos,
        args.album_name or DEFAULT_ALBUM,
        dry_run=args.dry_run,
        assume_yes=args.yes,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
