"""Run every cleanup pass: dry-run first, then prompt once to apply all."""

from __future__ import annotations

import sys

from photo_cleanup import cli
from photo_cleanup.cleanups import (
    clusters,
    documents,
    heic_estimate,
    low_quality,
    screenshots,
    similar,
)

PASSES = [
    ("Screenshots", screenshots.main),
    ("Low quality", low_quality.main),
    ("Burst clusters", clusters.main),
    ("Documents", documents.main),
    ("Similar photos", similar.main),
]
INFO_ONLY = [("HEIC estimate", heic_estimate.main)]

SUPPRESS_FLAGS = {"--dry-run", "-y", "--yes"}


def _strip_dryrun_yes(argv: list[str]) -> list[str]:
    return [a for a in argv if a not in SUPPRESS_FLAGS]


def _hr(label: str) -> None:
    print(f"\n{'=' * 60}\n{label}\n{'=' * 60}")


def main(argv: list[str] | None = None) -> int:
    parser = cli.base_parser(
        "Run all cleanup passes: dry-run preview first, then prompt once to apply."
    )
    args = parser.parse_args(argv)

    raw_argv = sys.argv[1:] if argv is None else list(argv)
    passthrough = _strip_dryrun_yes(raw_argv)

    _hr("DRY-RUN PREVIEW")
    for label, fn in PASSES + INFO_ONLY:
        print(f"\n--- {label} ---")
        fn([*passthrough, "--dry-run"])

    if not args.yes:
        _hr("APPLY?")
        answer = input("Create albums for all of the above? (y/n): ").strip().lower()
        if answer != "y":
            print("Aborted. No albums created.")
            return 0

    _hr("APPLYING")
    for label, fn in PASSES:
        print(f"\n--- {label} ---")
        fn([*passthrough, "-y"])

    print("\nAll passes complete. Open Photos.app to review the albums.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
