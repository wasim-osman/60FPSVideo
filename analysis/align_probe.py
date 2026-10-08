#!/usr/bin/env python3
"""Find the frame offset that aligns two raw clips of the same content.

Why this exists
---------------
Two extractions of "the same" segment are not guaranteed to start on the same
source frame. `ffmpeg -ss T -i SRC` seeks to a keyframe and then decodes forward,
and which frame it lands on depends on how the timestamp rounds — so an SDR
extraction and an HDR extraction of the same `-ss` value can differ by a frame
without either being wrong.

That matters here because the scene-change detector reported the same five cuts
one frame apart between the 8-bit and 10-bit versions of the same segment. A
constant offset across every cut is the signature of a *misaligned pair of
files*, not of a detection difference — but "is the signature of" is not
evidence. This measures it.

Method: normalise both luma planes to 0...1 (each by its own format's maximum
code value, which is what makes them comparable at all), then for each candidate
offset score the overlapping frame pairs two ways.

Raw mean absolute difference is the obvious metric and it is a *weak* one here:
one clip is a tone map of the other, so the two differ by a monotone curve at
every pixel and the offset signal is buried under that. Correlation is far
better suited, because it is invariant to any affine change of value — and a
tone curve is close enough to affine locally that the true alignment stands out
clearly. Both are reported; the correlation is the one to trust.

The alignment is the offset that maximises correlation. The *shape* of the curve
matters as much as the peak: a sharp well means real alignment, a flat curve
means the two clips are not the same content.

Usage:
  align_probe.py A B --format-a nv12 --format-b p010 --width 3840 --height 1632
                     [--frames 24] [--range 4]
"""
import argparse
import sys

import numpy as np

FORMATS = {
    # name: (bytes per sample, maximum code value)
    "nv12": (1, 255),
    "p010": (2, 1023),
}


def frame_bytes(fmt, width, height):
    return width * height * 3 // 2 * FORMATS[fmt][0]


def read_luma(path, frame, fmt, width, height, subsample):
    """One frame's luma plane, normalised to 0...1."""
    _, full_scale = FORMATS[fmt]
    bytes_per_sample = FORMATS[fmt][0]
    luma_bytes = width * height * bytes_per_sample
    offset = frame * frame_bytes(fmt, width, height)

    with open(path, "rb") as f:
        f.seek(offset)
        raw = f.read(luma_bytes)
    if len(raw) < luma_bytes:
        raise EOFError(f"{path}: frame {frame} is past the end")

    dtype = "<u2" if bytes_per_sample == 2 else "u1"
    plane = np.frombuffer(raw, dtype=dtype).reshape(height, width)
    plane = plane[::subsample, ::subsample].astype(np.float32)
    if bytes_per_sample == 2:
        # P010: the code is in the top ten bits. Read it raw and every number is
        # 64x too big — and the comparison below would still "work", just on the
        # wrong values, so this shift is load-bearing.
        plane = np.floor(plane / 64.0)
    return plane / full_scale


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--format-a", default="nv12", choices=sorted(FORMATS))
    ap.add_argument("--format-b", default="p010", choices=sorted(FORMATS))
    ap.add_argument("--width", type=int, default=3840)
    ap.add_argument("--height", type=int, default=1632)
    ap.add_argument("--frames", type=int, default=24)
    ap.add_argument("--range", type=int, default=4, help="test offsets -N..+N")
    ap.add_argument("--subsample", type=int, default=8)
    args = ap.parse_args()

    n = args.range
    # Read one extra frame at each end so every offset has the same number of
    # overlapping pairs — otherwise the curve is biased toward the middle.
    a_frames = [read_luma(args.a, f, args.format_a, args.width, args.height, args.subsample)
                for f in range(args.frames)]
    b_frames = [read_luma(args.b, f, args.format_b, args.width, args.height, args.subsample)
                for f in range(args.frames + 2 * n)]

    print(f"a: {args.a}  ({args.format_a}, {len(a_frames)} frames)")
    print(f"b: {args.b}  ({args.format_b}, {len(b_frames)} frames)")
    print()
    print(f"{'offset':>7} {'corr':>8} {'mean|diff|':>11}   (a[i] vs b[i+offset])")

    mae_curve, corr_curve = {}, {}
    for offset in range(-n, n + 1):
        maes, corrs = [], []
        for i, a in enumerate(a_frames):
            j = i + n + offset          # +n because b_frames is padded at the front
            if 0 <= j < len(b_frames):
                b = b_frames[j]
                maes.append(float(np.abs(a - b).mean()))
                av, bv = a.ravel() - a.mean(), b.ravel() - b.mean()
                denom = float(np.sqrt((av * av).sum() * (bv * bv).sum()))
                # A flat plane has no variance to correlate; treat it as no
                # information rather than as a perfect match.
                corrs.append(float((av * bv).sum()) / denom if denom > 1e-9 else 0.0)
        mae_curve[offset] = sum(maes) / len(maes)
        corr_curve[offset] = sum(corrs) / len(corrs)

    best = max(corr_curve, key=corr_curve.get)
    lo, hi = min(corr_curve.values()), max(corr_curve.values())
    for offset in sorted(corr_curve):
        c = corr_curve[offset]
        marker = "  <-- best" if offset == best else ""
        # Longer bar = better correlation.
        frac = (c - lo) / max(1e-9, hi - lo)
        bar = "#" * max(1, int(60 * frac))
        print(f"{offset:>+7} {c:>8.4f} {mae_curve[offset]:>11.5f}   {bar}{marker}")

    spread = hi - lo
    print()
    print(f"best offset : {best:+d}   correlation {corr_curve[best]:.4f}")
    if spread < 1e-3:
        print("[INCONCLUSIVE] the correlation curve is flat — "
              "these may not be the same content")
        return 1

    # Sharpness is judged against the *immediate neighbours*, not against the whole
    # range. The range includes a long decaying tail — correlation falls off
    # smoothly as frames drift apart, because adjacent frames of real footage are
    # similar to each other — and measuring the peak against that tail would call
    # a perfectly good alignment "broad" purely because the content is continuous.
    # What makes an alignment real is that stepping one frame either way makes
    # things clearly worse.
    neighbours = [corr_curve[o] for o in (best - 1, best + 1) if o in corr_curve]
    if not neighbours:
        print("[INCONCLUSIVE] only one offset was tested")
        return 1
    runner_up = max(neighbours)
    margin = corr_curve[best] - runner_up
    sharp = margin > 0.02
    print(f"neighbours  : {runner_up:.4f}   (margin {margin:+.4f})")
    print(f"[{'OK' if sharp else 'WEAK'}] alignment is "
          f"{'clear' if sharp else 'ambiguous'}"
          + ("" if sharp else " — the peak does not stand out from its neighbours"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
