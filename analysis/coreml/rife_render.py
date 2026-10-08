#!/usr/bin/env python3
"""Real-content renderer: raw RGB24 in -> CoreML RIFE -> raw RGB24 out.

Half of the A/B instrument. It shares the phase plan with vt_render.swift so both
engines see identical source pairs and identical phases, which is the only way the
comparison means anything.

WHY RGB24 IN/OUT AND NOT YUV
----------------------------
The first version of this script did the NV12 -> RGB conversion in numpy. That was
a mistake worth recording:

  - RIFE requires RGB float32. A 4:2:0 source must therefore be converted, and
    converted back afterwards. That round trip is a REAL cost of the RIFE tier -
    VTFrameProcessor never pays it because it works in YUV natively.
  - But doing that conversion by hand in numpy made it far worse than it needs to
    be. Measured on the same clip:
        numpy conversion, clipping to [0,1]  -> 2.42 mean luma error
        numpy conversion, no clipping        -> 0.0018 mean luma error
        ffmpeg's own conversion              -> 0.205  mean luma error
  - The trap was assuming limited-range chroma. This clip's chroma is full-range;
    assuming otherwise put 97.6% of pixels outside [0,1] before clipping, and the
    clip then destroyed the luma that the chroma was carrying.

So ffmpeg owns the colour work: it reads the real metadata from the container
instead of guessing, and its round trip is 12x better than the hand-rolled one.
This script therefore moves RGB24 and knows nothing about colour.

Two hard-won rules it still encodes:
  - compute_units must be CPU_AND_GPU. The CoreML default (.all) is 8x slower,
    because the planner parks convolutions on the ANE and pays per-op transfers.
  - Frames must be padded to a multiple of 64, not 16: IFBlock.conv0 does two
    stride-2 convs at scale=16, so H/16 must be divisible by 4.

Usage:
  rife_render.py IN.rgb24 W H SRC_FPS OUT_FPS OUT.rgb24 [--model P] [--max-frames N]
"""
import argparse
import os
import sys
import time
from fractions import Fraction

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------- phase plan
# Mirrors vt_render.swift exactly. EXACT integer arithmetic - no epsilon.
#
#   t = k * (src_num/src_den) / (out_num/out_den)
#     = k * src_num * out_den / (src_den * out_num)
#
# An output frame is a pure passthrough when that ratio is an integer, i.e. when
# the remainder is exactly zero. 23.976 -> 59.94 is exactly 2.5x, so that is
# every 5th frame: 20% of the output needs no interpolation at all.
#
# The first version of this did it in floating point with an epsilon, on the
# theory that 0.9999999998 should count as 0. That was the wrong fix. Feeding
# 23.976024 and 59.94 gives a ratio of 0.4000004, not 0.4, so the fractional
# part drifts 4e-7 per frame and the epsilon is blown by k=5. Result: 1
# passthrough instead of 95, and 20% more inference than necessary.
def parse_rate(s):
    """'24000/1001' or '23.976' -> Fraction."""
    s = str(s).strip()
    if "/" in s:
        n, d = s.split("/")
        return Fraction(int(n), int(d))
    return Fraction(s)


