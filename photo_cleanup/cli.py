"""Shared argparse helpers for cleanup scripts."""

from __future__ import annotations

import argparse
import re
from datetime import UTC, datetime, timedelta

_DURATION_RE = re.compile(r"^(\d+)\s*([dwmy])$")
_DURATION_DAYS = {"d": 1, "w": 7, "m": 30, "y": 365}


def parse_duration(value: str) -> timedelta:
    """Parse '30d', '6w', '3m', '1y' into a timedelta. Months/years are nominal."""
    m = _DURATION_RE.match(value.strip().lower())
    if not m:
        raise argparse.ArgumentTypeError(
            f"invalid duration {value!r}; use forms like 30d, 6w, 3m, 1y"
        )
    return timedelta(days=int(m.group(1)) * _DURATION_DAYS[m.group(2)])


def parse_date(value: str) -> datetime:
    """Parse YYYY-MM-DD into a UTC datetime at midnight."""
    try:
        return datetime.strptime(value, "%Y-%m-%d").replace(tzinfo=UTC)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid date {value!r}; use YYYY-MM-DD") from exc


def resolve_date_range(args) -> tuple[datetime | None, datetime | None]:
    """Collapse --since / --until / --last into (since, until) datetimes."""
    last: timedelta | None = args.last
    if last is not None:
        now = datetime.now(UTC)
        return now - last, now
    return args.since, args.until


def base_parser(description: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report results but do not create/modify any albums",
    )
    parser.add_argument(
        "-y",
        "--yes",
        action="store_true",
        help="Skip confirmation prompt before creating albums",
    )
    parser.add_argument(
        "--album-name",
        default=None,
        help="Override the default album name",
    )
    parser.add_argument(
        "--ignore-album",
        action="append",
        default=[],
        metavar="NAME",
        help="Treat additional album as 'system' (skip its photos). May be repeated.",
    )

    range_group = parser.add_argument_group("date range")
    exclusive = range_group.add_mutually_exclusive_group()
    exclusive.add_argument(
        "--since",
        type=parse_date,
        default=None,
        metavar="YYYY-MM-DD",
        help="Only consider photos taken on or after this date",
    )
    exclusive.add_argument(
        "--last",
        type=parse_duration,
        default=None,
        metavar="N{d,w,m,y}",
        help="Only consider photos in the last N days/weeks/months/years (e.g. 3m). "
        "Mutually exclusive with --since.",
    )
    range_group.add_argument(
        "--until",
        type=parse_date,
        default=None,
        metavar="YYYY-MM-DD",
        help="Only consider photos taken on or before this date",
    )
    return parser
