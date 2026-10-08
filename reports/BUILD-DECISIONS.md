# Build decisions — read this before we write any code

You've confirmed the shape: **`VTFrameProcessor` is the engine, RIFE converted to CoreML is the
quality tier.** That's decided. This document is everything still open, with the **measured** effect
of each option so you can choose rather than guess.

Every number here comes from the benchmarks in `analysis/benchmarks/` on your M2 Max. Where I don't
know something, I say so rather than fill it in.

---

## How to read this

Each decision has options, an **Effect** line grounded in measurement, and a **Recommendation**.
The ones marked 🔴 **GATE** must be settled before any code is written — they change the
architecture, not just the tuning. The rest can be deferred to the phase that needs them.

Fill in the summary table at the end and I'll build to it.

---

## 0. Two things I found while preparing this that change the plan

**0a. SVP's shipped RIFE models cannot be converted to CoreML. At all.**

I read the ncnn graph files. All three models contain a custom layer:

| Model | Layers | Custom `rife.Warp` ops | Other layer types |
| --- | --- | --- | --- |
| `rife-v4` | 139 | **8** | Convolution, Deconvolution, Crop, Concat, BinaryOp, Split, Interp, Eltwise, Sigmoid |
| `rife-v4.6` | 299 | **8** | + ReLU, PixelShuffle, MemoryData |
| `rife-v4.16lite` | 313 | **14** | + ReLU, PixelShuffle, MemoryData |

`rife.Warp` is a bespoke ncnn layer implementing the flow-warp step in a custom Vulkan shader.
coremltools has no ncnn frontend, and no ncnn→ONNX converter understands `rife.Warp`. Every other
op in the graph is standard and would convert fine.

**Consequence:** the CoreML tier must be built from the **original PyTorch RIFE** implementation
(upstream `hzwer/Practical-RIFE` and friends), where the same warp is expressed as
`torch.nn.functional.grid_sample` — an op coremltools *does* handle. SVP's models are a dead end.

**0b. No ML toolchain is installed on this machine.**

| Tool | Status |
| --- | --- |
| `coremltools` | **missing** |
| `torch` | **missing** |
| `onnx` | **missing** |
| `numpy` | 2.0.2 (system python 3.9.6 only) |
| Xcode 27.1 `coremlcompiler` | present |

So Phase 0 includes setting up an isolated conversion environment. Not hard, but it is a real step.

---

## 1. 🔴 GATE — Distribution channel

| Option | Effect |
| --- | --- |
| **A. Mac App Store** | Sandboxed. **Cannot** `dlopen` from `/opt/homebrew` — irrelevant now that we're not shipping ncnn/Vulkan. **Cannot** include GPL-2.0 code — irrelevant now that MVTools is out. So the App Store is **viable** with the CoreML plan. Costs: Apple review, 30% cut, sandbox limits on file access (user must grant folder access; no arbitrary path writes). |
| **B. Developer ID, direct download** | Full filesystem freedom, no review, own payment/licensing. Costs: you handle notarization, updates, and a licence-key system (which is what SVP does). |
| **C. Both** | One codebase, two targets. The sandboxed build is the constraint — build it first and the direct build is a superset. |

**Effect on the build:** the sandbox is the only real technical difference. Under A, batch
conversion output must go through a user-granted folder (security-scoped bookmark), and the app
cannot spawn helper processes freely — which also means the **4-worker batch model must run as
threads inside one sandboxed process, not as child processes.** My concurrency measurements were
taken with *separate processes*; in-process threads with separate `VTFrameProcessor` sessions should
behave the same or better, but I have **not** verified that. That is a Phase 0 item.

**Recommendation: C**, App-Store-first. Nothing in the measured design is App-Store-hostile any
more, and it keeps the option open. If you already know you want a licence key, choose B.

---

## 2. Quality tier scope — how far does the RIFE tier go?

| Option | Effect |
| --- | --- |
| **A. Batch only** | Quality tier available in conversion, not playback. Simplest. **Safe**, because the RIFE-in-real-time question never has to be answered. |
| **B. Batch + playback, gated on measurement** | Ship the tier in playback **only if** the CoreML spike proves it can sustain 60 output fps at the target resolution. |
| **C. Batch + playback, unconditionally** | Would require a lower resolution or a frame-dropping policy at playback. Risky. |

**The unknown that decides this:** SVP's ncnn+Vulkan RIFE measured **28.5 output fps at 1080p
(0.47× real-time)**. CoreML on the ANE could plausibly be 2–4× faster — RIFE is a plain CNN and the
ANE is good at those — but `grid_sample` may fall back off the ANE to GPU/CPU, which would kill that
hope. **I will not guess this. Phase 0 measures it.**

**Recommendation: B.** Batch-only is the guaranteed fallback; if the spike says real-time works,
playback gets it for free.

> **RESOLVED — see §16.** The tier was built and measured against ground truth on real 4K HDR film.
> VTFrameProcessor and CoreML RIFE 4.25 are statistically indistinguishable (Δ 0.105 MAE, |t| = 1.06)
> and RIFE costs **4.06×** the time. **The tier is dropped; VTFrameProcessor ships alone.** The
> options below are kept as the record of what was considered.

---

## 3. 🔴 GATE — Which RIFE variant, and converted how

| Option | Effect |
| --- | --- |
| **A. RIFE v4.x from upstream PyTorch** | Matches SVP's oldest shipped model (`rife-v4`, 139 layers — the *smallest* and, per my benchmark, the *fastest* of the three at 28.6 fps). Lowest conversion risk. |
| **B. Newer upstream (4.18–4.26)** | Better quality on hard motion, more layers, higher conversion risk, slower. |
| **C. RIFE v4.6** | Middle ground; SVP's mid-tier. 299 layers, 26.9 fps in ncnn. |
| **D. Skip CoreML; ship VTFP only** | Fastest to ship, loses the quality tier entirely. |

