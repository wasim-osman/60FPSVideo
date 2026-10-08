#!/usr/bin/env python3
"""
ab_range_probe.py - is the measured VT-vs-RIFE difference REAL, or an artefact
of how the two buffers are interpreted?

Red flag: output frame k=0 is a *passthrough* frame. Both engines should emit
source frame 0 verbatim, so the difference there should be ~0. It measured 12.9.
That is a systematic offset, not an algorithmic disagreement.

Prime suspect: range. VT writes NV12, whose Y plane is studio/limited range
(16..235). RIFE writes rgb24, which ffmpeg expands to full range (0..255). If so,
every dark pixel differs by ~16/255 and the whole comparison is invalid.

This probe:
  1. prints the black/white points of each buffer
  2. fits luma_rife = a * y_vt + b  (a ~ 255/219 = 1.164, b ~ -18.7 => range mismatch)
  3. recomputes the MAE after range-normalising VT, and reports how much of the
     apparent difference survives
"""

import argparse
import numpy as np


def read_frame(path, frame_bytes, index):
    with open(path, "rb") as f:
        f.seek(frame_bytes * index)
        buf = f.read(frame_bytes)
    assert len(buf) == frame_bytes, f"short read at {index}"
    return np.frombuffer(buf, dtype=np.uint8)


def rgb24_luma(raw, w, h):
    a = raw.reshape(h, w, 3).astype(np.float32)
    return 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vt", required=True)
    ap.add_argument("--rife", required=True)
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--frames", default="0,254,1")
    args = ap.parse_args()

    w, h = args.width, args.height
    vt_fb, rgb_fb = w * h * 3 // 2, w * h * 3

    for k in [int(x) for x in args.frames.split(",")]:
        yv = read_frame(args.vt, vt_fb, k)[: w * h].reshape(h, w).astype(np.float32)
        yr = rgb24_luma(read_frame(args.rife, rgb_fb, k), w, h)

        print(f"\n===== output frame k={k} =====")
        print(f"  VT   (nv12 Y)  min {yv.min():6.1f}  mean {yv.mean():7.2f}  "
              f"p1 {np.percentile(yv,1):6.1f}  p99 {np.percentile(yv,99):6.1f}  max {yv.max():6.1f}")
        print(f"  RIFE (rgb->Y)  min {yr.min():6.1f}  mean {yr.mean():7.2f}  "
              f"p1 {np.percentile(yr,1):6.1f}  p99 {np.percentile(yr,99):6.1f}  max {yr.max():6.1f}")

        # least-squares affine fit on a subsample
        s = slice(None, None, 4)
        x, y = yv[s, s].ravel(), yr[s, s].ravel()
        a, b = np.polyfit(x, y, 1)
        print(f"  affine fit     luma_rife = {a:.5f} * y_vt + {b:+.3f}")
        print(f"                 (pure range mismatch would be a=1.16438, b=-18.628)")

        raw_mae = float(np.abs(yv - yr).mean())
        # normalise VT limited -> full, the way ffmpeg would
        yv_full = np.clip((yv - 16.0) * (255.0 / 219.0), 0, 255)
        norm_mae = float(np.abs(yv_full - yr).mean())
        # and the reverse: full -> limited
        yr_lim = np.clip(yr * (219.0 / 255.0) + 16.0, 0, 255)
        norm_mae2 = float(np.abs(yv - yr_lim).mean())

        print(f"  MAE as-measured                  : {raw_mae:7.3f}")
        print(f"  MAE after VT limited->full       : {norm_mae:7.3f}")
        print(f"  MAE after RIFE full->limited     : {norm_mae2:7.3f}")
        resid = float(np.abs(yv - yr).mean() - np.abs(yv_full - yr).mean())
        print(f"  -> explained by range alone      : {resid:7.3f} "
              f"({100.0*resid/raw_mae:.1f}% of the apparent difference)")


if __name__ == "__main__":
    main()
