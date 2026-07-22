"""Find document-like photos via Apple's image classification labels."""

from __future__ import annotations

from collections import Counter

from photo_cleanup import cli, common

DEFAULT_ALBUM = "Documents - Review Me"
DEFAULT_LABELS = {
    "receipt",
    "menu",
    "ticket",
    "barcode",
    "whiteboard",
    "business card",
    "invoice",
    "bill",
    "prescription",
}


def main(argv: list[str] | None = None) -> int:
    parser = cli.base_parser("Find document-like photos (receipts, menus, etc).")
    parser.add_argument(
        "--label",
        action="append",
        default=None,
        metavar="LABEL",
        help="Add a label to the document set. May be repeated. "
        "Defaults to the built-in document label list.",
    )
    args = parser.parse_args(argv)

    labels = set(args.label) if args.label else set(DEFAULT_LABELS)

    ignore = common.load_ignore_albums(args.ignore_album)
    since, until = cli.resolve_date_range(args)
    photosdb = common.get_photosdb()
    photos, stats = common.get_candidate_photos(photosdb, ignore, since=since, until=until)

    print(f"Scanning {len(photos)} photos for labels: {sorted(labels)}")
    print(common.format_skipped(stats))

    doc_photos = []
    label_counts: Counter[str] = Counter()
    for p in photos:
        photo_labels = {label.lower() for label in (p.labels or [])}
        matched = photo_labels.intersection(labels)
        if matched:
            doc_photos.append(p)
            label_counts.update(matched)

    common.print_summary("Document-like photos", doc_photos)

    print("\nLabel breakdown:")
    for label, count in label_counts.most_common():
        print(f"  {count:4d}  {label}")

    print("\nSample photos:")
    for p in doc_photos[:15]:
        matched = {label.lower() for label in (p.labels or [])}.intersection(labels)
        print(f"  {', '.join(matched):30s}  {p.original_filename}")

    common.add_to_album(
        doc_photos,
        args.album_name or DEFAULT_ALBUM,
        dry_run=args.dry_run,
        assume_yes=args.yes,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