**Conversion route**, independent of variant:

| Route | Verdict |
| --- | --- |
| ncnn → CoreML | **Impossible** — custom `rife.Warp` (§0a) |
| ncnn → ONNX → CoreML | **Impossible** — same custom op |
| **PyTorch → coremltools → CoreML** | **The route.** Warp is `grid_sample`, which recent coremltools supports. Must be verified for RIFE's exact call (2-D, `align_corners=False`). |
| MPSGraph, hand-built with a custom grid-sample node | Fallback if coremltools chokes. More work, full control, still no Vulkan. |
| Ship ncnn+Vulkan as-is | **Ruled out** — 0.47× real-time, no concurrency scaling, Homebrew/Vulkan/MoltenVK dependency, App-Store-incompatible. |

**Recommendation: A first** (smallest, fastest, lowest risk — proves the pipeline), **then evaluate B**
once the harness works. Converting a second variant is cheap after the first.

---

## 4. How the interpolation timestep is handled

RIFE's network takes **two frames plus a timestep `t`** and outputs the frame at position `t`. For a
fixed 60 fps output you only ever need a handful of `t` values: 24→60 needs `t ∈ {0.2, 0.4, 0.6, 0.8}`.

| Option | Effect |
| --- | --- |
| **A. Bake one model per phase** | 4 models for 24→60 (plus 0.5 for 30→60). Each is static — no dynamic inputs, which is what the ANE likes best. Cost: ~4× model size (~40 MB if each is 10 MB) and 4× conversion runs. Fastest inference. |
| **B. One model with `t` as an input tensor** | ~10 MB total, handles *any* ratio including 23.976→60. Cost: a dynamic input can force the ANE back to GPU, and CoreML would need `t` as a 1-element tensor rather than the scalar PyTorch expects. |

**Effect:** unknown until measured — this is exactly the kind of thing that is 2× one way and 2× the
other. Both are cheap to try once the conversion environment exists.

**Recommendation: A**, and fall back to B if the model count becomes unwieldy or we need arbitrary
ratios. Note that A still covers every rate we care about, because the phase set for a fixed 60 fps
target is finite and known.

---

## 5. 🔴 GATE — Target output rate policy

You said "60 fps". Worth knowing what that costs, because for NTSC-family sources it is not free.

| Option | Effect (measured, 1080p, depth 2) |
| --- | --- |
| **A. Always 60.000** | 24→60: **80.3 fps**. 23.976→60: **77.6 fps** (0% passthrough). 29.97→60: **65.7 fps**. 59.94→60: **37.4 fps**. |
| **B. Always 59.94** | 23.976→59.94: **82.0 fps** (+5.7%, 20% passthrough). 29.97→59.94: **138.6 fps via the low-latency path** (+111%). 59.94→59.94: **free passthrough** (vs 37.4 fps). But 24.000→59.94 is slightly *worse* than →60.000. |
| **C. Auto per source** | 59.94 for NTSC-family sources (23.976/29.97/59.94), 60.000 otherwise. Gets every benefit above. Cost: two output cadences to test, and the user sees "59.94" in the UI which needs explaining. |

**Why the gap exists:** `23.976 × 2.5 = 59.94` exactly, so every second source frame lands on an
output position and needs no work. `23.976 × 2.5 = 60.000` is not exact, so **every** output frame
must be interpolated.

**Effect on the app:** this is the single biggest performance lever in the whole design, and it costs
nothing to implement — it's a decision, not a feature.

**Recommendation: C**, defaulting to 60.000 when the source rate is a clean 24/25/30/50.

---

## 6. 🔴 GATE — 4K policy

4K real-time is **not achievable** — 33.4 fps measured, against 60 needed. And the low-latency path
(used for exact-2× rates like 30→60) is **hard-capped at 1920×1080**, failing *silently* above it.

| Option | Effect |
| --- | --- |
| **A. 4K = batch only; playback refuses 4K files** | Honest and simple. User gets a clear "4K is conversion-only" message. |
| **B. 4K = batch only; playback downscales to 1080p and interpolates there** | 4K files still *play* at 60 fps, just not at 4K. Needs a scaler in the playback path (Metal, cheap). Likely what users actually want. |
| **C. 4K everywhere** | Not real-time. Playback would stutter or drop frames. Don't. |
| **D. Also offer the 1080p→4K upscale trick** | `VTLowLatencyFrameInterpolationConfiguration` can do 2× spatial upscaling in the same session — but **only for the exact-2× phase-0.5 case**, so 30/29.97 sources only. Narrow. |

**Recommendation: B**, with A's messaging. Costs one Metal scale pass; makes 4K files usable for
preview.

---

## 7. Playback pipeline depth (latency vs throughput)

| Option | Effect (1080p, 24→60) |
| --- | --- |
| **A. Depth 1 (lock-step)** | 60.9 fps — **fails** for 23.976 (56.7 fps). Latency ~70 ms. |
| **B. Depth 2 (pipelined)** | **82.5 fps** (+35%). Latency ~100 ms. |
| C. Depth 3+ | No further gain (82.4 / 82.8). |

**Effect:** depth 1 is not an option for playback — it cannot sustain 60 fps. Depth 2 adds ~30 ms of
latency, which is invisible for film viewing.

**Recommendation: B.** Non-negotiable, really; this is the difference between working and not.

---

## 8. Batch concurrency default

| Option | Per-job | **Aggregate** |
| --- | --- | --- |
| 1 worker | 81.8 fps | 81.8 fps |
| 2 workers | **94.6 fps** (best per-job) | 189.2 fps |
| 3 workers | 75.2 fps | 225.6 fps |
| **4 workers** | 61.8 fps | **247.2 fps** (best wall-clock) |

