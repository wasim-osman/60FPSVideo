#!/usr/bin/env python3
"""Tone-map a frame of raw P010 (HDR10) to a viewable PNG.

HDR cannot be looked at directly — on an SDR display it appears washed out and
grey, which reads as "the pipeline broke" when nothing is wrong. So the only way
to eyeball an HDR result is to tone-map it, and that has to be done the same way
on both sides of a comparison or the comparison is meaningless.

This reuses `hdr_tonemap.py`, the same module `hdr_segment.py` uses to make the
SDR reference clips, so a tone-mapped HDR frame and an SDR frame from the same
source are directly comparable.

Two steps, because the YUV->RGB matrix is the one piece of colour work ffmpeg
can do correctly here (no zscale in this build, so it cannot do the PQ curve):

  1. ffmpeg: P010 -> rgb48le, tagged BT.2020/PQ, tv range. This applies the
     matrix and the range expansion and leaves the PQ curve intact.
  2. numpy:  PQ EOTF -> BT.2020->BT.709 -> tone curve -> BT.709 OETF -> 8-bit.

Usage:
  p010_preview.py IN.p010 OUT.png --frame 120 [--width 3840] [--height 1632]
                  [--curve knee90] [--ref-white 100] [--src-peak 1000]
                  [--side-by-side SDR.nv12] [--label-a A] [--label-b B]
"""
import argparse
import os
import subprocess
import sys
from fractions import Fraction

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from hdr_tonemap import tone_map, build_luts  # noqa: E402


def decode_p010_to_rgb48(path, frame, width, height):
    """One P010 frame -> uint16 (H,W,3) PQ-encoded BT.2020 RGB."""
    frame_bytes = width * height * 3
    cmd = [
        "ffmpeg", "-hide_banner", "-v", "error",
        "-f", "rawvideo", "-pix_fmt", "p010le",
        "-s", f"{width}x{height}",
        "-color_range", "tv", "-color_primaries", "bt2020",
        "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
        "-i", path,
        "-vf", f"select='eq(n\\,{frame})'", "-frames:v", "1",
        "-pix_fmt", "rgb48le", "-f", "rawvideo", "-",
    ]
    out = subprocess.run(cmd, capture_output=True, check=True).stdout
    expected = width * height * 6
    if len(out) != expected:
        raise SystemExit(f"ffmpeg returned {len(out)} bytes, expected {expected}")
    return np.frombuffer(out, dtype="<u2").reshape(height, width, 3)


def decode_nv12_to_rgb24(path, frame, width, height):
    """One NV12 frame -> uint8 (H,W,3) BT.709 RGB, for the SDR side."""
    cmd = [
        "ffmpeg", "-hide_banner", "-v", "error",
        "-f", "rawvideo", "-pix_fmt", "nv12",
        "-s", f"{width}x{height}",
        "-color_range", "tv", "-color_primaries", "bt709",
        "-color_trc", "bt709", "-colorspace", "bt709",
        "-i", path,
        "-vf", f"select='eq(n\\,{frame})'", "-frames:v", "1",
        "-pix_fmt", "rgb24", "-f", "rawvideo", "-",
    ]
    out = subprocess.run(cmd, capture_output=True, check=True).stdout
    expected = width * height * 3
    if len(out) != expected:
        raise SystemExit(f"ffmpeg returned {len(out)} bytes, expected {expected}")
    return np.frombuffer(out, dtype="u1").reshape(height, width, 3)


