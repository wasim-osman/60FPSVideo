# 60 fps output — feasibility and measured performance

> ## ⚠️ Partly superseded — read [`PLAYBACK-AND-BATCH.md`](PLAYBACK-AND-BATCH.md) first
>
> Everything below was measured in a **lock-step** harness: submit one `process()` call, block on the
> completion handler, submit the next. That harness leaves **~35% of the hardware idle**, so every
> throughput figure here is a *floor*, not a best case.
>
> Two conclusions in this report were **wrong** and are corrected in the newer report:
>
> 1. **§4 says to use pre-computed optical flow (`VTOpticalFlowConfiguration`) to buy margin for
>    24 → 60.** I built and measured it: it is **14% slower**, not faster (53.0 fps vs 60.3 fps).
>    Leave `usePrecomputedFlow: false`.
> 2. **§4 says 640×360 fails on the low-latency path, implying a minimum size.** That was
>    **transient resource contention**, not a resolution limit. Re-tested 3× each, 640×360 / 854×480 /
>    960×540 all pass.
>
> The **1920×1080 ceiling** on the low-latency path is real and was re-verified with an error-aware
> harness — but note it fails *silently*: the session starts, then every `process()` errors and the
> destination buffer is never written.
>
> Corrected headline figures at 1920×1080 with two requests in flight:
> 24 → 60 is **80.3 fps** (not 60.1), 23.976 → 60 is **76.8 fps**, 25 → 60 is **75.8 fps** (not 55.2).

**Question:** the app should only ever output 60 fps. Is that possible?

**Answer: yes at 1080p and below, with real headroom. No at 4K for real-time playback — 4K is
offline-conversion only on M2 Max.**

The difficulty depends entirely on the **source** frame rate, and there are two different Apple APIs
to use depending on which one you have.

Measured 2026-10-08 on Mac14,6 (Apple M2 Max, 38-core GPU, 64 GB), macOS 27.0.1 (26A434).

---

## 1. Which source rates are easy and which are hard

For a fixed 60 fps output, each source frame rate needs a specific set of interpolation phases
(where the output frame falls between two source frames):

| Source | Ratio to 60 | Non-zero phases needed | Expressible on the low-latency grid? |
| --- | --- | --- | --- |
| 60 | 1.0× | none — passthrough | n/a |
| **30 / 29.97** | **2.0×** | **0.5 only** | **yes** |
| 24 / 23.976 | 2.5× | 0.2, 0.4, 0.6, 0.8 | no |
| 25 | 2.4× | 0.083, 0.167, 0.25, 0.333, 0.417, 0.5, 0.583, 0.667, 0.75, 0.833, 0.917 | no |
| 50 | 1.2× | 0.167, 0.333, 0.5, 0.667, 0.833 | no |
| 48 | 1.25× | 0.2, 0.4, 0.6, 0.8 | no |

**Why this matters.** `VTLowLatencyFrameInterpolationConfiguration` exposes interpolation points
only at *k/2ⁿ* — that is, `numberOfInterpolatedFrames = 1` gives one point at 0.5, `= 2` gives three
points at 0.25 / 0.5 / 0.75, and so on. That grid contains 0.5 but **not** 0.2, 0.4, 0.6 or 0.8.

So:

- **30 → 60 and 29.97 → 59.94 use the fast low-latency path.** Exact 2×, single phase 0.5.
- **24, 25, 48 and 50 fps sources must use `VTFrameRateConversionConfiguration`**, which accepts an
  arbitrary `[Float]` phase array. That path is slower and has a lower resolution ceiling for
  real-time use.

This was verified at pixel level: on the same source pair, phase 0.40 and phase 0.80 produce
**different** output frames — so the arbitrary-phase path is genuinely interpolating at the
requested positions, not snapping to a grid.

---

## 2. Measured throughput for 60 fps output

### 2a. Low-latency path — 30 → 60 fps

| Resolution | Per-call latency | Output fps | 60 fps? |
| --- | --- | --- | --- |
| 1920×1080 | 14.12 ms | **141.6** | yes — 2.4× headroom |
| 1280×720 | 4.24 ms | **471.8** | yes — huge headroom |

**Resolution ceiling: 1920×1080.** Above that the configuration initialises but the session
silently fails to start, and every `process()` call returns
`VTFrameProcessorErrorDomain Code=-19730 "Processor is not initialized"`:

