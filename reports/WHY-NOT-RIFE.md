# Why not just use RIFE / MVTools?

Short answer: **you can use RIFE — it's MIT and it's already arm64 — but you shouldn't make it the
primary engine, because on this hardware it runs at 0.47× real-time at 1080p and cannot be scaled by
running more jobs.** MVTools is a separate matter: it isn't in SVP 4 Mac at all, and its GPL-2.0
licence blocks App Store distribution.

Everything below is **measured on this machine**, not estimated. I loaded SVP's own
`libRIFE.dylib` into the system VapourSynth install and benchmarked it head-to-head against
`VTFrameProcessor`.

Raw data: [`analysis/benchmarks/rife_vs_vtfp.txt`](../analysis/benchmarks/rife_vs_vtfp.txt).

---

## 1. First, a correction to my own earlier report

`FEASIBILITY-AND-STACK.md` repeatedly describes MVTools as SVP's motion-estimation engine and
proposes a "VapourSynth + MVTools (arm64)" fallback tier. **That is wrong for SVP 4 Mac.**

I searched the bundle. There is **no MVTools anywhere** — no `libmvtools`, no `mvanalyse`, no
MVTools binary of any kind. MVTools is an AviSynth/VapourSynth plugin that appears in SVP's
**Windows/AviSynth** configurations. On macOS, SVP uses its own engine.

So "why not MVTools" has a simpler answer than expected: **SVP 4 Mac doesn't use it either.**

---

## 2. What SVP 4 Mac actually ships

From `Contents/Resources/`:

| Component | Size | Arch | Licence | Role |
| --- | --- | --- | --- | --- |
| `plugins/libsvpflow2.dylib` | 773 KB | universal | proprietary | **the main engine** (OpenCL) |
| `plugins/libsvpflow1.dylib` | 808 KB | universal | proprietary | older engine |
| `rife/libRIFE.dylib` | 13 MB | universal | **MIT** | optional neural tier |
| `rife/models/rife-v4.6/` | 10 MB | — | MIT | RIFE model weights (ncnn) |
| `rife/models/rife-v4.16lite/` | 5 MB | — | MIT | RIFE model weights (ncnn) |
| `rife/rife-v4/` | 9.9 MB | — | MIT | legacy RIFE model |
| `plugins/libvapoursynth_plugin.dylib.30` | 174 KB | universal | — | SVP's VapourSynth host plugin |
| `Frameworks/libpython3.11.dylib` | 14 MB | universal | PSF | embedded Python runtime |

Two things fall out of this immediately:

- **`libRIFE.dylib` is a VapourSynth plugin, not a library.** It exports
  `_VapourSynthPluginInit2`. You cannot link it directly — you must host VapourSynth.
- **SVP does not bundle VapourSynth or Vulkan.** It depends on both being installed separately.
  On this machine they come from Homebrew (`vapoursynth` R77, `vulkan-loader` 1.4.350,
  `molten-vk`).

---

## 3. RIFE's licence is not the problem

I read `Contents/Resources/licenses/RIFE_license.txt` directly:

```
https://github.com/hzwer/arXiv2020-RIFE
https://github.com/HomeOfVapourSynthEvolution/VapourSynth-RIFE-ncnn-Vulkan
https://github.com/Asd-g/AviSynthPlus-RIFE

MIT License
Copyright (c) 2021-2022 hzwer, HolyWu, Asd-g
```

**MIT.** No copyleft, no source-disclosure obligation, App Store compatible. So if the only
objection were licensing, RIFE would be a clear yes.

The objection is performance and deployment.

---

## 4. The measured blocker: RIFE is 0.47× real-time at 1080p

SVP's own `libRIFE.dylib`, loaded into VapourSynth R77, Vulkan 1.4.350 via MoltenVK, M2 Max.
Task: 24 → 60 fps.

| Resolution | **RIFE v4** | vs real-time | **VTFrameProcessor** | vs real-time | VTFP lead |
| --- | --- | --- | --- | --- | --- |
| 640×360 | 91.2 fps | 1.52× | — | — | — |
| 1280×720 | 56.5 fps | 0.94× | 80.5 fps | 1.34× | **1.4×** |
| **1920×1080** | **28.5 fps** | **0.47×** | **80.8 fps** | **1.35×** | **2.8×** |
| 3840×2160 | 7.7 fps | 0.13× | 33.4 fps | 0.56× | **4.3×** |