**Effect on a 2-hour film:** 1 w → 88 min · 2 w → 38 min · 4 w → **29 min**.

**Recommendation:** default to **4 workers** for a queue (fastest total), expose 1–4 in settings.
Caveat: measured with separate processes; must be re-verified as in-process threads under the
sandbox (§1).

---

## 9. Minimum macOS version

| Option | Effect |
| --- | --- |
| **A. macOS 26+** | `VTLowLatencyFrameInterpolationConfiguration` available → **30/29.97 → 59.94 runs at 138.6 fps**. Smallest install base. |
| **B. macOS 15.4+** | `VTFrameRateConversionConfiguration` available, so everything *works*, but 30/29.97 → 60.000 falls back to the FRC path at **65.7 fps** (still real-time, just 2× less headroom). Much larger install base. |

**Effect:** only matters for 30/29.97 fps sources. For your 24/23.976 film sources, **A and B perform
identically** (76.8 fps either way), because those use the FRC path regardless.

**Recommendation: B (15.4+)**, since your primary content is film-rate and gains nothing from 26.
Gate the low-latency path behind a runtime availability check and use it when present.

---

## 10. Encoder and output

| Decision | Options | Effect |
| --- | --- | --- |
| Codec | **HEVC** vs H.264 | HEVC: ~40% smaller at equal quality, hardware-encoded on M-series, but slightly less compatible with old players. H.264: universal. |
| Bitrate mode | Constant quality (CRF-like) vs target bitrate | Quality mode is the sane default for archival; bitrate mode for streaming targets. |
| 10-bit / HDR | 8-bit vs 10-bit passthrough | 10-bit preserves HDR and reduces banding. `VTFrameProcessor` supports 420v; 10-bit and HDR metadata handling is **not yet verified** and is listed as an open risk in `FEASIBILITY-AND-STACK.md`. |
| Audio | **Passthrough copy** vs re-encode | Passthrough is lossless, near-free, and avoids A/V drift. Re-encoding is only needed to change sample rate or channel layout. |
| Container | MP4 vs MOV vs MKV | MP4/MOV for AVFoundation-native writing; MKV needs FFmpeg and is read-only in practice. |

**Recommendation:** HEVC hardware, quality mode, 8-bit initially (verify 10-bit in a later phase),
audio copied untouched, MP4/MOV output. Expose codec choice in settings.

---

## 11. Passthrough frames

| Option | Effect |
| --- | --- |
| **A. Use passthrough** | 24→60: **20% of output frames need no interpolation** (120 of 600). 30→60: 50%. 29.97→59.94: 50%. Free performance. |
| **B. Always interpolate** | Simpler code path, uniform output. ~25% slower at 24→60, and re-interpolating a frame that exactly coincides with a source frame can only *lose* fidelity. |

**Recommendation: A.** Already implemented in the benchmark harness; it is a table lookup plus a
skip.

---

## 12. Behaviour when things go wrong

| Decision | Options | Effect |
| --- | --- | --- |
| Unsupported source (VFR, interlaced, 50 fps) | Refuse · Warn and convert anyway · Auto-fallback to a lower resolution | 50→60 measures 44.8 fps and cannot play in real time. VFR breaks the fixed phase table outright. |
| Engine fails mid-job | Abort · Retry with the other engine · Skip the frame | The low-latency path's *silent* failure above 1080p is the dangerous one — must be caught by checking the completion error, never by assuming success. |
| Quality tier unavailable (model missing / ANE unsupported) | Grey out · Silently fall back to VTFP | Silently changing the user's chosen quality is bad; grey it out with a reason. |

**Recommendation:** refuse VFR and interlaced with a clear message; auto-fallback to VTFP only with a
visible notice.

---

## Non-negotiable invariants

These are not choices. Each one is a measured failure mode, and violating any of them breaks the app:

1. **Never use the Swift `async` form of `process()`** — it returns in 0.08 ms and never writes the
   destination buffer. Use the completion-handler form.
2. **Recycle buffers from a `CVPixelBufferPool` ring.** Per-frame `CVPixelBufferCreate` crashes after
   65–90 frames.
3. **Keep 2 requests in flight.** Depth 1 fails 23.976→60 (56.7 fps).
4. **Use `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`.** Native decode/encode format; zero
   colour conversion. The API's `frameSupportedPixelFormats` misreports this — ignore it.
5. **Always check the completion-handler error.** The low-latency path fails *silently* above
   1920×1080; `startSession` still reports success.
6. **Leave `usePrecomputedFlow: false`.** Pre-computed flow measured 14% *slower*.
7. **Do not ship ncnn/Vulkan RIFE.** 0.47× real-time, no concurrency scaling, Homebrew/Vulkan/
   MoltenVK dependency.
8. **Do not convert SVP's model files.** They contain a custom `rife.Warp` layer; start from PyTorch.
9. **Request `.cpuAndGPU` for the RIFE tier.** `.all` — the *default* — is **8× slower** (307 ms vs
   39 ms). Not a tuning preference; the default is actively wrong for this graph.
10. **Pad every frame to a multiple of 64.** `IFBlock.conv0` does two stride-2 convs at scale=16, so
    H/16 must be divisible by 4. 16 is not enough — 544 silently restores to 576 and the warp breaks.
11. **Use `align_corners=True`.** The `align_corners=False` grid-rescale emulation buys nothing
    (ANE is equally slow either way) and costs 1.3/255.
12. **Use fp16, not fp32.** 7% faster, half the size, 68 dB PSNR against PyTorch.
13. **Do not use `4.25.lite`.** It is 5% *slower* than standard 4.25 (c=24 is a poor GPU width).
14. **Carry frame rates as exact rationals, never decimals.** `24000/1001`, not `23.976`. Measured on
    real film: a decimal rate drifts the interpolation phase 4e-7 per frame, which destroys **20% of
    the passthrough frames** on 23.976→59.94 and **50%** on 29.97→59.94. That is a 20–50% throughput
    loss, not a rounding detail. See `REAL-CONTENT-AB.md` §4.
