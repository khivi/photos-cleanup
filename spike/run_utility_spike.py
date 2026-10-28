"""Spike: can the on-device Foundation Models split Vision's isUtility bucket
into keep vs delete?

Samples N local photos, lets utility_probe.swift gate on isUtility and ask the
model for a verdict on each utility photo, then writes an HTML contact sheet
(image + kind + keep/delete + reason) so the calls can be judged by eye.

Needs Full Disk Access on the running terminal, macOS 27+, Apple Intelligence on.
Run: uv run python spike/run_utility_spike.py [N]
"""

from __future__ import annotations

import html
import random
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

from photos_cleanup import library as common

N = int(sys.argv[1]) if len(sys.argv) > 1 else 300
random.seed(0)


def main() -> int:
    print("Opening library...", file=sys.stderr)
    db = common.get_photosdb()
    photos = sorted(
        (p.path, p.date.date().isoformat()) for p in db.photos() if p.path and not p.ismovie
    )
    if not photos:
        print("Nothing to scan — is Full Disk Access granted to this terminal?", file=sys.stderr)
        return 1
    if len(photos) > N:
        photos = random.sample(photos, N)

    probe = Path(__file__).parent / "utility_probe.swift"
    print(f"Probing {len(photos)} photos (~20% expected utility, ~2s each)...", file=sys.stderr)
    proc = subprocess.run(
        ["swift", str(probe)],
        input="\n".join(f"{path}\t{date}" for path, date in photos),
        capture_output=True,
        text=True,
    )
    lines = proc.stdout.splitlines()
    if proc.returncode != 0 or len(lines) != len(photos):
        print("Swift probe failed:", file=sys.stderr)
        print(proc.stderr[-2000:], file=sys.stderr)
        return 1

    rows = []
    errors = 0
    for (path, date), line in zip(photos, lines, strict=True):
        parts = line.split("\t")
        if parts[0] == "SKIP":
            continue
        if parts[0] == "ERR":
            errors += 1
            continue
        rows.append((path, date, parts[0], parts[1] == "1", parts[2]))

    kinds = Counter(r[2] for r in rows)
    deletes = sum(not r[3] for r in rows)
    print()
    print(f"Scanned:   {len(photos)}   utility: {len(rows)}   errors: {errors}")
    print(f"Verdicts:  delete {deletes} / keep {len(rows) - deletes}")
    print(f"Kinds:     {dict(kinds.most_common())}")

    # Delete suggestions first — those are the calls that matter.
    rows.sort(key=lambda r: (r[3], r[2]))
    cards = "\n".join(
        f'<div class="c {"keep" if keep else "del"}"><img src="file://{html.escape(path)}">'
        f"<b>{'KEEP' if keep else 'DELETE'}</b> · {html.escape(kind)} · {date}"
        f"<br>{html.escape(reason)}</div>"
        for path, date, kind, keep, reason in rows
    )
    page = f"""<!doctype html><meta charset="utf-8"><title>utility spike</title>
<style>body{{font:13px -apple-system;display:flex;flex-wrap:wrap;gap:8px}}
.c{{width:220px;padding:6px;border:3px solid}}.del{{border-color:#d33}}.keep{{border-color:#3a3}}
img{{width:100%;height:220px;object-fit:contain;background:#eee}}</style>{cards}"""
    out = Path(tempfile.gettempdir()) / "utility_spike.html"
    out.write_text(page)
    print(f"Report:    {out}")
    # Safari, not the default browser: it is the one that renders HEIC originals.
    subprocess.run(["open", "-a", "Safari", str(out)])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
