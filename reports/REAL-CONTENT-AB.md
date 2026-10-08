# Real-content A/B — *The Fast and the Furious* (2001) UHD BluRay

The first test on real film, at real 4K, in real HDR. Everything before this used
synthetic frames or a colour-bars test clip. Three things came out of it that the
synthetic tests could not have found: an instrument bug worth 20%, a mandatory
app feature, and the real cost of the 4K decision.

**Artifacts:** `~/Desktop/FNF-60FPS-A-B/` — see the `README.md` in that folder.

---

## 1. The source

| | |
|---|---|
| File | `The.Fast.and.the.Furious.2001.2160p.UHD.BluRay.x265.10bit.HDR.DTS-X.7.1-LAMA.mkv` |
| Duration | 6411.456 s (106:51), 9.96 GB |
| Video | HEVC Main 10, **3840×1632**, 23.976 fps (24000/1001) |
| Pixels | 6.27 Mpx — **not** 8.29 Mpx. The scope black bars are cropped, so this is 2.35:1 |
| Colour | `yuv420p10le`, **PQ (smpte2084)**, **BT.2020**, tv range |
| Mastering | Display P3 primaries, 1000 cd/m² peak, 0.005 cd/m² black |
| Light levels | MaxCLL **1000**, MaxFALL 221 |
| Audio | DTS-HD MA + DTS:X 7.1, AC3 5.1 |
| Subtitles | 2× SubRip |

Two facts here changed the plan. It is **3840×1632**, not 3840×2160 — so every 4K
figure in this project is really a 6.27 Mpx figure, 25% cheaper than true UHD.
And it is **23.976**, which is the rate the phase plan was designed around.

## 2. Choosing the segment

The middle of the film is 3205.7 s. A 2 fps greyscale scan of 3160–3320 s
(320 samples) found the highest-motion 8-second window at **3204.5 s — film clock
53:24**, dead centre. That is the segment used throughout.

**The scan was measuring the wrong thing, and I only found out later.** At 2 fps a
scene cut looks identical to fast motion. The segment contains **5 cuts**, so part
of what the scan ranked as "most motion" was actually cuts. See §6.

## 3. HDR: the standard toolchain was not available

This machine's ffmpeg is a slim build:

| Needed | Status |
|---|---|
| `zscale` (libzimg) | **absent** — this is the filter the whole standard HDR→SDR chain is built on |
| `libplacebo` | absent |
| `tonemap` | present, but needs linear-light input, which is what `zscale` was providing |
| `scale_vt` (VideoToolbox) | present, **fails with ENOSYS** on this input |
| freetype / `drawtext` | absent (already known) |

So the tone mapping was written by hand: `analysis/hdr_tonemap.py`.

- **PQ EOTF** (SMPTE ST 2084) → linear light, 1.0 = 10 000 cd/m²
- **BT.2020 → BT.709** primaries, 3×3 matrix in linear light
- **Tone curve applied as a luma-preserving scale**, `f(Y)/Y`, not per channel.
  Per-channel tone mapping desaturates highlights toward white because R
  compresses while G and B do not. Since the point is comparing motion, hue
  preservation matters more than peak fidelity.
- **BT.709 OETF** → 8-bit

Curve: a **soft knee at 0.90** — identity below 90 nits so shadows and mid-tones
pass through untouched, with a tanh shoulder above.

Two curve bugs found and fixed on the way:

1. **Hable has a black lift.** `hable(0) = 1/30`, not 0, so dividing by
   `hable(W)` maps black to 0.047 — a visible grey veil over the whole image. The
   first version did exactly this and looked blue and washed out. Fixed by
   subtracting the toe: `(hable(x) − hable(0)) / (hable(W) − hable(0))`.
2. **The knee choice barely matters here.** Measured: `clip`, `knee75` and
   `knee90` all pin the same 0.839% of pixels, because this shot's highlights sit
   at 500–800 nits — 5–8× reference white, far above any knee. The knee is kept
   for robustness on brighter shots, not because it changes this one.

### This shot is a hard tone-mapping case