def build_plan(n_frames, src_rate, out_rate):
    src_rate, out_rate = parse_rate(src_rate), parse_rate(out_rate)
    pnum = src_rate.numerator * out_rate.denominator
    pden = src_rate.denominator * out_rate.numerator
    plan = [[] for _ in range(n_frames)]
    k = 0
    while True:
        t = k * pnum
        j, rem = divmod(t, pden)
        if j >= n_frames - 1:
            break
        if rem == 0:
            plan[j].append((k, 0, 0.0))          # exact passthrough, frame j
        else:
            plan[j].append((k, -1, rem / pden))
        k += 1
    return plan, k


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("width", type=int)
    ap.add_argument("height", type=int)
    ap.add_argument("src_fps", type=str,
                    help="source rate: decimal or exact rational, e.g. 24000/1001")
    ap.add_argument("out_fps", type=str,
                    help="output rate: decimal or exact rational, e.g. 60000/1001")
    ap.add_argument("output")
    ap.add_argument("--model", default=None)
    ap.add_argument("--max-frames", type=int, default=None)
    ap.add_argument("--interp-width", type=int, default=None,
                    help="interpolate at this width instead of native (preview mode)")
    ap.add_argument("--interp-height", type=int, default=None,
                    help="interpolate at this height instead of native (preview mode)")
    args = ap.parse_args()

    import coremltools as ct

    w, h = args.width, args.height
    frame_size = w * h * 3

    n = os.path.getsize(args.input) // frame_size
    if args.max_frames:
        n = min(n, args.max_frames)
    if n < 2:
        sys.exit(f"need >= 2 frames, found {n}")

    iw = args.interp_width or w
    ih = args.interp_height or h
    pw = (iw + 63) // 64 * 64
    ph = (ih + 63) // 64 * 64

    model_path = args.model or os.path.join(
        HERE, "build", f"rife425_{pw}x{ph}_fp16.mlpackage")
    model_path = os.path.abspath(model_path)
    if not os.path.isdir(model_path):
        sys.exit(
            f"no CoreML model at {model_path}\n"
            f"convert one first:\n"
            f"  python convert_rife.py --height {ph} --width {pw} --precision fp16")

    print(f"input  : {n} frames  {w}x{h} rgb24  src {args.src_fps} -> out {args.out_fps}",
          file=sys.stderr)
    print(f"model  : {model_path}", file=sys.stderr)
    print(f"interp : {iw}x{ih}  padded to {pw}x{ph}", file=sys.stderr)

    plan, total_out = build_plan(n, args.src_fps, args.out_fps)
    n_pass = sum(1 for f in plan for x in f if x[1] >= 0)
    n_interp = total_out - n_pass
    print(f"plan   : {total_out} out frames = {n_interp} interpolated + {n_pass} passthrough",
          file=sys.stderr)

    model = ct.models.MLModel(model_path, compute_units=ct.ComputeUnit.CPU_AND_GPU)

    fin = open(args.input, "rb")
    fout = open(args.output, "wb")
    cache = {}

    def load_chw(idx):
        """Read frame idx, scale/downsample to the interpolation size, pad, and
        return a contiguous NCHW float32 tensor ready for the model."""
        if idx in cache:
            return cache[idx]
        fin.seek(idx * frame_size)
        raw = fin.read(frame_size)
        if len(raw) != frame_size:
            raise EOFError(f"short read at frame {idx}")
        img = np.frombuffer(raw, np.uint8).reshape(h, w, 3).astype(np.float32) / 255.0
        if (iw, ih) != (w, h):
            ys = (np.arange(ih) * h / ih).astype(int).clip(0, h - 1)
            xs = (np.arange(iw) * w / iw).astype(int).clip(0, iw - 1)
            img = img[ys][:, xs]
        img = np.pad(img, ((0, ph - ih), (0, pw - iw), (0, 0)), mode="edge")
        t = np.ascontiguousarray(img.transpose(2, 0, 1))[None]
        cache[idx] = t
        if len(cache) > 4:
            for k in sorted(cache)[:-2]:
                del cache[k]
        return t

    def write_raw(idx):
        fin.seek(idx * frame_size)
        fout.write(fin.read(frame_size))

    t0 = time.perf_counter()
    errors = 0
    done = 0
    for j in range(n - 1):
        frames = plan[j]
        if not frames:
            continue
        interp = [(k, p) for (k, s, p) in frames if s < 0]
        for (k, s, _p) in frames:
            if s >= 0:
                write_raw(j if s == 0 else j + 1)
                done += 1
        if not interp:
            continue

        a = load_chw(j)
        b = load_chw(j + 1)
        for (k, phase) in interp:
            inp = {"img0": a, "img1": b,
                   "timestep": np.full((1, 1, 1, 1), phase, np.float32)}
            try:
                out = model.predict(inp)
            except Exception as e:                       # noqa: BLE001
                errors += 1
                print(f"predict failed @k={k}: {e}", file=sys.stderr)
                continue
            key = list(out.keys())[0]
            rgb = out[key][0].transpose(1, 2, 0)[:ih, :iw]
            if (iw, ih) != (w, h):
                ys = (np.arange(h) * ih / h).astype(int).clip(0, ih - 1)
                xs = (np.arange(w) * iw / w).astype(int).clip(0, iw - 1)
                rgb = rgb[ys][:, xs]
            q = np.clip(rgb, 0.0, 1.0) * 255.0
            fout.write(np.rint(q).astype(np.uint8).tobytes())
            done += 1
        if j % 25 == 0:
            el = time.perf_counter() - t0
            print(f"  ..interval {j}/{n-1}  {done}/{total_out} frames  {el:.1f}s",
                  file=sys.stderr)

    wall = time.perf_counter() - t0
    fout.close()
    fin.close()
    print(f"frames : wrote {done} / expected {total_out}  errors {errors}", file=sys.stderr)
    print(f"RESULT rife_render {iw}x{ih} (padded {pw}x{ph}) {args.src_fps}->{args.out_fps}"
          f" | {total_out} out frames | wall {wall:.2f}s | OUTPUT {total_out/wall:6.1f} fps"
          f" | {wall*1000/max(n_interp,1):6.2f} ms/call", file=sys.stderr)


if __name__ == "__main__":
    main()