**RIFE cannot reach real-time at 1080p.** It runs at less than half the speed needed. That alone
rules it out as the playback engine, and it makes it a poor batch engine too.

The three shipped models, all at 1080p:

| Model | Output fps | vs real-time |
| --- | --- | --- |
| `rife-v4` | 28.6 | 0.48× |
| `rife-v4.6` | 26.9 | 0.45× |
| `rife-v4.16lite` | 23.0 | 0.38× |

Note the "lite" model is **slower**, not faster — the cost is dominated by per-frame Vulkan/MoltenVK
dispatch, not by model size.

The gap also **widens with resolution**, which is the wrong direction: RIFE's quality advantage
would matter most at 4K, and 4K is exactly where it is 4.3× behind.

---

## 5. The measured blocker, part two: RIFE doesn't scale with concurrency

This is the part that kills it for batch. Apple's engine is *round-trip-latency-bound*, so running
more workers recovers 3× of throughput. RIFE is *GPU-compute-bound*, so more workers just contend.

| Workers | **RIFE aggregate** | **VTFrameProcessor aggregate** |
| --- | --- | --- |
| 1 | 28.2 fps | 81.8 fps |
| 2 | 42.0 fps | 189.2 fps |
| 3 | — | 225.6 fps |
| 4 | **40.0 fps** | **247.2 fps** |

RIFE peaks at **~42 fps aggregate** and then goes *backwards*. Four RIFE workers give no more than
two. Apple's engine reaches **247 fps**.

I also tried RIFE's own `gpu_thread` multi-queue option (1, 2, 3): **28.4 / 28.5 / 28.5 fps** — no
effect whatsoever.

### What that means for a real job

A 2-hour film at 24 fps → 432,000 output frames at 1080p:

| Engine | Best configuration | Time |
| --- | --- | --- |
| RIFE v4 | 2 processes | **2 h 51 m** |
| VTFrameProcessor | 4 workers | **29 m** |

**VTFrameProcessor is 5.9× faster for batch conversion**, and RIFE is not capable of real-time
playback at all.

---

## 6. The deployment blocker: a Vulkan/MoltenVK/VapourSynth dependency chain

Even if RIFE were fast, shipping it is a problem. `otool -L` on SVP's `libRIFE.dylib`:

```
(architecture x86_64):
    /usr/local/opt/vulkan-loader/lib/libvulkan.1.dylib
(architecture arm64):
    /opt/homebrew/opt/vulkan-loader/lib/libvulkan.1.dylib   (weak)
```

So RIFE-on-Mac means:

```
your app  →  VapourSynth (LGPL-2.1)  →  libRIFE.dylib  →  Vulkan loader  →  MoltenVK  →  Metal
                                          + ncnn
                                          + 15 MB of models
```

- **Vulkan on macOS does not exist natively.** It is always **MoltenVK**, a translation layer that
  maps Vulkan onto Metal. You are running GPU compute through a compatibility shim — which is a
  large part of why the numbers in §4 are what they are.
- **SVP bundles neither VapourSynth nor Vulkan.** It requires Homebrew-installed copies. That is
  fine for a free download that documents its prerequisites; it is not fine for a product.
- **Mac App Store: impossible.** A sandboxed app cannot `dlopen` from `/opt/homebrew`. There is no
  entitlement that permits it.
- **Direct distribution: possible but heavy.** You would bundle MoltenVK (Apache-2.0, fine),
  VapourSynth (LGPL-2.1, fine if dynamically linked), ncnn (BSD-3), and 15 MB of model weights —
  roughly a 30 MB addition to do a job Apple's framework already does better.

Apple's path by comparison is `VTFrameProcessor`, which ships with the OS. Zero third-party
dependencies, zero licensing surface, zero bundling.

---

## 7. The format blocker: RIFE needs RGB float32

The plugin rejected my first attempt outright:

```
Error RIFE: only constant RGB format 32 bit float input supported
```

RIFE **cannot accept the decoder's native YUV.** Every frame must be converted to RGB 32-bit float
first — a 1080p RGBS frame is ~25 MB versus ~3 MB for 8-bit YUV 4:2:0, so you pay a full-colour
conversion and roughly 8× the memory traffic per frame.