| Resolution | Result |
| --- | --- |
| 1280×720 | OK |
| 1920×1080 | OK |
| 2048×1080 | fails — not initialized |
| 2560×1440 | fails — not initialized |
| 3840×2160 | fails — not initialized |
| 7680×4320 | fails — not initialized |

### 2b. Arbitrary-phase path — 24 → 60 fps

Here two phases are batched into a single `process()` call (phases `[0.4, 0.8]` alternating with
`[0.2, 0.6]` per source interval), because batching shares the optical-flow computation.

These are **lock-step** numbers. With two requests in flight (see the newer report) the same
conversions run at **80.3 fps** (1080p) and **33.4 fps** (4K):

| Resolution | Per-call latency | Output fps | 60 fps? |
| --- | --- | --- | --- |
| 1920×1080 | 34.42 ms (2 frames/call) | **60.1** | yes — but only just |
| 1280×720 | 31.59 ms (2 frames/call) | **68.2** | yes |
| 3840×2160 | 83.46 ms (2 frames/call) | **22.9** | **no** |

### 2b-bis. PAL sources — 25 → 60 and 50 → 60 fps

These are the hardest cases, and the measurements were worse than first estimated. Both clear 60 fps
once the submissions are pipelined — see the newer report.

| Conversion | Phases per interval | Interp frames needed/sec | Output fps @ 1080p (lock-step) | 60 fps? |
| --- | --- | --- | --- | --- |
| 25 → 60 | 2, 2, 3, 2, … (11 distinct) | 54 | **55.2** | short by 9% |
| 50 → 60 | 1 (5 distinct) | 50 | **34.0** | short by 76% |

Pipelined (depth 2), 25 → 60 rises to **75.8 fps** and clears the bar. **50 → 60 only reaches
44.8 fps** and stays below 60 — that one is genuinely not real-time.

**50 → 60 is the worst case in the whole table.** Two factors compound: the 1.2× ratio means
almost every output frame must be interpolated (only 1 in 6 is a passthrough), *and* each source
interval needs only a single phase, so there is nothing to batch — the full per-call overhead is
paid for one frame at a time.

25 → 60 is close to viable at 55.2 fps. It would likely clear 60 fps with pre-computed optical flow
or with the CPU-side harness overhead removed.

### 2c. Comparison: the same conversion without batching

| Conversion | Path | Calls | Output fps |
| --- | --- | --- | --- |
| 30 → 60 @ 1080p | FRC, 1 phase per call | 60 | 56.1 |
| 24 → 60 @ 1080p | FRC, 2 phases per call | 60 | 60.1 |

**Batching is worth roughly 1.6× per frame.** A single-frame call cost 27.2 ms; a two-frame call
cost 34.4 ms — 17.2 ms per output frame instead of 27.2 ms. Optical flow is computed once and reused
across the requested phases.

Note that 30 → 60 through the *frame-rate-conversion* path is slower than 24 → 60 through the same
path, purely because 30 → 60 cannot batch (only one phase exists per interval) while 24 → 60 can.
This is exactly why 30 → 60 should use the low-latency API instead.

---

## 3. What this means for a 60 fps-only app

**The constraint helps.** Fixing the output at 60 fps removes the hardest part of a general-purpose
frame interpolator:

1. **One output cadence.** No adaptive rate logic, no dynamic phase negotiation. The phase pattern
   for each source rate is a fixed lookup table computed once.
2. **Few distinct phases.** 30 → 60 needs one phase. 24 → 60 needs four. That is a small, cacheable
   set.
3. **A large fraction of output frames need no interpolation at all.** Passthrough frames are
   free — you simply display the decoded source frame:
   - 30 → 60: 50% of output frames are passthrough (every source frame)
   - 24 → 60: 20% are passthrough (every second source frame)
4. **Engine selection is a simple rule.** `source_fps × 2 == 60` → low-latency path;
   otherwise → arbitrary-phase path. That is the whole decision.

### Recommended routing

```
source rate            path                                    ceiling
──────────────────────────────────────────────────────────────────────────────
30 / 29.97 fps   ->    VTLowLatencyFrameInterpolation          1080p   (139 fps @ 1080p)
60 / 59.94 fps   ->    passthrough, no interpolation           any
24 / 23.976 fps  ->    VTFrameRateConversion, batched phases  1080p   (80.3 / 76.8 fps pipelined)
25 fps           ->    VTFrameRateConversion, batched phases  1080p   (75.8 fps pipelined)
50 fps           ->    VTFrameRateConversion, batched phases  —       (44.8 fps — not real-time)
any -> 4K        ->    offline conversion only                 —       (33.4 fps pipelined)
```