15. **Detect scene changes and pass through at every cut.** Neither engine does this, and both produce
    a visible double-exposure when interpolating across a cut — verified on real film, both engines,
    the same frame. A 2 h action film has roughly 2000 cuts; without detection every one becomes a
    ghost frame. See `REAL-CONTENT-AB.md` §6.
    *A histogram-only rule is not enough on dark footage.* Measured on the reference clip: the cut at
    source frames **168→169** moves the spatial grid by 0.105 but the histogram by only 0.074, because
    both shots sit near black and their tonal distributions are genuinely similar — a histogram
    threshold that catches the other four cuts misses this one. The detector therefore needs a second
    path: a hard grid spike counts as a cut provided the histogram is at least *clearly not flat*
    (several times the recent median, with an absolute floor). Both paths are required; neither
    catches all five on its own.
16. **Never mix colour ranges inside the pipeline.** `VTFrameProcessor` works in
    `420YpCbCr8BiPlanarVideoRange` — luma 16..235. Any path that leaves NV12 for RGB comes back
    full-range 0..255. Comparing or blending the two invents a **16/255** offset on every pixel, which
    in a dark film is larger than any real difference being measured. This is the bug that made the
    first engine comparison wrong by **96%** (`ENGINE-EQUIVALENCE.md` §1). Stay in NV12 end to end;
    if a conversion is unavoidable, make it explicit and one-directional, and assert the range.
17. **A slot's buffers belong to the request that borrowed them until it completes.** Do not rely on
    the depth throttle to make a slot safe to reuse: that throttle lives *inside* `submit()`, which
    runs *after* the source frames have already been loaded into the slot. The result is that
    `VTFrameProcessor` reads a mix of old and new frame data, and the damage is disguised as success —
    a slow shot comes out barely wrong, a fast shot comes out very wrong, and the final interval is
    perfectly correct because nothing follows it to clobber the buffers. Measured on the reference
    clip: **378 of 475 output frames wrong, up to 40/255 MAE**, with every passthrough frame still
    byte-exact (they are copied synchronously, before the overwrite). Fixed by guarding each slot with
    its own semaphore, acquired before the load and released in the completion. After the fix the
    harness agrees with the standalone probe to within VT's own run-to-run noise.
18. **`VTFrameProcessor` is not bit-exact run to run.** Two renders of the same input with the same
    configuration differ by roughly **48 bytes of ±1/255** across a 475-frame 4K output (~1.5 bytes per
    affected frame). This is floating-point reduction order inside VT's kernels, not a bug. So
    *byte-equality* is the wrong acceptance test for this pipeline — it will report failure on a
    correct render. Compare with a 1-LSB tolerance and treat anything larger as real.

---

## Risks no decision removes

→ Superseded by **§13, "Risks no decision removes (updated)"**. This is the pre-Phase 0 version, and
its first row is now answered. Kept only so the record shows what was unknown before the spike ran.

---

## Summary table — **your decisions recorded**

| # | Decision | Options | My recommendation | **Your choice** |
| --- | --- | --- | --- | --- |
| 1 | Distribution | A App Store · B direct · C both | C | **Open source, DMG on GitHub. No App Store, no paid Developer account.** |
| 2 | Quality tier scope | A batch only · B batch + playback if measured | B | **DROPPED** — gate measured at 1080p (`PHASE0-COREML-RIFE.md`), then §16 measured the tier against ground truth and found it **statistically indistinguishable** from VTFrameProcessor at **4.06×** the cost. ✅ confirmed 2026-10-08 |
| 3 | RIFE variant | A v4.x · B 4.18+ · C v4.6 · D none | A, then B | **VOID** — no tier to put a variant in. The CoreML conversion used 4.25 as the instrument. |
| 4 | Timestep | A baked per phase · B input tensor | A | *(default applied)* |
| 5 | Target rate | A 60.000 · B 59.94 · C auto | C | **Always 59.94** |
| 6 | 4K | A refuse · B downscale · C all | B | **Keep true 4K, accept the drops** — recorded, with a downscale toggle built in |
| 7 | Playback depth | A 1 · B 2 · C 3+ | B | *(default applied — non-negotiable)* |
| 8 | Batch workers | 1 · 2 · 3 · 4 | 4 | *(default applied — no sandbox, so directly valid)* |
| 9 | macOS floor | A 26+ · B 15.4+ | B | *(default applied)* |
| 10 | Encoder | HEVC/H.264 · bitrate mode · 10-bit | HEVC, quality, 8-bit | *(default applied)* |
| 11 | Passthrough | A use · B ignore | A | *(default applied)* |
| 12 | Failure policy | refuse / warn / fallback | refuse VFR+interlaced | *(default applied)* |
| 13 | Notarization route | Cask+script · README xattr · pay $99 | Cask + script | **Homebrew Cask + de-quarantine install script** |
| 14 | Licence | MIT · Apache-2.0 | MIT | **MIT** |

---

## 13. Consequences of your choices

### 13.1 Open source, DMG on GitHub, no paid Developer account

**Two good outcomes:**

- **No sandbox.** So the app can spawn child processes, has full filesystem access, and needs no
  entitlements. That means my concurrency measurements — **247 fps aggregate at 4 workers, measured
  with separate OS processes** — apply **directly**, with no need to re-verify an in-process thread
  model. One Phase 0 item is deleted.
- **No App Store review**, no 30% cut, no sandbox file-access dance.

