#!/usr/bin/env python3
"""Compare two packed frame streams, in code values rather than bytes.

## Why not `cmp`

`cmp` is the wrong tool here, for two separate reasons.

**The engine is not bit-exact run to run.** Two renders of the same input with the
same configuration differ by roughly 48 bytes of +/-1/255 across a 475-frame 4K
output — floating-point reduction order inside VT's kernels, not a bug. That is
BUILD-DECISIONS.md invariant 18. Byte equality therefore reports failure on a
correct render, which makes it useless as an acceptance test.

**And a global tolerance is the wrong shape too.** Sixteen full-length repeat runs
were compared frame by frame: fifteen agreed to within 1 code step, and one differed
on a *single interval* — two frames of 478, up to 45 code steps, on 1% of their
samples. So "no sample differs by more than 1" fails on a correct render about one
run in ten, and "no sample differs by more than 45" would hide a real error on every
frame but two. The policy this implements is therefore **per-frame with an
allowance**: every sample within `--tolerance`, except at most `--outlier-frames`
frames, which may differ by up to `--outlier-tolerance`. Outliers are always
reported, so an occasional wander is visible rather than swallowed. `--strict`
removes the allowance when the two sides are expected to be identical.

**P010 is not a byte array.** Its 10-bit code lives in the top ten bits of a 16-bit
little-endian word, so the stored word is `code << 6`. One code step is 64 in byte
terms. A byte-wise tolerance of 1 would call a 64-byte difference a pass, and a
byte-wise tolerance of 64 would accept a full code step of error.

So this compares *code values*: the byte itself for NV12, the shifted word for P010.

## Usage

    compare_packed.py A B W H FORMAT [--tolerance N] [--frames N] [--first N]
                                     [--outlier-frames N] [--outlier-tolerance N]
                                     [--strict]

Exit status is 0 when the pair passes the policy, 1 otherwise, so it can be used
directly as a check.
"""

import argparse
import sys

import numpy as np


def load(path, width, height, fmt, first, count):
    """Read up to `count` frames starting at `first`, as code values."""
    if fmt == "nv12":
        frame_size = width * height * 3 // 2
        dtype = np.uint8
        shift = 0
    elif fmt == "p010":
        frame_size = width * height * 3 // 2 * 2
        dtype = np.dtype("<u2")
        shift = 6
    else:
        raise SystemExit(f"unknown format {fmt!r} — expected nv12 or p010")

    with open(path, "rb") as handle:
        total_bytes = handle.seek(0, 2)
        total_frames = total_bytes // frame_size
        # Clamp before reading, not after: asking for a billion frames is an
        # allocation of a billion frames.
        usable = max(0, min(count, total_frames - first))
        if usable == 0:
            raise SystemExit(f"{path}: no frames at offset {first} "
                             f"(the file holds {total_frames})")
        handle.seek(first * frame_size)
        raw = handle.read(usable * frame_size)

    usable = len(raw) // frame_size
    if usable == 0:
        raise SystemExit(f"{path}: short read at offset {first}")
    values = np.frombuffer(raw[: usable * frame_size], dtype=dtype)
    if shift:
        values = values >> shift
    else:
        values = values.astype(np.uint16)
    return values.reshape(usable, -1), total_frames, frame_size


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("a")
    parser.add_argument("b")
    parser.add_argument("width", type=int)
    parser.add_argument("height", type=int)
    parser.add_argument("format", choices=["nv12", "p010"])
    parser.add_argument("--tolerance", type=int, default=1,
                        help="allowed difference in code steps (default 1)")
    parser.add_argument("--frames", type=int, default=None,
                        help="compare at most this many frames")
    parser.add_argument("--first", type=int, default=0,
                        help="start at this frame (default 0)")
    parser.add_argument("--max-report", type=int, default=10,
                        help="how many offending frames to list")
    parser.add_argument("--outlier-tolerance", type=int, default=64,
                        help="a frame may exceed --tolerance up to this much, but "
                             "only --outlier-frames of them may (default 64)")
    parser.add_argument("--outlier-frames", type=int, default=3,
                        help="how many frames are allowed to be outliers (default 3). "
                             "The engine is not bit-exact run to run and occasionally "
                             "deviates by far more than 1 code step on a single "
                             "interval; a global tolerance either fails a correct "
                             "render or hides a real error on every other frame. See "
                             "BUILD-DECISIONS.md invariant 18.")
    parser.add_argument("--strict", action="store_true",
                        help="no outliers at all: every sample within --tolerance")
    args = parser.parse_args()

    if args.strict:
        args.outlier_frames = 0

    a, a_total, a_size = load(args.a, args.width, args.height, args.format,
                              args.first, args.frames or 1 << 30)
    b, b_total, b_size = load(args.b, args.width, args.height, args.format,
                              args.first, args.frames or 1 << 30)

    if a_size != b_size:
        raise SystemExit(f"frame sizes differ: {a_size} vs {b_size}")

    count = min(a.shape[0], b.shape[0])
    if a.shape[0] != b.shape[0]:
        print(f"note: {a.shape[0]} frames in A, {b.shape[0]} in B — comparing {count}")

    # Work in signed 32-bit: a - b on unsigned types wraps and a 0-vs-1023
    # difference would read as 1.
    a = a[:count].astype(np.int32)
    b = b[:count].astype(np.int32)
    diff = np.abs(a - b)

    per_frame_max = diff.max(axis=1)
    # A frame is an outlier when it exceeds the ordinary tolerance, and a violation
    # when it also exceeds what an outlier is allowed to be. Splitting it this way is
    # the whole point: a global tolerance cannot express "one interval may wander".
    outlier = (per_frame_max > args.tolerance)
    violating = (per_frame_max > args.outlier_tolerance)
    over = int((diff > args.tolerance).sum())
    total = int(diff.size)
    worst = int(per_frame_max.max()) if count else 0

    outlier_frames = np.nonzero(outlier)[0]
    violating_frames = np.nonzero(violating)[0]

    print(f"format     : {args.format}, {args.width}x{args.height}, "
          f"{a_size} B/frame")
    print(f"frames     : {count} compared "
          f"(A has {a_total}, B has {b_total})")
    print(f"samples    : {total:,} compared, {over:,} differ by more than "
          f"{args.tolerance} code step(s)")
    print(f"worst      : {worst} code step(s)"
          + ("  <- identical" if worst == 0 else ""))
    print(f"policy     : every sample within {args.tolerance}, except at most "
          f"{args.outlier_frames} frame(s) up to {args.outlier_tolerance}")

    if outlier_frames.size:
        print(f"outliers   : {outlier_frames.size} frame(s) over tolerance")
        for index in outlier_frames[: args.max_report]:
            print(f"  frame {args.first + index}: "
                  f"{int((diff[index] > args.tolerance).sum()):,} samples, "
                  f"worst {int(per_frame_max[index])} step(s)")

    problems = []
    if violating_frames.size:
        problems.append(f"{violating_frames.size} frame(s) exceed even the outlier "
                        f"tolerance of {args.outlier_tolerance}")
    if outlier_frames.size > args.outlier_frames:
        problems.append(f"{outlier_frames.size} outlier frame(s), more than the "
                        f"{args.outlier_frames} allowed")

    if not problems:
        detail = ("identical" if worst == 0
                  else f"within {args.tolerance} code step(s)"
                  if not outlier_frames.size
                  else f"within {args.tolerance} code step(s) apart from "
                       f"{outlier_frames.size} outlier frame(s), worst {worst}")
        print(f"\n[PASS] {detail} — the two paths agree")
        return 0

    print()
    for problem in problems:
        print(f"[FAIL] {problem}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