Source luminance, sampled 1/16:

| p1 | p25 | **p50** | p75 | p90 | p95 | p99 | p100 |
|---|---|---|---|---|---|---|---|
| 0.02 | 0.05 | **0.17** | 1.41 | 7.44 | 15.5 | **522** | 820 nits |

Half the frame is below **0.17 nits**; 1% is above **522 nits**. That is an
enormous range and a near-black scene — a dark garage at night. It is a *good*
interpolation test (ghosting shows worst in dark gradients) but a demanding
tone-mapping one.

## 4. The instrument bug — 20% of the work was unnecessary

First run reported:

```
plan : 475 out frames = 474 interpolated + 1 passthrough
```

23.976 → 59.94 is **exactly 2.5×**. One output frame in five lands precisely on a
source frame and needs no interpolation at all — 95 of 475. I got **1**.

**Cause.** The phase plan computed `t = k × src_fps / out_fps` in floating point,
with a `1e-6` epsilon to catch the fractional part landing on 0.9999999998. The
epsilon was the wrong fix. Feeding `23.976024` and `59.94` gives a ratio of
**0.4000004**, not 0.4 — the fractional part drifts 4×10⁻⁷ per frame, and by k=5
it is 2×10⁻⁶, past the epsilon. Every passthrough was lost.

**Fix.** Exact integer arithmetic, no epsilon:

```
t = k × (src_num/src_den) / (out_num/out_den)
  = k × src_num × out_den / (src_den × out_num)
```

An output frame is a passthrough when the remainder is **exactly zero**. Applied
to `rife_render.py` and `vt_render.swift`; `ab_test.py` now passes the container's
exact rational (`24000/1001`) instead of a 6-decimal float.

**Verified across the rate matrix:**

| source → 59.94 | passthrough |
|---|---|
| **23.976 (24000/1001)** | **20.0%** |
| 29.97 (30000/1001) | 50.0% |
| 24.000 | 0.2% |
| 25.000 | 0.2% |
| 50.000 | 0.3% |
| 23.976 → **60.000** | 0.2% |

That last row is the NTSC-alignment effect reproduced on real content: 23.976 and
59.94 share the /1001 denominator, 60.000 does not.

**Effect on the measurement:**

| | buggy | fixed | gain |
|---|---|---|---|
| Interpolated frames | 474 | 380 | −20% |
| RIFE wall | 75.7 s | 61.8 s | **+22%** |
| VT wall | 16.5 s | 15.2 s | +8% |

RIFE gained almost exactly the 20% fewer calls — it is purely compute-bound. VT
gained only 8%, because a passthrough frame still costs a 9.4 MB buffer copy;
VT's bottleneck is partly memory traffic, not the VideoToolbox call.

> **This is an app requirement, not just a test-harness fix.** Any implementation
> that carries frame rates as decimals throws away 20% of its throughput on
> 23.976 → 59.94 and 50% on 29.97 → 59.94.

## 5. Results

Same 191 source frames, same 475 output frames, same phases, both engines, both
resolutions. Zero errors in all four runs.

| | 4K — 3840×1632 | 1080p — 1920×816 |
|---|---|---|
| **VTFrameProcessor** | 15.2 s → **31.2 fps** (80.2 ms/call) | 6.3 s → **75.9 fps** (32.9 ms/call) |
| **CoreML RIFE 4.25** | 61.8 s → **7.7 fps** (162.6 ms/call) | 16.5 s → **28.8 fps** (43.4 ms/call) |
| RIFE penalty | **4.1×** | **2.6×** |

### Where RIFE's time actually goes

RIFE's CoreML graph is a flat ~**54 Mpx/s** — measured at 1080p (54.1), 4K pure
inference (54.2) and 4K in the renderer. The rest is the Python harness:

| | pixels | pure model | harness overhead | measured |
|---|---|---|---|---|
| 1080p | 1.60 Mpx | 29.5 ms | **+13.9 ms** | 43.4 ms |
| 4K | 6.39 Mpx | 117.9 ms | **+44.7 ms** | 162.6 ms |

