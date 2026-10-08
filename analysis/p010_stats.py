#!/usr/bin/env python3
"""Report whether a raw P010 stream is *genuinely* 10-bit, or has been flattened.

The point of this tool
----------------------
An 8-bit pipeline that silently claims to be 10-bit looks fine. Every frame
decodes, nothing throws, and the picture is recognisably the right picture. The
only way to catch it is to measure the *precision* of the samples, and there are
two independent tells:

1. **The low six bits of each 16-bit word.** P010 puts the 10-bit code in the top
   ten bits, so the bottom six are always zero. If they are not, the stream is not
   P010 at all — it is 10-bit codes left unshifted, or a different layout.

2. **How many distinct codes appear.** Real 10-bit content fills hundreds to
   thousands of the 1024 levels. Round-trip through 8-bit and you are capped at
   256 distinct values no matter how large the frame is — and worse, the surviving
   values are spread out rather than contiguous, so a histogram shows a comb.
   On a 6.2-megapixel frame, a 200-code result is proof of an 8-bit bottleneck.

The second test is the one that matters, because it survives a pipeline that
correctly *packages* P010 while only ever having 8-bit information in it — which
is exactly the failure mode a "decode 10-bit, do everything in 8-bit, re-pack as
10-bit" path produces.

Usage:
  p010_stats.py FILE [--width 3840] [--height 1632] [--frames 0,50,191]
                     [--label NAME] [--quiet]
"""
import argparse
import os
import sys

import numpy as np

LUMA_WORDS_PER_FRAME = None  # set in main


def read_luma(path, frame, width, height, subsample=4):
    """Return the luma plane of one frame as uint16 codes (shifted down).

    Subsamples rows and columns by `subsample` — the statistics below are all
    distributional, so a 1-in-16 sample of 6.2 M pixels is plenty and keeps a
    192-frame pass to a few seconds.
    """
    frame_words = width * height * 3 // 2
    offset = frame * frame_words * 2
    luma_bytes = width * height * 2
    with open(path, "rb") as f:
        f.seek(offset)
        raw = f.read(luma_bytes)
    if len(raw) < luma_bytes:
        raise EOFError(f"frame {frame}: wanted {luma_bytes} luma bytes, got {len(raw)}")

    words = np.frombuffer(raw, dtype="<u2").reshape(height, width)
    words = words[::subsample, ::subsample]
    return words


def describe(words, width, height, subsample):
    """All the measurements, from one subsampled luma plane."""
    flat = words.ravel()
    codes = (flat >> 6).astype(np.int32)

    low_bits = flat & 0x3F
    violations = int(np.count_nonzero(low_bits))

    distinct = int(np.unique(codes).size)
    # If the content ever passed through 8-bit, every code is ~4k. Real 10-bit
    # content hits a multiple of 4 about a quarter of the time by chance.
    on_multiple_of_4 = float(np.count_nonzero((codes & 3) == 0)) / codes.size

    return {
        "samples": int(codes.size),
        "low_bit_violations": violations,
        "low_bit_violation_rate": violations / flat.size,
        "distinct_codes": distinct,
        "on_multiple_of_4": on_multiple_of_4,
        "min": int(codes.min()),
        "max": int(codes.max()),
        "mean": float(codes.mean()),
        "p01": float(np.percentile(codes, 1)),
        "p50": float(np.percentile(codes, 50)),
        "p99": float(np.percentile(codes, 99)),
        "p999": float(np.percentile(codes, 99.9)),
        "unique_ratio": distinct / codes.size,
    }


def verdict(s):
    """A one-line judgement, and whether it is a pass."""
    if s["low_bit_violation_rate"] > 0.001:
        return (False, f"NOT P010 — {s['low_bit_violation_rate']*100:.2f}% of words "
                       f"have non-zero low bits (the code is not in the top ten bits)")
    if s["distinct_codes"] <= 256:
        return (False, f"8-BIT BOTTLENECK — only {s['distinct_codes']} distinct codes; "
                       f"10-bit content would fill many more")
    if s["on_multiple_of_4"] > 0.75:
        return (False, f"8-BIT DERIVED — {s['on_multiple_of_4']*100:.1f}% of codes are "
                       f"multiples of 4 (chance is ~25%)")
    return (True, f"genuine 10-bit — {s['distinct_codes']} distinct codes, "
                  f"{s['on_multiple_of_4']*100:.1f}% on multiples of 4 (chance ~25%)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("--width", type=int, default=3840)
    ap.add_argument("--height", type=int, default=1632)
    ap.add_argument("--frames", default=None,
                    help="comma-separated frame indices, or a range like 0-191")
    ap.add_argument("--count", type=int, default=6, help="frames to sample if --frames absent")
    ap.add_argument("--subsample", type=int, default=4)
    ap.add_argument("--label", default=None)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    width, height = args.width, args.height
    frame_bytes = width * height * 3
    size = os.path.getsize(args.path)
    n_frames = size // frame_bytes
    if size % frame_bytes:
        print(f"warning: {args.path} is not a whole number of frames "
              f"({size} % {frame_bytes} = {size % frame_bytes} bytes left over)",
              file=sys.stderr)

    label = args.label or os.path.basename(args.path)
    print(f"=== {label} ===")
    print(f"file   : {size:,} B  |  {frame_bytes:,} B/frame  |  {n_frames} frames  "
          f"|  {width}x{height}")

    if args.frames:
        if "-" in args.frames:
            lo, hi = (int(v) for v in args.frames.split("-"))
            wanted = list(range(lo, min(hi + 1, n_frames)))
        else:
            wanted = [int(v) for v in args.frames.split(",")]
    else:
        step = max(1, n_frames // args.count)
        wanted = list(range(0, n_frames, step))[:args.count]

    wanted = [f for f in wanted if 0 <= f < n_frames]
    if not wanted:
        print("no frames to read", file=sys.stderr)
        return 2

    rows = []
    for frame in wanted:
        words = read_luma(args.path, frame, width, height, args.subsample)
        rows.append((frame, describe(words, width, height, args.subsample)))

    if not args.quiet:
        print()
        print(f"{'frame':>6} {'distinct':>9} {'%x4':>6} {'min':>5} {'p01':>6} {'p50':>7} "
              f"{'p99':>6} {'p99.9':>6} {'max':>5} {'lowbits':>8}")
        for frame, s in rows:
            print(f"{frame:>6} {s['distinct_codes']:>9} {s['on_multiple_of_4']*100:>5.1f}% "
                  f"{s['min']:>5} {s['p01']:>6.0f} {s['p50']:>7.0f} {s['p99']:>6.0f} "
                  f"{s['p999']:>6.0f} {s['max']:>5} "
                  f"{s['low_bit_violations']:>8}")

    worst = min(rows, key=lambda r: r[1]["distinct_codes"])[1]
    best = max(rows, key=lambda r: r[1]["distinct_codes"])[1]
    ok, why = verdict(worst)
    ok_best, why_best = verdict(best)

    print()
    print(f"codes  : {worst['distinct_codes']}..{best['distinct_codes']} distinct "
          f"(of 1024 possible)")
    print(f"range  : {min(s['min'] for _, s in rows)}..{max(s['max'] for _, s in rows)}")
    print(f"low 6b : {max(s['low_bit_violation_rate'] for _, s in rows)*100:.4f}% non-zero "
          f"(must be 0.0000%)")
    print(f"[{'PASS' if ok and ok_best else 'FAIL'}] {why if not ok else why_best}")
    return 0 if (ok and ok_best) else 1


if __name__ == "__main__":
    sys.exit(main())
