import vapoursynth as vs
core = vs.core
PLUG = "/Applications/SVP 4 Mac.app/Contents/Resources/rife/libRIFE.dylib"
print("VapourSynth:", core.core_version, "| API:", core.api_version)
core.std.LoadPlugin(path=PLUG)
print("LoadPlugin OK")
print("\nRegistered plugins and functions:")
for pl in core.plugins():
    print(f"  namespace '{pl.namespace}'")
    fns = pl.functions() if callable(pl.functions) else pl.functions
    for fn in fns:
        print(f"      {pl.namespace}.{fn}")
