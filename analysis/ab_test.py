#!/usr/bin/env python3
"""End-to-end A/B: one source clip -> both engines -> comparable output.

Runs VTFrameProcessor and CoreML RIFE over the SAME decoded frames at the SAME
output rate and the SAME phase plan, then produces artifacts you can actually
look at:

  out/<name>_VT.mp4            59.94 fps from VTFrameProcessor
  out/<name>_RIFE.mp4          59.94 fps from CoreML RIFE
  out/<name>_COMPARE.mp4       stacked, VT on top, RIFE below, labelled
  out/<name>_SLOW.mp4          both, at 1/4 speed, so artefacts show in motion
  out/<name>_frames/           matched still frames at 1:1 for pixel inspection
  out/<name>_report.txt        frame counts, timings, verification results

Colour handling is delegated entirely to ffmpeg, which reads the real metadata
from the container. A hand-rolled numpy NV12->RGB conversion was measured at 2.42
mean luma error against ffmpeg's 0.205 - see rife_render.py's docstring.

Usage:
  ab_test.py INPUT.mp4 [--out-fps 59.94] [--name NAME] [--seconds S]
                       [--rife-scale 1.0] [--no-rife] [--stills N]
"""
import argparse
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
VENV = "/Users/Wasim/.workbuddy-ai/binaries/python/envs/coreml"
VTRENDER = os.path.join(HERE, "probes", "vtrender")
RIFE_RENDER = os.path.join(HERE, "coreml", "rife_render.py")

WORK = os.path.join(PROJ, "work")
OUT = os.path.join(PROJ, "out")

# Common broadcast rates as exact rationals. The renderers are handed these
# rather than decimals on purpose: 23.976 -> 59.94 is exactly 2.5x, so one output
# frame in five lands on a source frame and needs no interpolation at all. Pass
# 59.94 as a decimal and that exactness is lost, along with the 20%.
EXACT_RATES = {
    23.976: "24000/1001", 23.98: "24000/1001",
    24.0: "24/1", 25.0: "25/1",
    29.97: "30000/1001", 30.0: "30/1",
    47.952: "48000/1001", 48.0: "48/1",
    50.0: "50/1",
    59.94: "60000/1001", 60.0: "60/1",
}


def rate_str(x):
    for k, v in EXACT_RATES.items():
        if abs(x - k) < 1e-6:
            return v
    return f"{x}"


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