The overhead is numpy padding, transpose and quantisation — proportional to
pixels, ~27%. **A Swift/Metal port removes it**, which would give RIFE ~36 fps at
1080p and ~8.5 fps at 4K. Still short of the 47.9 calls/s that 23.976 → 59.94
needs for real-time at 1080p.

### Projected cost, 2-hour film at 59.94

431 568 output frames:

| | VTFrameProcessor | CoreML RIFE | penalty |
|---|---|---|---|
| **4K (3840×1632)** | **3.8 h** | **15.6 h** | 4.0× |
| **1080p (1920×816)** | **1.6 h** | **4.2 h** | 2.6× |

**4K costs 2.4× more than 1080p for VT and 3.7× more for RIFE** — for 3.06× the
pixels.

## 6. Scene cuts — both engines fail, and neither knows

The segment contains **5 cuts** in 8 seconds. Frame-to-frame difference jumps from
a median of 7.6 to 36–65 at each — 5–9× the median, unambiguous.

Interpolating across a cut blends two unrelated shots. Measured output frame
`k00173` (the frame between source 69 and 70):

- **VTFrameProcessor**: visible double-exposure
- **CoreML RIFE**: visible double-exposure

Neither engine detects scene changes. Neither is expected to — cut detection is a
separate, well-understood problem, and both engines are doing exactly what they
were asked.

> **This is a mandatory app feature.** At a scene change the correct behaviour is
> to pass the source frame through, never to interpolate. Without it every cut in
> a film produces a ghost frame — roughly 2000 of them in a 2-hour action film.
> It is now in the build plan.

## 7. What this changes

| Finding | Consequence |
|---|---|
| Exact rational rates give +20% on 23.976→59.94, +50% on 29.97→59.94 | Carried into the app as an invariant, not a test-harness detail |
| **Scene-change detection is mandatory** | **New Phase 1 deliverable.** Not in the original plan |
| 4K costs 2.4× (VT) / 3.7× (RIFE) over 1080p | Directly informs decision #6 |
| 4K playback: VT gives 31.2 fps against 59.94 needed | **48% of frames dropped** — the measured reality behind "accept dropped frames" |
| 1080p playback: VT gives 75.9 fps | **Above real-time. No drops.** |
| RIFE's CoreML graph is a flat ~54 Mpx/s | Throughput is predictable from pixel count alone; no need to re-measure per resolution |
| The source is 3840×**1632**, not 3840×2160 | All 4K figures are 6.27 Mpx, 25% cheaper than true UHD |
| No `zscale`; `scale_vt` fails | HDR tone mapping must be written by hand, or the app must own it |

## 8. Reproduce

```bash
VENV=/Users/Wasim/.workbuddy-ai/binaries/python/envs/coreml
SRC="/Users/Wasim/Desktop/The.Fast.and.the.Furious.2001.2160p.UHD.BluRay.x265.10bit.HDR.DTS-X.7.1-LAMA.mkv"

# 1. cut + tone map HDR10 -> SDR BT.709, losslessly
$VENV/bin/python analysis/hdr_segment.py "$SRC" --start 3204.5 --duration 8 \
    --out work/fnf_sdr_lossless.mp4 --curve knee90

# 2. both engines, then encode / compare / stills / verify
$VENV/bin/python analysis/ab_test.py work/fnf_sdr_lossless.mp4 \
    --name FNF_60FPS --outdir ~/Desktop/FNF-60FPS-A-B --stack-width 1600 --stills 4
```

## 9. Still open

- **Is RIFE's output visibly better?** Only your eyes can answer this. That is
  what `FNF_60FPS_SLOW.mp4` is for.
- **HDR output.** This test deliberately produced SDR. Whether the app tone maps,
  or keeps HDR end-to-end (VTFrameProcessor handles 10-bit P010 natively), is a
  separate decision we have not made.
- **Audio.** Not touched. The app needs a muxing story (the source is DTS:X 7.1).
- **Cut detection thresholds.** Not measured — how many false positives a
  detector produces on fast motion is a real question.