**⚠️ The catch you need to decide on: without a paid Apple Developer Program membership ($99/yr) you
cannot notarize.** macOS Gatekeeper will block an unnotarized DMG, and users will see
*"Apple cannot check it for malicious software"* or *"…is damaged and can't be opened"*.

Mitigations, best first:

| Approach | Effect |
| --- | --- |
| **Publish a Homebrew Cask** | `brew install --cask <app>` strips the quarantine attribute automatically. This is the standard route for unnotarized open-source Mac apps and makes install frictionless for anyone with Homebrew. |
| **`xattr` one-liner in the README** | `xattr -dr com.apple.quarantine /Applications/App.app` — works, but scares non-technical users. |
| **Install script** | A `curl … \| sh` that downloads, installs and de-quarantines in one step. |
| Ad-hoc sign (`codesign -s -`) | Improves integrity, does **not** satisfy Gatekeeper. |
| Free Apple ID | Gives a *development* certificate for local use — **not** distribution. |
| Pay $99 for Developer Program | Full notarization. Can be added later without changing the code. |

**Recommendation: DMG + Homebrew Cask + a de-quarantine install script.** I'll also make the build
script produce an ad-hoc-signed, hardened-runtime bundle so the only gap is Apple's notarization
stamp — then if you ever pay the $99, it's a one-command change.

**Licence:** since MVTools (the only GPL-2.0 component) is out, **MIT** is the natural choice and
matches RIFE's licence. Use Apache-2.0 instead if you want an explicit patent grant. **RIFE is MIT,
so its copyright notice must ship** in an About/Licences screen — I'll wire that in.

### 13.2 Always 59.94 — I measured the full sweep, and it is *not* uniformly better

| Source | → 59.94 | → 60.000 | Δ | Why |
| --- | --- | --- | --- | --- |
| **23.976** | **79.1** (20% passthrough) | 77.6 (0% passthrough) | **+2%** ✅ | shares the /1001 denominator |
| 24.000 | 74.8 (0% passthrough) | **80.3** (20% passthrough) | **−7%** ❌ | integer rate, no alignment |
| 25 | 73.1 | **75.8** | −3.6% | integer rate |
| **29.97** | **72.7** (50% passthrough) | 65.7 | **+10.7%** ✅ | shares /1001 |
| **29.97 via low-latency path** | **138.6** | n/a | **+111%** ✅ | exact 2× |
| 30 | 63.4 (FRC path) | **64.7** | −2% | integer rate |
| 50 | 42.4 | **44.8** | −5.4% | integer rate |

**Why:** 59.94 = 60000/1001. It shares the /1001 denominator with 23.976 (24000/1001) and 29.97
(30000/1001), so those align exactly and produce free passthrough frames. Integer rates (24.000,
25, 30, 50) do not align and lose their passthrough.

**Effect on your content:** if your films are **23.976** (NTSC Blu-ray/DVD), 59.94 is **optimal** —
79.1 fps and a clean 2.5× cadence. If any are **24.000** (cinema), you give up ~7% and the 20%
passthrough, but 74.8 fps is still comfortably real-time.

**Every value stays well above the 60 fps requirement**, so this is an efficiency choice, not a
feasibility one. I'll implement 59.94 as you asked. **One addition I'd suggest:** make it a setting
with 59.94 as the default, so a 24.000 source can be switched to 60.000 to recover its passthrough.

Two implementation notes: **30 and 29.97 sources must be routed to the low-latency path** (138.6 fps)
rather than the FRC path (63.4 / 72.7 fps) — that routing is now load-bearing, not an optimisation.
And on a 60.00 Hz display, 59.94 output means one frame repeat roughly every 16.7 s, which is
imperceptible and is exactly what all NTSC content already does.

### 13.3 RIFE 4.18+ — the conversion risk is **resolved**, and I found the version to use

I pulled the coremltools op registry (278 registered torch ops) and checked RIFE's full op set:

| RIFE op | coremltools | Notes |
| --- | --- | --- |
| **`grid_sample`** (the warp) | ✅ **supported** | registered as `grid_sampler` → MIL `resample`, with exactly RIFE's arguments: `sampling_mode=bilinear`, `padding_mode=border`, explicit grid, `align_corners=True` passed through, `coordinates_mode=normalized_minus_one_to_one` |
| `Conv2d` / `ConvTranspose2d` | ✅ | `_convolution` |
| `PReLU`, `LeakyReLU`, `ReLU`, `Sigmoid` | ✅ | `prelu`, `leaky_relu`, `relu`, `sigmoid` |
| `cat`, `mul`, `add`, `sub`, `div`, `pad` | ✅ | all registered |
| `PixelShuffle` | ✅ | `pixel_shuffle` |
| `F.interpolate` | ✅ | `upsample_bilinear2d`, `upsample_nearest2d`, `upsample_bicubic2d` |

**The whole RIFE v4.x graph converts.** The remaining unknown is *speed*, not *convertibility*.
coremltools latest is **9.0**.

**Which version.** The upstream README states: *"it is recommended to choose 4.25 by default for most
scenes."* Available: **4.26** (2024.09.21, newest), **4.25** (2024.09.19, maintainer's default),
**4.25.lite** (2024.10.20, lower cost). All MIT.

**Practical constraints:** the repo requires **python ≤ 3.11**; this machine has 3.9.6 and 3.14.6, and
PyTorch has dropped 3.9 — so Phase 0 needs a **Python 3.11 environment**. Model files are `*.py`
(architecture) + `flownet.pkl` (weights).

**Independent confirmation of §13.4:** RIFE's own docs recommend `--scale=0.5` (UHD mode) for 4K
input — i.e. **RIFE itself downscales 4K before interpolating.** The same conclusion I reach below.