def write_png(path, rgb, scale=4):
    """PNG via Pillow, downscaled by an integer factor so it stays quick and the
    comparison is at a size a person can actually see at once."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        raise SystemExit("Pillow is not installed in this interpreter")
    h, w, _ = rgb.shape
    img = Image.fromarray(rgb)
    if scale > 1:
        img = img.resize((w // scale, h // scale), Image.LANCZOS)
    img.save(path)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--frame", type=int, default=120)
    ap.add_argument("--width", type=int, default=3840)
    ap.add_argument("--height", type=int, default=1632)
    ap.add_argument("--curve", default="knee90", choices=["hable", "reinhard", "knee", "knee90", "clip"])
    ap.add_argument("--ref-white", type=float, default=100.0)
    ap.add_argument("--src-peak", type=float, default=1000.0)
    ap.add_argument("--side-by-side", default=None,
                    help="an SDR .nv12 of the same content, to stack underneath")
    ap.add_argument("--src-rate", default="24000/1001")
    ap.add_argument("--out-rate", default="60000/1001")
    ap.add_argument("--scale", type=int, default=4, help="integer downscale for the PNG")
    ap.add_argument("--label-a", default="HDR 10-bit, tone-mapped")
    ap.add_argument("--label-b", default="SDR 8-bit reference")
    args = ap.parse_args()

    luts = build_luts()
    rgb16 = decode_p010_to_rgb48(args.src, args.frame, args.width, args.height)
    hdr = tone_map(rgb16, curve=args.curve, ref_white=args.ref_white,
                   src_peak=args.src_peak, luts=luts)
    print(f"HDR frame {args.frame}: tone-mapped {args.curve}, "
          f"mean {hdr.mean():.1f}/255")

    if not args.side_by_side:
        write_png(args.out, hdr, args.scale)
        print(f"wrote {args.out}")
        return 0

    # Which SOURCE frame does this output frame sit on? Derive it, never assume
    # it. At 2.5x, output k lands on source 2k/5 — so output 120 is source 48,
    # and comparing it against source 120 compares two unrelated pictures.
    src_rate = Fraction(args.src_rate)
    out_rate = Fraction(args.out_rate)
    position = Fraction(args.frame) * src_rate / out_rate
    exact = position.denominator == 1
    sdr_frame = int(position)
    if exact:
        print(f"output {args.frame} sits exactly on source {sdr_frame} "
              f"(a passthrough) — both sides are the same real frame, so any "
              f"difference is the colour path, not the interpolation")
    else:
        print(f"output {args.frame} sits at source position {float(position):.2f}, "
              f"i.e. INTERPOLATED. Comparing it against source {sdr_frame} mixes "
              f"interpolation error into the colour comparison — pick an output "
              f"frame that is a multiple of 5 for a clean one")

    sdr = decode_nv12_to_rgb24(args.side_by_side, sdr_frame, args.width, args.height)
    print(f"SDR frame {sdr_frame}: mean {sdr.mean():.1f}/255")
    # Not an equality claim — the SDR clip was tone-mapped independently, so a few
    # levels of difference is expected. A large one would mean the HDR path
    # changed the picture.
    d = np.abs(hdr.astype(np.int16) - sdr.astype(np.int16))
    print(f"difference: mean {d.mean():.2f}/255, 99th pct {np.percentile(d, 99):.0f}/255")

    try:
        from PIL import Image, ImageDraw
    except ImportError:
        raise SystemExit("Pillow is not installed in this interpreter")

    # Stack with labels. drawtext is unavailable in this ffmpeg build, so the
    # labels are drawn here (a known constraint of this machine — see MEMORY).
    h, w, _ = hdr.shape
    gap, bar = 8, 34
    canvas = Image.new("RGB", (w, h * 2 + gap + bar * 2), (24, 24, 28))
    canvas.paste(Image.fromarray(hdr), (0, bar))
    canvas.paste(Image.fromarray(sdr), (0, h + gap + bar * 2))
    draw = ImageDraw.Draw(canvas)
    draw.text((10, 9), args.label_a, fill=(240, 240, 240))
    draw.text((10, h + gap + bar + 9), args.label_b, fill=(240, 240, 240))
    if args.scale > 1:
        canvas = canvas.resize((canvas.width // args.scale, canvas.height // args.scale),
                               Image.LANCZOS)
    canvas.save(args.out)
    print(f"wrote {args.out} ({canvas.width}x{canvas.height})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