`VTFrameProcessor` accepts `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` **directly** — the exact
format VideoToolbox decodes to and `VTCompressionSession` encodes from. Zero conversion anywhere in
the pipeline.

And note: my RIFE benchmark fed it **native RGBS** (no conversion), so the real-world gap is
*worse* than the table in §4 shows.

---

## 8. GPL-2.0 and MVTools

Separate from RIFE, for completeness, since I raised MVTools in the earlier report:

- **vapoursynth-mvtools is GPL-2.0.** Linking it into your application makes the whole linked work
  GPL-2.0: you must publish your source under a compatible licence.
- **GPL-2.0 is incompatible with Mac App Store distribution.** Apple's terms impose DRM and usage
  restrictions that GPL-2.0 forbids as "additional restrictions". This is a well-established
  conflict, not a grey area.
- SVP itself is distributed outside the App Store, as a free download with a separate licence key,
  and ships `gpl_for_used_libs.txt` plus a `source_codes.txt` pointing at an external GPL source
  download — that is the GPL compliance mechanism, and it is exactly the arrangement the App Store
  does not permit.

RIFE has none of these problems. **MVTools has all of them.**

---

## 9. So what *is* the right role for RIFE?

> **SUPERSEDED — see [`ENGINE-EQUIVALENCE.md`](ENGINE-EQUIVALENCE.md).** The reasoning below assumes
> RIFE's value is quality. That assumption has since been tested against ground truth on real 4K HDR
> film: VTFrameProcessor and CoreML RIFE 4.25 are **statistically indistinguishable** (Δ 0.105 MAE,
> |t| = 1.06, 95 held-out frames) while RIFE costs **4.06×** the time. **The tier is dropped.** What
> follows is kept as the record of why the tier was proposed in the first place.

**An optional quality tier — and converted to CoreML, not run through Vulkan.**

The reasoning:

1. Apple's engine is 2.8–4.3× faster and the only one that can do real-time playback. It is the
   correct default, and probably the correct *only* engine for most users.
2. RIFE's value is quality, not speed. Its MIT licence and the fact that it is already arm64 inside
   SVP mean there is no legal or architectural obstacle.
3. But **do not ship the ncnn+Vulkan build.** Convert the RIFE network to **CoreML**
   (via `coremltools`) so it runs natively on the ANE/GPU through Metal. That removes MoltenVK,
   removes VapourSynth, removes the Homebrew dependency, and removes the RGB-float conversion
   penalty — while keeping the model.
4. Keep it behind the same engine protocol as the default tier, so it is a switch, not a fork.

If you do that, you get a two-tier product: **fast by default, neural on request** — with no
GPL-2.0, no MoltenVK, and no external runtime.

---

## 10. Bottom line

| Claim | Verdict |
| --- | --- |
| "RIFE's licence blocks us" | **No** — it is MIT, confirmed from the bundle. |
| "MVTools is SVP's Mac engine" | **No** — it is not in the bundle at all. My earlier report was wrong. |
| "RIFE can do real-time playback" | **No** — 0.47× real-time at 1080p, 0.13× at 4K. |
| "RIFE can do batch faster" | **No** — 42 fps aggregate peak vs 247 fps. 5.9× slower. |
| "RIFE scales with more workers" | **No** — 4 workers give no gain over 2. It is GPU-bound, not latency-bound. |
| "RIFE is easy to ship" | **No** — needs VapourSynth + Vulkan + MoltenVK + Homebrew; impossible on the App Store. |
| "RIFE is useless" | **Also no.** It is the right *quality* tier, as a CoreML conversion. |

**Use Apple's `VTFrameProcessor` as the engine. Keep RIFE as an optional CoreML quality tier.
Ignore MVTools entirely.**

---

## Reproduce

Requires `brew install vapoursynth` (R77) and a Vulkan loader (`brew install vulkan-loader
molten-vk`).

```bash
cd analysis/probes/rife

# confirm the plugin loads and what it exposes
/opt/homebrew/bin/python3 probe_rife_load.py

# single benchmark:  bench_rife.py W H SRC_FPS OUT_FPS NSOURCE [MODEL]
/opt/homebrew/bin/python3 bench_rife.py 1920 1080 24 60 100 rife-v4
/opt/homebrew/bin/python3 bench_rife.py 3840 2160 24 60  40 rife-v4

# full sweep (models, resolutions, gpu_thread, concurrency)
bash run_rife_bench.sh
```