> ### ✅ MEASURED — see `PHASE0-COREML-RIFE.md`
>
> Convertibility is no longer a prediction. RIFE 4.25 was converted and benchmarked:
> **all 18 warps became `resample`, zero leftovers, 68.0 dB PSNR against PyTorch.**
>
> **But the speed gate FAILS:** 1080p gives **25.9 calls/s against the 47.9–59.8 required**, so the
> quality tier is **batch-only** (decision #2 resolved). Two corrections to this section: the warp
> uses **`align_corners=True`**, not `False`; and RIFE needs dimensions divisible by **64**, not 16.
> A third finding worth more than either: **`.all` compute units is 8× slower than `.cpuAndGPU`.**

### 13.4 4K: allow, accept dropped frames — **I want to revisit this one**

You chose to allow 4K playback and accept dropped frames. I'll build what you confirm, but the
measured numbers are harsher than "dropped frames" implies:

> **4K 24→60 measures 33.4 fps against the 60 needed — 44% of frames are missing.** Playback would
> run at roughly **half speed with visible judder**. That is not graceful degradation, it is
> unwatchable.

Also note the **low-latency path is hard-capped at 1920×1080**, so 30/29.97 fps 4K sources cannot use
the fast path at all.

The fix is to **decouple display resolution from interpolation resolution**:

| Option | What happens | Measured |
| --- | --- | --- |
| **A. Interpolate at 1080p, upscale to 4K for display** *(my recommendation)* | Smooth 60 fps, 4K file still plays full-screen. Costs one cheap Metal upscale. You lose true-4K detail but keep motion. | interpolation at 1080p = **80.8 fps**, real-time with 35% margin |
| B. Play 4K at 30 fps output | No judder from missing frames, but not 60 fps | 30 fps target |
| C. True 4K 60 fps with drops *(your choice)* | Honest, but ~44% of frames missing | **33.4 fps** |
| D. Block 4K playback | Clear "conversion only" message | — |

Option A is still "allow 4K playback" — it just stops paying 4K interpolation prices for a benefit
the display cannot show anyway. It is also what RIFE's own documentation does for 4K.

**Decision recorded: you kept Option C — true 4K, accept the drops.** I'll build it that way. Two
things I'll do so the choice is reversible and never silent:

1. **A visible "resolution" setting** (Full / 1080p-interpolated) with **Full** as the default, so
   the behaviour matches what you chose but a 4K title that judders can be fixed in one click.
2. **An honest UI readout** — when a 4K source is playing below the 60 fps target, show the measured
   output rate rather than pretending. No silent degradation.

The measured cost of your choice, for the record: **4K 24→60 = 33.4 fps** (needs 60), and 30/29.97
fps 4K sources cannot use the low-latency fast path at all because it is hard-capped at 1920×1080.

**Now measured on your own disc** (`REAL-CONTENT-AB.md`) — 3840×1632, 23.976 → 59.94:

| | 4K | 1080p | 4K costs |
| --- | --- | --- | --- |
| Playback, VTFrameProcessor | **31.2 fps** → 48% of frames dropped | **75.9 fps** → smooth, above real-time | — |
| Batch, 2 h film, VT | **3.8 h** | **1.6 h** | **2.4×** |
| Batch, 2 h film, RIFE | **15.6 h** | **4.2 h** | **3.7×** |

So the "dropped frames" you accepted are **48% of them**, and the batch penalty for true 4K is
**2.4× (VT) to 3.7× (RIFE)**. Option A is still available and is now backed by measurement rather than
extrapolation — but the choice is recorded and I will build Option C unless you say otherwise.

---

## Risks no decision removes (updated)

| Risk | Status |
| --- | --- |
| **Can CoreML RIFE hit 60 fps at 1080p?** | ✅ **ANSWERED — NO. 25.9 calls/s vs 47.9–59.8 needed (0.43–0.54×).** Measured on M2 Max GPU, which saturates at ~50 Mpx/s. Tier is batch-only. |
| **Is CoreML RIFE's quality actually better than VTFP?** | **The instrument now exists.** A real 4K HDR clip from your disc has been run through both engines — `~/Desktop/FNF-60FPS-A-B/`. Still needs your eyes: PSNR proves faithfulness to PyTorch (68 dB), not beauty. |
| ~~In-process thread concurrency~~ | **Deleted** — no sandbox, so separate processes work (§13.1). Also moot: RIFE shows *no* concurrency scaling at all (GPU-saturated). |
| ~~Scene cuts~~ | **Found, and it is now a build requirement rather than a risk.** Both engines double-expose across a cut. Invariant 15. |
| HDR handling | **Partly answered.** The source is HDR10/PQ/BT.2020, and this machine's ffmpeg cannot tone map it (`zscale` absent, `scale_vt` ENOSYS). Hand-rolled numpy tone mapping works (`analysis/hdr_tonemap.py`). **Whether the app tone maps or stays HDR end-to-end is still undecided.** |
| A/V drift over long playback | Unverified. |
| Gatekeeper friction without notarization | Known, mitigated by Homebrew Cask + install script (§13.1). |

| Phase | Goal | Exit criterion |
| --- | --- | --- |
| **0 — Spikes** | (a) CoreML conversion env; (b) convert RIFE v4.x; (c) **measure CoreML RIFE fps at 1080p**; (d) verify in-process concurrency | A number for CoreML RIFE, and a yes/no on the real-time quality tier |
| **1 — Interpolation core** | Shared `Interpolator`: phase table, passthrough mask, pool ring, depth-2 queue, error checking | 23.976→60 at 1080p ≥ 60 fps sustained, verified output |
| **2 — Playback** | Decode → interpolate → present, A/V sync | 30 min continuous playback, no drift, no crash |
| **3 — Batch** | Reader → interpolate ×N workers → encode → writer, audio passthrough | A 2 h film at 1080p in under 35 min |
| **4 — Quality tier** | RIFE/CoreML behind the engine protocol | Switchable, output verified, no Vulkan anywhere |
| **5 — Polish & ship** | Settings, 4K downscale path, notarize, sandbox entitlements | Notarized build |

**Phase 0 is the one that matters.** Everything else is engineering I'm confident in. Whether the
CoreML quality tier is real-time is the only genuine unknown, and it is cheap to answer before
committing.

---

## 14. Where the build order actually stands

Phase 0 is done; §13.3 is answered. Two questions remain open, and they are **not** the same size —
which is the thing I got wrong in my first framing.

### 14.1 The RIFE tier question should be answered *later*, not now

> **✅ COMPLETE — all three steps ran, in this order.** Phase 1 was not started first, because step 2
> turned out to be cheap and step 3 then removed work from step 1. The sequence below is the record of
> the plan; the outcome is in §16.

I originally asked for a decision on the batch-only RIFE tier immediately. On reflection that is the
wrong order, because the decision turns on something **I cannot measure**: whether RIFE's output
actually looks better than `VTFrameProcessor` on real film. PSNR proves faithfulness to PyTorch
(68 dB); it says nothing about beauty.

So the sequence should be:

1. **Phase 1 — the shared `Interpolator` core.** Engine-agnostic; does not depend on this decision.
2. **A/B one real film clip through both engines.** Minutes, not hours — and it replaces my guess
   with your judgement.
3. **Then** decide the tier, looking at something rather than reading a table.

### 14.2 A new option: a reduced-resolution RIFE *preview*

> **❌ DROPPED with the tier (§16).** This was proposed as a decision aid — watch motion quality live
> before committing a long batch. The decision it was meant to aid is now made, so the aid is moot.
> Kept as the record.

RIFE's cost is a flat ~50 Mpx/s, so its real-time resolution depends on the source rate:

| Conversion | Calls/s needed | Max real-time resolution |
| --- | --- | --- |
| 23.976 → 59.94 | 47.9 | ~1362×766 |
| 24.000 → 59.94 | 59.8 | ~1219×685 |
| 29.97 → 59.94 | 29.9 | ~1724×969 |

Measured, 960×576 gives **75.1 calls/s** — 1.57× the 47.9 that 23.976 needs. So RIFE *can* run
real-time at low resolution, even though it cannot at 1080p.

That is worth having even if the batch tier is dropped: a **RIFE preview mode at ≤768p** lets you
watch motion quality in motion, live, before committing a 3.7-hour batch. It is a decision aid, not a
shipping quality tier, and it should be labelled as such in the UI.

### 14.3 Cost of the tier, stated plainly

| | VTFrameProcessor | RIFE / CoreML |
| --- | --- | --- |
| 2 h film, 1080p, inference only | ~1.2 h | **~3.7 h** |
| GPU during the run | free between calls | **saturated ~4 h** |

The wall-clock ratio is ~3×. The cost that matters more is that RIFE saturates the GPU for the entire
run, so the machine is not usable for other GPU work while a film converts.

The **marginal** cost of the tier is small, though: the model is already converted (20 MB), and the
engine protocol has to exist for `VTFrameProcessor` regardless. It is one more conforming type plus a
UI affordance — not a new subsystem.

---

## 15. Real-content A/B — measured on your own disc

Full report: `REAL-CONTENT-AB.md`. Artifacts: `~/Desktop/FNF-60FPS-A-B/`.

An 8-second clip from **3204.5 s** (film clock 53:24 — the middle of the film), 3840×1632, 23.976 fps,
HDR10, run through both engines with identical source frames and identical phases.

### Measured

| | 4K — 3840×1632 | 1080p — 1920×816 |
| --- | --- | --- |
| VTFrameProcessor | 15.2 s → **31.2 fps** | 6.3 s → **75.9 fps** |
| CoreML RIFE 4.25 | 61.8 s → **7.7 fps** | 16.5 s → **28.8 fps** |
| RIFE penalty | **4.1×** | **2.6×** |

Zero errors in all four runs; every verification check passed. RIFE's CoreML graph runs at a flat
**~54 Mpx/s**, so its cost is predictable from pixel count alone.

### Two findings that are build requirements, not test details

**1. Exact rational frame rates — worth 20%.**
23.976 → 59.94 is exactly 2.5×, so 95 of 475 output frames need no interpolation at all. Carrying the
rate as a decimal (`59.94` instead of `60000/1001`) drifts the phase 4e-7 per frame and loses **all
95 of them**. Fixed with exact integer arithmetic: RIFE **+22%**, VT **+8%**. Now invariant 14.

**2. Scene-change detection is mandatory.**
The clip contains 5 cuts. Both engines produce a **visible double-exposure** when interpolating across
a cut — verified side by side on the same output frame. Neither engine detects cuts, and neither is
expected to. A 2 h action film has roughly 2000 of them. Now invariant 15, and a new Phase 1
deliverable.

### HDR

The source is PQ/BT.2020 with a 1000-nit P3 master, and this machine's ffmpeg **cannot** tone map it:
no `zscale` (no libzimg), and `scale_vt` fails with `ENOSYS`. Tone mapping is hand-rolled in
`analysis/hdr_tonemap.py`. Whether the app tone maps or keeps HDR end-to-end is **still undecided**.

### Cost, projected to a 2-hour film at 59.94

| | VTFrameProcessor | CoreML RIFE |
| --- | --- | --- |
| **4K** | **3.8 h** | **15.6 h** |
| **1080p** | **1.6 h** | **4.2 h** |

---

## 16. Engine equivalence — the RIFE tier question is **closed** ✅ **CONFIRMED**

You watched the comparison and said *"they look identical to me."* You were right. Full analysis:
[`ENGINE-EQUIVALENCE.md`](ENGINE-EQUIVALENCE.md).

**Measured, range-corrected, engine vs engine:**

| | MAE mean | MAE median |
| --- | --- | --- |
| interpolated frames (n=380) | 1.524 | 1.072 |
| passthrough frames (n=95) | 0.377 | 0.373 |

463 of 475 output frames agree to within **3/255**; the whole clip is **34.0 dB** PSNR between the two
engines. The other 12 frames are the five scene cuts — and outside those, the largest disagreement
anywhere in the clip is **1.777/255**.

**And ground truth** — delete every odd source frame, ask each engine to put it back at t=0.5 exactly,
score against the real frames (95 held out, 4K):

| | MAE median | PSNR mean |
| --- | --- | --- |
| repeat previous frame | 7.692 | 24.12 |
| 50/50 linear blend | 5.894 | 26.74 |
| **VTFrameProcessor** | **2.572** | 32.17 |
| **CoreML RIFE 4.25** | 2.581 | 32.25 |

Head to head: VT 28 wins, RIFE 67, 22 ties. mean(VT − RIFE) = **+0.105 MAE**, paired **|t| = 1.06** —
**not significant**. RIFE's entire quality advantage is 0.105 MAE out of 2.6, for **4.06×** the time.

### Decision

**Drop the RIFE tier. Ship VTFrameProcessor alone.** ✅ **Confirmed by you, 2026-10-08.** This reverses
§2's recommendation and `WHY-NOT-RIFE.md` §9, both of which assumed RIFE's value was quality without
testing it. Now it is tested, against ground truth, on real 4K HDR film. There is no quality argument
left to pay 4× for.

Decision #3 (which RIFE variant) is therefore **void** — there is no tier to put a variant in.
§14.2's reduced-resolution RIFE *preview* is also dropped with it: it existed to answer this question,
and the question is answered.

- Engine: VTFrameProcessor, single tier. No CoreML, no model download, no second code path.
- `analysis/coreml/` stays as the instrument that proved it, and as the starting point if a future
  title shows a gap.
- **Scene-change detection is now the only measured quality difference between the engines' outputs** —
  and it is a difference between two flavours of wrong. Both must pass the source frame through at a
  cut. Invariant 15, Phase 1, not optional.

### Two things this test also fixed

**The instrument was wrong by 96% on the first pass.** The first comparison read **MAE 12.9/255 on
every frame**. The tell was frame k=0 — a passthrough frame, where both engines emit the source frame
verbatim, so the difference must be ~0. Fitting one buffer to the other gave
`luma_rife = 1.16485 × y_vt − 19.170`, which is the textbook limited→full-range conversion
(`1.16438 × y − 18.628`). VT writes studio-range NV12, RIFE writes full-range rgb24; comparing them raw
invents a 16/255 offset on every pixel, and this film is dark enough that most pixels live near black.
Corrected: **12.928 → 0.516**. The delivered videos were never affected — both were encoded through the
same swscale path.

**Diff gain is a correctness issue, not a taste one.** An early `|difference| ×32` build made the
1/255 rounding difference visible as grey noise on every frame — visually implying the engines
disagreed everywhere, the opposite of the truth. The shipped artifacts use **×4**, which keeps a
typical difference nearly black (3–7/255) while a real one blazes (47–74/255 at the cuts).

### What would change this

One 8-second clip from one film is one data point. The result is decisive *for this content*. RIFE's
reputation rests on occlusion, large displacement, animation and grain; this clip is a dark, largely
translational shot. If a future title shows visible ghosting where VT struggles, re-run
`analysis/gt_holdout.py` — it takes about four minutes.

---

## What I need from you

**All three answers are in — 2026-10-08.**

1. ✅ **Drop the RIFE tier.** Confirmed. §16 is closed; decisions #2 and #3 are resolved and void.
2. ✅ **Start Phase 1.** Confirmed, and the core is now built and validated. The `Interpolator`
   package (exact-rational `FrameRate`, integer `PhasePlan`, `SceneChangeDetector`, `NV12` bridge,
   `VTFrameProcessorEngine`) plus a headless `interp-harness`, with **34 tests in 5 suites passing**.
   It carries three deliverables out of testing: **scene-change detection** (invariant 15),
   **exact-rational rate handling** (invariant 14), and **range-correct buffers end-to-end**
   (invariant 16). Two further invariants were earned during the build: **slot ownership across the
   pipeline** (17) and the fact that **VT is not bit-exact run to run** (18).

   Validated end to end on the reference clip — `FNF_60FPS.nv12`, 191 frames at 3840×1632,
   24000/1001 → 60000/1001:

   ```
   scenes: 5 cut(s) in 191 frames
           between source frames: 6-7, 69-70, 101-102, 108-109, 168-169
   plan  : 475 out frames = 370 interpolated + 105 passthrough
           10 of those interpolations were turned into passthroughs by scene detection
   wall  : 19.4s | OUTPUT 24.5 fps | 104.7 ms/interval
   [PASS] passthrough frames byte-identical to source
   [PASS] wrote 475/475 frames
   ```

   The 105 passthroughs decompose exactly as predicted: **95 exact-rate** (every 5th frame, the free
   20% from invariant 14) plus **10 cut-forced** (2 per cut, each resolved to the nearest source frame
   — phase < 0.5 takes the outgoing shot, ≥ 0.5 the incoming). Verified by hashing every output frame
   against the source: `16→6, 17→7, 173→69, 174→70, 253→101, 254→102, 271→108, 272→109, 421→168,
   422→169`.
3. ⏸ **4K — parked at your request.** Not needed until Phase 2. The numbers when you want them: your
   recorded choice costs **48% dropped frames in playback** and **2.4–3.7× in batch time** (§13.4).
   With the quality argument now gone, this is a pure speed decision.

Still genuinely open, and not blocking: **HDR output policy** — tone map to SDR, or stay HDR
end-to-end (§15).
