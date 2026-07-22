"""Estimate space savings from converting JPEG/PNG photos to HEIC.

Read-only: reports projected savings only. Actual conversion should go through
Photos app (File → Export → HEIC) so the library database stays consistent.
"""

from __future__ import annotations

from photo_cleanup import cli, common

ASSUMED_HEIC_RATIO = 0.5


def main(argv: list[str] | None = None) -> int:
    parser = cli.base_parser("Estimate HEIC conversion savings (read-only).")
    parser.add_argument(
        "--ratio",
        type=float,
        default=ASSUMED_HEIC_RATIO,
        help=f"Assumed HEIC size as fraction of original. Apple cites ~0.5 vs "
        f"JPEG at equivalent quality; treat as a rough estimate. "
        f"(default: {ASSUMED_HEIC_RATIO})",
    )
    args = parser.parse_args(argv)

    ignore = common.load_ignore_albums(args.ignore_album)
    since, until = cli.resolve_date_range(args)
    photosdb = common.get_photosdb()
    photos, stats = common.get_candidate_photos(photosdb, ignore, since=since, until=until)

    print(f"Scanning {len(photos)} photos for conversion potential...")
    print(common.format_skipped(stats))

    if not photos:
        print("\nNo photos found to convert.")
        return 0

    current_bytes = sum(p.original_filesize or 0 for p in photos)
    estimated_bytes = current_bytes * args.ratio

    current_mb = current_bytes / 1024 / 1024
    heic_mb = estimated_bytes / 1024 / 1024
    savings_mb = current_mb - heic_mb
    savings_pct = (savings_mb / current_mb * 100) if current_mb > 0 else 0

    print("\nHEIC Conversion Estimate:")
    print(f"  Convertible photos: {len(photos)}")
    print(f"  Current total size: {current_mb:.1f} MB")
    print(f"  Estimated HEIC size: {heic_mb:.1f} MB")
    print(f"  Potential savings: {savings_mb:.1f} MB ({savings_pct:.0f}%)")

    print("\nNotes:")
    print("  - Convert via Photos app: File -> Export -> Format: HEIC")
    print("  - WhatsApp auto-converts HEIC to JPEG when sharing")
    print("  - macOS/iOS handle HEIC natively; Windows may need a viewer")
    print("  - Do NOT replace files inside Photos Library.photoslibrary directly:")
    print("    it corrupts the SQLite database. Always export, convert, re-import.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