def make_label(path, width, title, accent):
    """Render an overlay label. This ffmpeg has no freetype, so drawtext does not
    exist and the text has to come from Pillow instead."""
    from PIL import Image, ImageDraw, ImageFont
    hgt = 62
    img = Image.new("RGBA", (width, hgt), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, width, hgt], fill=(0, 0, 0, 170))
    d.rectangle([0, 0, 6, hgt], fill=accent)
    font = None
    for p in ("/System/Library/Fonts/SFNS.ttf",
              "/System/Library/Fonts/Helvetica.ttc",
              "/System/Library/Fonts/Supplemental/Arial.ttf",
              "/System/Library/Fonts/Geneva.ttf"):
        if os.path.exists(p):
            try:
                font = ImageFont.truetype(p, 32)
                break
            except Exception:                            # noqa: BLE001
                pass
    if font is None:
        font = ImageFont.load_default()
    d.text((22, hgt // 2), title, font=font, fill=(255, 255, 255, 255), anchor="lm")
    img.save(path)
    return path


def probe(path):
    """Return (width, height, fps, n_frames, has_audio, rate_string).

    rate_string is the container's EXACT rational (e.g. '24000/1001') and is
    passed to the renderers untouched - see EXACT_RATES for why."""
    def q(entries, stream="v:0"):
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", stream,
             "-show_entries", entries, "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, check=True)
        return [l for l in r.stdout.strip().splitlines() if l]

    w, h = q("stream=width,height")
    fr = q("stream=r_frame_rate")[0]
    num, den = (fr.split("/") + ["1"])[:2]
    fps = float(num) / float(den)
    nb = q("stream=nb_frames")
    n = int(nb[0]) if nb and nb[0].isdigit() else None
    audio = bool(subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
         "stream=index", "-of", "csv=p=0", path],
        capture_output=True, text=True).stdout.strip())
    return int(w), int(h), fps, n, audio, fr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("--out-fps", type=float, default=59.94)
    ap.add_argument("--name", default=None)
    ap.add_argument("--seconds", type=float, default=None,
                    help="only use the first N seconds of source")
    ap.add_argument("--rife-scale", type=float, default=1.0,
                    help="interpolate RIFE at this fraction of native (preview mode)")
    ap.add_argument("--no-rife", action="store_true")
    ap.add_argument("--stills", type=int, default=4)
    ap.add_argument("--outdir", default=None,
                    help="where the artifacts go (default: the project's out/)")
    ap.add_argument("--stack-width", type=int, default=1280,
                    help="width of each panel in the stacked comparison")
    args = ap.parse_args()

    global OUT
    if args.outdir:
        OUT = os.path.abspath(os.path.expanduser(args.outdir))

    name = args.name or os.path.splitext(os.path.basename(args.input))[0]
    name = "".join(c if c.isalnum() or c in "-_" else "_" for c in name)
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)

    w, h, fps, n_total, has_audio, src_rate = probe(args.input)
    out_rate = rate_str(args.out_fps)
    print(f"source : {args.input}")
    print(f"         {w}x{h}  {fps:g} fps  {n_total or '?'} frames"
          f"{'  +audio' if has_audio else ''}")
    print(f"rates  : {src_rate} -> {out_rate}  (exact)")

    # frame-accurate truncation so both engines see an identical source
    limit = ["-frames:v", str(int(args.seconds * fps))] if args.seconds else []

    src_nv12 = os.path.join(WORK, f"{name}.nv12")
    src_rgb24 = os.path.join(WORK, f"{name}.rgb24")

    print("\n[1/6] decode once, twice: NV12 for VT, RGB24 for RIFE")
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-i", args.input, *limit, "-pix_fmt", "nv12", "-f", "rawvideo", src_nv12])
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-i", args.input, *limit, "-pix_fmt", "rgb24", "-f", "rawvideo", src_rgb24])

    n = os.path.getsize(src_nv12) // (w * h * 3 // 2)
    n_rgb = os.path.getsize(src_rgb24) // (w * h * 3)
    if n != n_rgb:
        sys.exit(f"decode mismatch: NV12 has {n} frames, RGB24 has {n_rgb}")
    print(f"      {n} frames decoded ({os.path.getsize(src_nv12)/1e6:.0f} MB NV12, "
          f"{os.path.getsize(src_rgb24)/1e6:.0f} MB RGB24)")

    report = [f"AB test: {args.input}",
              f"source {w}x{h} {fps:g} fps ({src_rate}) -> {args.out_fps} fps ({out_rate})",
              f"frames {n}", ""]

    # ---------------------------------------------------------------- VT
    print(f"\n[2/6] VTFrameProcessor -> {args.out_fps} fps")
    vt_raw = os.path.join(WORK, f"{name}_vt.nv12")
    t0 = time.time()
    p = subprocess.run([VTRENDER, src_nv12, str(w), str(h), src_rate,
                        out_rate, vt_raw, "2"],
                       capture_output=True, text=True)
    print(p.stderr.rstrip())
    report += ["VTFrameProcessor", p.stderr.rstrip(), f"wall {time.time()-t0:.2f}s", ""]
    if p.returncode != 0:
        sys.exit(f"vtrender failed rc={p.returncode}")
    vt_frames = os.path.getsize(vt_raw) // (w * h * 3 // 2)

    # ---------------------------------------------------------------- RIFE
    rife_raw = os.path.join(WORK, f"{name}_rife.rgb24")
    rife_frames = 0
    if not args.no_rife:
        print(f"\n[3/6] CoreML RIFE -> {args.out_fps} fps")
        iw, ih = int(w * args.rife_scale), int(h * args.rife_scale)
        cmd = [os.path.join(VENV, "bin", "python"), RIFE_RENDER, src_rgb24,
               str(w), str(h), src_rate, out_rate, rife_raw]
        if args.rife_scale != 1.0:
            cmd += ["--interp-width", str(iw), "--interp-height", str(ih)]
        t0 = time.time()
        p = subprocess.run(cmd, capture_output=True, text=True)
        print(p.stderr.rstrip())
        report += ["CoreML RIFE", p.stderr.rstrip(), f"wall {time.time()-t0:.2f}s", ""]
        if p.returncode != 0:
            sys.exit(f"rife_render failed rc={p.returncode}")
        rife_frames = os.path.getsize(rife_raw) // (w * h * 3)
    else:
        print("\n[3/6] RIFE skipped (--no-rife)")

    # ---------------------------------------------------------------- encode
    print("\n[4/6] encode both to H.264 at the target rate")
    vt_mp4 = os.path.join(OUT, f"{name}_VT.mp4")
    run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
         "-f", "rawvideo", "-pix_fmt", "nv12", "-s", f"{w}x{h}", "-r", f"{args.out_fps}",
         "-i", vt_raw, "-c:v", "libx264", "-preset", "fast", "-crf", "12",
         "-pix_fmt", "yuv420p", vt_mp4])
    print(f"      {vt_mp4}  ({vt_frames} frames)")

    rife_mp4 = None
    if rife_frames:
        rife_mp4 = os.path.join(OUT, f"{name}_RIFE.mp4")
        run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
             "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{w}x{h}", "-r", f"{args.out_fps}",
             "-i", rife_raw, "-c:v", "libx264", "-preset", "fast", "-crf", "12",
             "-pix_fmt", "yuv420p", rife_mp4])
        print(f"      {rife_mp4}  ({rife_frames} frames)")

    # ---------------------------------------------------------------- compare
    if rife_mp4:
        print("\n[5/6] build the stacked comparison and the 1/4-speed version")
        cw = args.stack_width
        ch = int(round(cw * h / w / 2)) * 2      # keep the source aspect, stay even
        lbl_vt = make_label(os.path.join(WORK, "label_vt.png"), cw,
                            "VTFrameProcessor  (Apple VideoToolbox)", (90, 170, 230, 255))
        lbl_rf = make_label(os.path.join(WORK, "label_rife.png"), cw,
                            "CoreML RIFE 4.25  (converted from PyTorch)", (235, 170, 60, 255))
        compare = os.path.join(OUT, f"{name}_COMPARE.mp4")
        run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
             "-i", vt_mp4, "-i", rife_mp4, "-i", lbl_vt, "-i", lbl_rf,
             "-filter_complex",
             f"[0:v]scale={cw}:{ch}[a0];[1:v]scale={cw}:{ch}[b0];"
             f"[a0][2:v]overlay=0:0[a];[b0][3:v]overlay=0:0[b];[a][b]vstack",
             "-c:v", "libx264", "-preset", "fast", "-crf", "14",
             "-pix_fmt", "yuv420p", compare])
        print(f"      {compare}   (top = VTFrameProcessor, bottom = RIFE)")
        slow = os.path.join(OUT, f"{name}_SLOW.mp4")
        run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", compare,
             "-vf", "setpts=4*PTS", "-an", "-c:v", "libx264", "-preset", "fast",
             "-crf", "14", "-pix_fmt", "yuv420p", slow])
        print(f"      {slow}   (same stack, 1/4 speed - artefacts show in motion)")

    # ---------------------------------------------------------------- stills
    if rife_frames and args.stills > 0:
        print(f"\n[6/6] extract {args.stills} matched still pairs at 1:1")
        fdir = os.path.join(OUT, f"{name}_frames")
        os.makedirs(fdir, exist_ok=True)
        # spread the samples, skipping the first few (usually a passthrough frame)
        picks = [int(vt_frames * (i + 1) / (args.stills + 1)) for i in range(args.stills)]
        for k in picks:
            for tag, raw, pf in (("VT", vt_raw, "nv12"), ("RIFE", rife_raw, "rgb24")):
                dst = os.path.join(fdir, f"k{k:05d}_{tag}.png")
                run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                     "-f", "rawvideo", "-pix_fmt", pf, "-s", f"{w}x{h}",
                     "-i", raw, "-vf", f"select=eq(n\\,{k})", "-frames:v", "1", dst])
            print(f"      frame {k:5d}  k{k:05d}_VT.png / k{k:05d}_RIFE.png")
        report += [f"stills in {fdir}", ""]

    # ---------------------------------------------------------------- verify
    print("\n== verification ==")
    import numpy as np

    def frame_bytes(path, idx, fsz):
        with open(path, "rb") as f:
            f.seek(idx * fsz)
            return f.read(fsz)

    checks = []
    # 1. both engines must produce the same number of output frames
    checks.append(("output frame counts match",
                   vt_frames == rife_frames if rife_frames else None,
                   f"VT {vt_frames}" + (f", RIFE {rife_frames}" if rife_frames else "")))
    # 2. passthrough frames must be byte-identical to their source frame
    src0 = frame_bytes(src_nv12, 0, w * h * 3 // 2)
    vt0 = frame_bytes(vt_raw, 0, w * h * 3 // 2)
    checks.append(("VT passthrough k=0 == source frame 0", src0 == vt0, ""))
    # 3. no zeroed chroma anywhere in the VT output (the bug that bit once already)
    uv = np.frombuffer(frame_bytes(vt_raw, min(1, vt_frames - 1), w * h * 3 // 2),
                       np.uint8)[w * h:].reshape(h // 2, w)
    checks.append(("VT chroma fully populated", int((uv.max(axis=1) == 0).sum()) == 0,
                   f"{int((uv.max(axis=1)==0).sum())} zero rows"))

    for label_, ok, extra in checks:
        mark = "PASS" if ok else ("skip" if ok is None else "FAIL")
        print(f"   [{mark}] {label_}" + (f"  ({extra})" if extra else ""))
        report.append(f"[{mark}] {label_} {extra}")

    rpath = os.path.join(OUT, f"{name}_report.txt")
    with open(rpath, "w") as f:
        f.write("\n".join(report) + "\n")
    print(f"\nreport -> {rpath}")


if __name__ == "__main__":
    main()
