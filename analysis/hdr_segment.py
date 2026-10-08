#!/usr/bin/env python3
"""Cut a segment from an HDR10 source, tone map it to SDR BT.709, and write a
lossless intermediate the A/B driver can consume.

The colour work is done here, ONCE, so both engines see byte-identical input.
That matters: if each engine did its own HDR handling, a difference in the
comparison could be the colour pipeline rather than the interpolator.

Chain:
  source (yuv420p10le / PQ / BT.2020 / tv range)
    -> ffmpeg decodes to rgb48le   (ffmpeg expands tv-range YUV to full-range RGB)
    -> numpy: PQ EOTF -> BT.2020->BT.709 matrix -> luma-preserving tone curve
       -> BT.709 OETF -> 8-bit RGB24
    -> ffmpeg encodes losslessly to yuv420p BT.709 mp4

Usage:
  hdr_segment.py SRC --start 3204.5 --duration 8 --out work/seg.mp4
"""
import argparse
import os
import subprocess
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from hdr_tonemap import tone_map, build_luts, CURVES  # noqa: E402


def probe(path):
    def q(entries):
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", entries, "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, check=True)
        return [l for l in r.stdout.strip().splitlines() if l]
    w, h = q("stream=width,height")
    fr = q("stream=r_frame_rate")[0]
    num, den = (fr.split("/") + ["1"])[:2]
    return int(w), int(h), float(num) / float(den), fr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--start", type=float, required=True)
    ap.add_argument("--duration", type=float, default=8.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--keep-rgb24", default=None,
                    help="also write the raw RGB24 (the RIFE engine's input)")
    ap.add_argument("--curve", default="knee90", choices=sorted(CURVES))
    ap.add_argument("--ref-white", type=float, default=100.0,
                    help="source nits that map to SDR diffuse white")
    ap.add_argument("--src-peak", type=float, default=1000.0)
    ap.add_argument("--crf", type=int, default=0, help="0 = lossless")
    args = ap.parse_args()

    W, H, fps, fr = probe(args.src)
    print(f"source : {args.src}")
    print(f"         {W}x{H}  {fr} ({fps:.6f} fps)")
    print(f"segment: {args.start}s .. {args.start + args.duration}s "
          f"({args.duration * fps:.0f} frames)")
    print(f"tonemap: {args.curve}  ref_white={args.ref_white:g} nit  "
          f"src_peak={args.src_peak:g} nit")

    if W % 2 or H % 2:
        sys.exit(f"odd dimensions {W}x{H} - yuv420p needs even")

    luts = build_luts()
    fsz = W * H * 3 * 2
    dec = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-ss", f"{args.start}", "-i", args.src,
         "-t", f"{args.duration}", "-an", "-sn", "-fps_mode", "passthrough",
         "-pix_fmt", "rgb48le", "-f", "rawvideo", "-"],
        stdout=subprocess.PIPE, bufsize=fsz * 4)

    tmp_rgb = args.keep_rgb24 or os.path.join(
        os.path.dirname(os.path.abspath(args.out)), "_seg_rgb24.raw")
    fo = open(tmp_rgb, "wb")

    n = 0
    t0 = time.perf_counter()
    while True:
        buf = dec.stdout.read(fsz)
        if len(buf) < fsz:
            break
        a = np.frombuffer(buf, dtype="<u2").reshape(H, W, 3)
        out = tone_map(a, curve=args.curve, ref_white=args.ref_white,
                       src_peak=args.src_peak, luts=luts)
        fo.write(out.tobytes())
        n += 1
        if n % 50 == 0:
            print(f"   {n} frames  {time.perf_counter()-t0:.1f}s", flush=True)
    dec.stdout.close()
    dec.wait()
    fo.close()
    print(f"tone mapped {n} frames in {time.perf_counter()-t0:.1f}s -> {tmp_rgb}")

    if n < 2:
        sys.exit("no frames decoded")

    cmd = ["ffmpeg", "-y", "-v", "error",
           "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", fr,
           "-i", tmp_rgb,
           "-c:v", "libx264", "-preset", "medium",
           "-qp" if args.crf == 0 else "-crf", "0" if args.crf == 0 else str(args.crf),
           "-pix_fmt", "yuv420p",
           "-color_primaries", "bt709", "-color_trc", "bt709",
           "-colorspace", "bt709", "-color_range", "tv",
           args.out]
    subprocess.run(cmd, check=True)
    if not args.keep_rgb24:
        os.remove(tmp_rgb)
    sz = os.path.getsize(args.out)
    print(f"wrote {args.out}  {sz/1e6:.1f} MB  ({n} frames)")
    print(f"RESULT hdr_segment {W}x{H} {fr} {n} frames "
          f"{'lossless' if args.crf == 0 else 'crf'+str(args.crf)}")


if __name__ == "__main__":
    main()
