import vapoursynth as vs
core = vs.core
PLUG = "/Applications/SVP 4 Mac.app/Contents/Resources/rife/libRIFE.dylib"
core.std.LoadPlugin(path=PLUG)
clip = core.std.BlankClip(width=320, height=240, format=vs.RGBS, length=4, fpsnum=24, fpsden=1)
print("--- list_gpu ---")
try:
    out = core.rife.RIFE(clip, fps_num=60, fps_den=1, list_gpu=1)
    print("returned:", out)
except Exception as e:
    print("ERR:", type(e).__name__, e)
