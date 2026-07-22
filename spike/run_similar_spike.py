"""De-risk spike: does Vision's feature-print distance reproduce osxphotos'
fingerprint-based "similar photos" grouping (the last pass not yet proven native)?

Ground truth = what the app already produces: group_similar_fingerprints(all, 70, 4).
  positive pairs = two photos the app groups as duplicates (keeper + extra)
  negative pairs = two photos with clearly-different fingerprints (< 40% similar)
For every involved photo we compute Vision's VNGenerateImageFeaturePrintRequest and
measure pairwise L2 distance, then ask: does small Vision distance separate the
positives from the negatives? If yes, the "similar" pass survives a native rewrite.

Needs Full Disk Access. Run: uv run python spike/run_similar_spike.py
"""

from __future__ import annotations

import base64
import random
import struct
import subprocess
import sys
from pathlib import Path

from photo_cleanup import common

random.seed(0)
MAX_POS = 150  # cap positive pairs (bounds Vision scoring)
MAX_NEG = 300
NEG_MAX_SIM = 40.0  # a pair counts as "clearly different" below this fingerprint similarity


def decode_vec(elem_type: int, count: int, b64: str) -> list[float]:
    raw = base64.b64decode(b64)
    fmt = f"<{count}{'f' if elem_type == 1 else 'd'}"
    return list(struct.unpack(fmt, raw))


def l2(a: list[float], b: list[float]) -> float:
    return sum((x - y) * (x - y) for x, y in zip(a, b, strict=False)) ** 0.5


def auc(pos: list[float], neg: list[float]) -> float:
    """P(positive is more-similar than negative). Score = -distance; rank-based."""
    scores = [(-d, 1) for d in pos] + [(-d, 0) for d in neg]
    scores.sort(key=lambda t: t[0])
    # average ranks
    n = len(scores)
    ranks = [0.0] * n
    i = 0
    while i < n:
        j = i
        while j + 1 < n and scores[j + 1][0] == scores[i][0]:
            j += 1
        avg = (i + j) / 2.0 + 1.0
        for k in range(i, j + 1):
            ranks[k] = avg
        i = j + 1
    rsum_pos = sum(r for r, (_, lbl) in zip(ranks, scores, strict=False) if lbl == 1)
    npos, nneg = len(pos), len(neg)
    return (rsum_pos - npos * (npos + 1) / 2.0) / (npos * nneg)


def main() -> int:
    print("Opening library...", file=sys.stderr)
    db = common.get_photosdb()
    photos = [p for p in db.photos() if p.fingerprint and p.path]
    print(f"{len(photos)} photos have a fingerprint + local file", file=sys.stderr)

    groups = common.group_similar_fingerprints(photos, 70, 4)
    print(f"osxphotos groups {len(groups)} similar clusters", file=sys.stderr)

    # Positive pairs: (keeper, extra) within each app-produced group.
    pos_pairs: list[tuple] = []
    for g in groups:
        for extra in g[1:]:
            pos_pairs.append((g[0], extra))
            if len(pos_pairs) >= MAX_POS:
                break
        if len(pos_pairs) >= MAX_POS:
            break

    if len(pos_pairs) < 10:
        print(
            f"Only {len(pos_pairs)} duplicate pairs in this library — too few to judge "
            "the similar pass. (Not many near-duplicates here.)",
            file=sys.stderr,
        )
        return 1

    # Negative pairs: random, clearly-different fingerprints.
    neg_pairs: list[tuple] = []
    tries = 0
    while len(neg_pairs) < MAX_NEG and tries < MAX_NEG * 50:
        tries += 1
        a, b = random.sample(photos, 2)
        if common.fingerprint_similarity(a.fingerprint, b.fingerprint) < NEG_MAX_SIM:
            neg_pairs.append((a, b))

    # Collect the unique photos we must Vision-score.
    involved = {}
    for a, b in pos_pairs + neg_pairs:
        involved[a.uuid] = a.path
        involved[b.uuid] = b.path
    uuids = list(involved)
    paths = [involved[u] for u in uuids]
    print(
        f"Vision feature-printing {len(paths)} photos "
        f"({len(pos_pairs)} pos / {len(neg_pairs)} neg pairs)...",
        file=sys.stderr,
    )

    probe = Path(__file__).parent / "featureprint_probe.swift"
    proc = subprocess.run(
        ["swift", str(probe)], input="\n".join(paths), capture_output=True, text=True
    )
    lines = proc.stdout.splitlines()
    if proc.returncode != 0 or len(lines) != len(paths):
        print("Swift probe failed:", file=sys.stderr)
        print(proc.stderr[-2000:], file=sys.stderr)
        return 1

    vec: dict[str, list[float]] = {}
    for u, line in zip(uuids, lines, strict=False):
        parts = line.split("\t")
        if parts[0] == "ERR":
            continue
        vec[u] = decode_vec(int(parts[0]), int(parts[1]), parts[2])

    def dist(pair) -> float | None:
        a, b = pair
        if a.uuid in vec and b.uuid in vec:
            return l2(vec[a.uuid], vec[b.uuid])
        return None

    pos_d = [d for p in pos_pairs if (d := dist(p)) is not None]
    neg_d = [d for p in neg_pairs if (d := dist(p)) is not None]
    if len(pos_d) < 10 or len(neg_d) < 10:
        print("Too many probe errors to judge.", file=sys.stderr)
        return 1

    pos_d.sort()
    neg_d.sort()
    med_pos = pos_d[len(pos_d) // 2]
    med_neg = neg_d[len(neg_d) // 2]
    a = auc(pos_d, neg_d)

    # A simple threshold at the negatives' 5th percentile: what fraction of true
    # duplicate pairs fall below it (recall) with ~5% false-positive rate?
    thr = neg_d[max(0, int(len(neg_d) * 0.05) - 1)]
    recall = sum(1 for d in pos_d if d < thr) / len(pos_d)

    print()
    print(f"Duplicate (positive) pairs:  {len(pos_d)}")
    print(f"Different (negative) pairs:  {len(neg_d)}")
    print(f"Median Vision distance:      pos {med_pos:.2f}   vs   neg {med_neg:.2f}")
    print(
        f"Separation AUC:              {a:.3f}   "
        f"(1.0 = Vision perfectly separates duplicates from different photos)"
    )
    print(
        f"Recall @ ~5% false-positive: {recall:.0%}   "
        "(true duplicates caught below a low-FP Vision threshold)"
    )
    print()
    if a >= 0.9 and recall >= 0.6:
        print(
            "VERDICT: Vision feature prints reproduce the similar-pass grouping. "
            "All passes are native-viable — the rewrite is fully de-risked."
        )
    elif a >= 0.75:
        print(
            "VERDICT: Partial. Vision separates most duplicates but the boundary is "
            "softer than Apple's fingerprint; a native similar pass would need a tuned "
            "threshold and would miss some near-duplicates."
        )
    else:
        print(
            "VERDICT: Vision feature prints do NOT reproduce the fingerprint grouping. "
            "The similar pass is the one that degrades in a native rewrite."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