(All figures at 1920×1080 except the 4K row, and with two requests in flight — see
[`PLAYBACK-AND-BATCH.md`](PLAYBACK-AND-BATCH.md).)

---

## 4. Caveats and honest limits

- **4K real-time 60 fps is not achievable on M2 Max.** 22.9 output fps against a 60 fps target is
  2.6× short. 4K should be positioned as an offline/batch conversion feature. A partial mitigation
  exists — `VTLowLatencyFrameInterpolationConfiguration` supports 2× spatial upscaling in the same
  session, so you could interpolate at 1080p and upscale to 4K — but that is a quality trade-off and
  the scaling path only supports phase 0.5, so it applies to 30 → 60 only.
- **24 → 60 at 1080p is right at the threshold** (60.1 measured against 60 required) — *in this
  lock-step harness*. The margin problem is solved by keeping two requests in flight, which lifts it
  to **80.3 fps**. Do that rather than pre-computing optical flow: I measured pre-computed flow and it
  is **14% slower** (53.0 vs 60.3 fps), because Apple's on-the-fly flow is already as efficient as the
  standalone flow session. These measurements also include harness overhead a production pipeline
  would not have — synthetic frame generation writes roughly 8 MB of pixel data per call, plus a
  semaphore round trip and CPU pixel reads.
- **25 → 60 is short by 9%** (55.2 fps measured) *in lock-step only*. Pipelined it reaches
  **75.8 fps** and clears the bar comfortably. No optical-flow work is needed.
- **50 → 60 is not real-time at 1080p** (34.0 fps lock-step, **44.8 fps** pipelined). It is the worst
  case measured: almost every output frame needs interpolation *and* only one phase exists per source
  interval, so batching gives nothing. PAL 50 fps sources need offline conversion, a lower source
  resolution, or a different approach.
- **The 1080p ceiling on the low-latency path is measured on M2 Max.** It may differ on other
  chips. Re-measure on your target hardware. Note the failure is **silent** — the session starts
  successfully, then every `process()` returns `-19730` and the destination buffer is never written,
  so always check the completion-handler error.
- ~~**640×360 failed** on the low-latency path with a different error (`-19740`), so there appears to
  be a minimum size as well as a maximum.~~ **Retracted:** that was transient resource contention.
  Re-tested 3× each, 640×360, 854×480 and 960×540 all pass. There is no minimum size.
- As established earlier, use the **completion-handler** form of `process()`, not the Swift `async`
  form, and **recycle buffers** from a small `CVPixelBufferPool` ring.

---

## 5. Bottom line

| Content | Real-time 60 fps on M2 Max (pipelined, depth 2) |
| --- | --- |
| 720p, 24 or 30 fps source | **yes, comfortably** |
| 1080p from 30/29.97 fps | **yes, ~2.3× headroom** (139 fps via low-latency) |
| 1080p from 24/23.976 fps | **yes** — 80.3 / 76.8 fps, ~28–34% headroom |
| 1080p from 25 fps | **yes** — 75.8 fps |
| 1080p from 50 fps | **no** (44.8 fps) |
| 4K, any source rate | **no** — offline conversion only (33.4 fps) |

A 60 fps-only app is a **more** achievable target than a general-purpose interpolator, not less.
The two things to settle early are:

1. **What happens with 4K sources** — this determines whether you need a batch-conversion mode
   alongside playback.
2. **Whether PAL 50 fps is in scope** — if it is, it needs offline conversion or a resolution
   fallback, because it will not play back at 60 fps in real time.

For the playback-plus-batch design and the corrected throughput figures, see
[`PLAYBACK-AND-BATCH.md`](PLAYBACK-AND-BATCH.md).

---

## Reproduce

```bash
cd analysis/probes
swiftc -O -o vts60 vt_60fps.swift      # arbitrary-phase path
swiftc -O -o vtll  vt_ll_60.swift      # low-latency path
swiftc -O -o vtlllim vt_ll_limits.swift # resolution ceiling probe

./vts60 1920 1080 24 60     # 24 -> 60 fps at 1080p
./vts60 1280 720  24 60     # 24 -> 60 fps at 720p
./vtll  1920 1080 80        # 30 -> 60 fps via low-latency
./vtlllim                   # sweep resolutions on the low-latency path
```
