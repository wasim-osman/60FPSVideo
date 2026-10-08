#!/usr/bin/env python3
"""RIFE throughput benchmark, matched to the VTFrameProcessor probes.
Usage: bench_rife.py W H SRC_FPS OUT_FPS NSOURCE [MODEL]
"""
import sys, os, time, vapoursynth as vs

W, H, SRC, OUT, NSRC = (int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]),
                        int(sys.argv[4]), int(sys.argv[5]))
MODEL = sys.argv[6] if len(sys.argv) > 6 else "rife-v4"
MODELDIR = "/Applications/SVP 4 Mac.app/Contents/Resources/rife"
PLUG = "/Applications/SVP 4 Mac.app/Contents/Resources/rife/libRIFE.dylib"

core = vs.core
core.max_cache_size = 512          # 1080p RGBS is ~25 MB/frame
core.num_threads = 12
core.std.LoadPlugin(path=PLUG)

# RGBS is mandatory - the plugin rejects YUV outright.
clip = core.std.BlankClip(width=W, height=H, format=vs.RGBS,
                          length=NSRC, fpsnum=SRC, fpsden=1)
out = core.rife.RIFE(clip, fps_num=OUT, fps_den=1, gpu_id=0, gpu_thread=int(os.environ.get("GPU_THREAD", "1")),
                     tta=0, uhd=0, skip=0, sc=0,
                     model_path=f"{MODELDIR}/{MODEL}" if MODEL != "default" else None)

n_out = out.num_frames
print(f"  input {W}x{H} {SRC}fps x{NSRC} -> output {n_out} frames @ {OUT}fps")

# warm-up: first frames pay model load + shader compile
for i in range(min(4, n_out)):
    out.get_frame(i)

N = n_out
t0 = time.perf_counter()
for i in range(N):
    out.get_frame(i)
dt = time.perf_counter() - t0

fps = N / dt
src_equiv = (N / (OUT / SRC)) / dt          # source frames consumed per second
print(f"  {N} output frames in {dt:.2f}s")
print(f"RESULT RIFE {W}x{H} {SRC}->{OUT} model={MODEL} | OUTPUT {fps:6.1f} fps "
      f"| {src_equiv:5.1f} src fps | realtime={fps/OUT:.2f}x")
