"""Spike: does Vision's native aesthetics score reproduce osxphotos' curation score?

Samples N photos from the real library, scores each two ways —
  osxphotos: photo.score.overall  (Apple's private curation score, what the app uses)
  Vision:    VNCalculateImageAestheticsScoresRequest.overallScore  (native, App-Store-legal)
— then reports Spearman rank correlation and, more importantly, whether Vision's
worst-decile overlaps osxphotos' worst-decile (the set the low-quality pass would flag).

Needs Full Disk Access on the running terminal (reads Photos.sqlite + originals).
Run: uv run python spike/run_spike.py [N]
"""

from __future__ import annotations

# Deterministic sample without importing random's global state surprises.
import random
import subprocess
import sys
from pathlib import Path

from photos_cleanup import library as common

N = int(sys.argv[1]) if len(sys.argv) > 1 else 300
random.seed(0)


def ranks(vals: list[float]) -> list[float]:
    """Average ranks (1-based), ties share the mean rank."""
    order = sorted(range(len(vals)), key=lambda i: vals[i])
    r = [0.0] * len(vals)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and vals[order[j + 1]] == vals[order[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            r[order[k]] = avg
        i = j + 1
    return r


def pearson(x: list[float], y: list[float]) -> float:
    n = len(x)
    mx, my = sum(x) / n, sum(y) / n
    cov = sum((a - mx) * (b - my) for a, b in zip(x, y, strict=False))
    vx = sum((a - mx) ** 2 for a in x) ** 0.5
    vy = sum((b - my) ** 2 for b in y) ** 0.5
    return cov / (vx * vy) if vx and vy else 0.0


def spearman(x: list[float], y: list[float]) -> float:
    return pearson(ranks(x), ranks(y))


def main() -> int:
    print("Opening library...", file=sys.stderr)
    db = common.get_photosdb()

    scored: list[tuple[str, str, float]] = []  # (uuid, path, osxphotos_score)
    for p in db.photos():
        s = common.get_photo_score(p)
        path = p.path  # original on disk; None if iCloud-only / not downloaded
        if s is not None and path:
            scored.append((p.uuid, path, s))

    print(f"{len(scored)} photos have both a local file and an osxphotos score", file=sys.stderr)
    if len(scored) > N:
        scored = random.sample(scored, N)
    if not scored:
        print("Nothing to score — is Full Disk Access granted to this terminal?", file=sys.stderr)
        return 1

    probe = Path(__file__).parent / "aesthetics_probe.swift"
    print(f"Vision-scoring {len(scored)} photos (first run compiles the probe)...", file=sys.stderr)
    proc = subprocess.run(
        ["swift", str(probe)],
        input="\n".join(path for _, path, _ in scored),
        capture_output=True,
        text=True,
    )
    lines = proc.stdout.splitlines()
    if proc.returncode != 0 or len(lines) != len(scored):
        print("Swift probe failed:", file=sys.stderr)
        print(proc.stderr[-2000:], file=sys.stderr)
        return 1

    # Join by index (probe emits one line per input line, in order).
    osx: list[float] = []
    vis: list[float] = []
    uuids: list[str] = []
    utility = 0
    errors = 0
    for (uuid, _, s), line in zip(scored, lines, strict=False):
        parts = line.split("\t")
        if parts[0] == "ERR":
            errors += 1
            continue
        osx.append(s)
        vis.append(float(parts[0]))
        uuids.append(uuid)
        utility += int(parts[1])

    m = len(osx)
    if m < 10:
        print(f"Only {m} usable pairs ({errors} probe errors) — too few to judge.", file=sys.stderr)
        return 1

    rho = spearman(osx, vis)
    r = pearson(osx, vis)

    # Decision metric: does Vision flag the same worst photos the app would delete?
    k = max(1, m // 10)
    osx_worst = {uuids[i] for i in sorted(range(m), key=lambda i: osx[i])[:k]}
    vis_worst = {uuids[i] for i in sorted(range(m), key=lambda i: vis[i])[:k]}
    overlap = len(osx_worst & vis_worst)
    recall = overlap / k

    print()
    print(f"Paired photos:        {m}   (probe errors: {errors})")
    print(f"Spearman rho:         {rho:+.3f}   (rank agreement; +1 = identical ordering)")
    print(f"Pearson r:            {r:+.3f}")
    print(
        f"Worst-decile recall:  {overlap}/{k} = {recall:.0%}   "
        f"(Vision's worst {k} vs osxphotos' worst {k})"
    )
    print(f"isUtility flagged:    {utility}/{m}   (Vision's screenshot/doc/receipt signal)")
    print()
    if rho >= 0.6 and recall >= 0.5:
        print("VERDICT: Vision reproduces the ranking. Native rewrite viable — drop osxphotos.")
    elif rho >= 0.3:
        print(
            "VERDICT: Partial agreement. Vision tracks the trend but reflags a different set; "
            "a native low-quality pass would need its own threshold tuning."
        )
    else:
        print(
            "VERDICT: Different signals. osxphotos' score is not replaceable by Vision "
            "aesthetics — the App-Store rewrite loses the low-quality pass."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
