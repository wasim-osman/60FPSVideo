# 60FPSVideo

Feasibility study and stack design for a **native Apple Silicon** video frame-interpolation
application — real-time playback **and** batch conversion, with output pinned to the 60-family
frame rate (**59.94 by default** — see `reports/BUILD-DECISIONS.md` §5).

The reference product analysed is **SVP 4 Mac** (`/Applications/SVP 4 Mac.app`), using
[`morluto/rea`](https://github.com/morluto/rea) as the reverse-engineering toolchain.

## Headline result

A native Apple Silicon implementation is **feasible**, and it does not require reimplementing
SVP's engine. Apple's `VTFrameProcessor` (VideoToolbox) provides first-party frame interpolation
that was measured **real-time at 1080p on an M2 Max**.

Both playback and batch conversion are achievable from one shared interpolation engine:

| Source → 60 fps @ 1920×1080 | Output fps | Real-time? |
| --- | --- | --- |
| **24.000 (film)** | **80.3** | **yes — 34% headroom** |
| **23.976 (NTSC film)** | **76.8** | **yes — 28% headroom** |
| 25 (PAL film) | 75.8 | yes |
| 29.97 | 64.7 | yes |
| 50 | 44.8 | no — batch only |
| 59.94 | 37.4 | no — batch only |
| 4K, 24 → 60 | 33.4 | no — batch only |

Measured at **60.000**. The shipped default is **59.94**, which for NTSC-family sources is the cheaper
target because the rates share a denominator: 23.976 → 59.94 runs at **79.1 fps** with **20% of output
frames needing no interpolation at all**, against 76.8 fps and 0% at 60.000. Integer rates (24.000, 25,
30, 50) are the other way round and keep their passthrough at 60.000, which is why the policy is a
setting with 59.94 as its default rather than a constant.

Batch throughput scales to **~247 output fps aggregate with 4 concurrent workers** — a 2 h film in
about 29 minutes at 1080p. (That is the Phase-0 figure for four concurrent *processes*. The
shipped converter uses four interpolating *sessions inside one job* instead, which is the same
idea without the four sets of buffers — §26.)

## The app — built

**60FPS.app** is a native frame-interpolation player and batch converter for Apple Silicon. It
plays a film at 59.94 with its own soundtrack, computing the picture as it goes, and it converts
films in a queue. Both are the same engine with two schedulers.

```bash
swift build --disable-sandbox          # the library, the harness and the app
swift test  --disable-sandbox          # 452 tests in 37 suites, zero warnings

scripts/bundle.sh                      # build 60FPS.app (ad-hoc signed)
scripts/bundle.sh --dmg                # ... and 60FPS-1.0.0.dmg
open build/60FPS.app --args film.mkv   # or just drag a film onto it
```

Needs **macOS 15.4** and **ffmpeg** on `PATH` (Homebrew's `/opt/homebrew/bin` is probed
directly, so a Finder launch works without a shell). MIT licensed.

| | |
| --- | --- |
| Playback | **Real time — including on a 4K film.** The default is **Automatic**: the player measures the real pipeline at each width and takes the widest that fits (**1920×816** on a 4K film), then watches its own presented rate and narrows one rung if the prediction was wrong. Verified in the installed app on the real film: **0.998 ± 0.003× real time**, `59.5–59.9 fps of 59.94 presented`, `1920×816 · measured`, **5 of 153,721 intervals skipped (0%)**. **Full 4K is one click away, and it does play at native resolution while interpolating** — measured on the real film: `3840×1632`, **18.2 fps presented, 233 intervals skipped**, still real time at 0.95× with no growing lag. Native resolution *and* real time, yes; native resolution *and* 59.94, no — the engine needs **84.15 ms** per interval against a **41.71 ms** budget. (§33) |
| Transport | `←` / `→` step back 5 s and forward 10 s; `⌘←` / `⌘→` from the Playback menu, `space` plays and pauses. The bare arrows are a local key monitor rather than menu key equivalents, so they still reach a focused text field. Measured in the app, paused: **+10.00 / +10.00 / −5.00 / −5.00 s**. |
| Sound | The soundtrack is the clock. MP4 + AAC by default, or MKV + a bit-for-bit copy of a real track off the disc. |
| HDR | 10-bit P010 end to end, disc metadata carried through, tone-mapped by the system compositor. |
| Batch | **4 interpolating sessions per job** (§26) — measured 1.78× on the interpolator and 1.63× end to end, four separate runs at 55.7 s. Segments with resume, both containers, audio muxed once over the joined picture. |
| Queue | **Convert is the first tab, and the app opens on it** — the queue is the reason the app exists; the player is for checking the result. Each job shows an **accurate time remaining**, from a sliding window over the render rate rather than `elapsed ÷ fraction` (which was wrong inside every piece and only moved at piece boundaries). Verified on the real film: projected **196 s** against a true **198.8 s** at 20.6% done, and **6 s** against **5.4 s** at 97.9%. |
| Output rate | 59.94 (`OutputRatePolicy.standard`); `exactSixty` overrides. A policy is a *value*, so batch and playback cannot disagree. |

The whole record — every measured trap with its numbers — is
[`reports/BUILD-DECISIONS.md`](reports/BUILD-DECISIONS.md) §§0–36 and invariants 1–78.

## Read this first

**→ [`reports/BUILD-DECISIONS.md`](reports/BUILD-DECISIONS.md)** ⭐ **latest — §§0–36**
The index, and the one to read before touching the pipeline. The 14 decisions with measured
effects and your recorded choices; **§§13–36 are what was built**; and **invariants 1–78** are
every measured failure mode, each with the numbers that produced it. If you read one thing,
read the invariants — they are the difference between a build that works and a build that looks
like it works. §30 covers doing what SVP does: the resize lever, the calibration that holds real
time, and the two conversion methods. §31 is why that calibration was still not enough, and the
rate watchdog that fixed it — including the verification in the installed app on the real film.
§25 covers the shell: the four bugs that only running it could find, the bundle, the signing, and
what the first launch actually does.

**→ [`reports/ENGINE-EQUIVALENCE.md`](reports/ENGINE-EQUIVALENCE.md)**
**The RIFE tier question is closed.** VTFrameProcessor and CoreML RIFE 4.25 are statistically
indistinguishable on real 4K HDR film — 465 of 475 frames within 2/255, and on a ground-truth holdout
(delete every odd frame, re-create it at t=0.5, score) they differ by 0.105 MAE with |t| = 1.06, while
RIFE costs **4.06×** the time. Also documents the range bug that made the first pass wrong by 96%.

**→ [`reports/REAL-CONTENT-AB.md`](reports/REAL-CONTENT-AB.md)**
Real 4K HDR film from your own disc, both engines, one 8-second clip. Contains the measured cost of
the 4K decision (48% dropped frames in playback; 2.4–3.7× in batch), the exact-rational frame-rate
bug that was silently costing 20% of throughput, and the scene-change finding that adds a mandatory
Phase 1 deliverable. Artifacts: `~/Desktop/FNF-60FPS-A-B/`.

**→ [`reports/PHASE0-COREML-RIFE.md`](reports/PHASE0-COREML-RIFE.md)**
Phase 0 executed: RIFE 4.25 converted to CoreML (all 18 warps → `resample`, 68 dB PSNR), then
benchmarked. **Convertibility solved; real-time disproved** — 25.9 calls/s at 1080p against
47.9–59.8 needed. Includes the `.all`-is-8×-slower trap and three corrections to earlier reports.

**→ [`reports/PLAYBACK-AND-BATCH.md`](reports/PLAYBACK-AND-BATCH.md)**
Playback + batch in one app, film-rate sources to 60 fps, the pipelining finding that lifts
throughput 35%, 60.000 vs 59.94 target rates, concurrency scaling, recommended architecture, risks.
**§12 is the same questions answered by the thing that now ships.**

**→ [`reports/WHY-NOT-RIFE.md`](reports/WHY-NOT-RIFE.md)**
Why RIFE isn't the primary engine even though it's MIT and already arm64 — measured head-to-head
against `VTFrameProcessor`, plus the Vulkan/MoltenVK/VapourSynth deployment problem and the GPL-2.0
issue with MVTools.

**→ [`reports/FEASIBILITY-AND-STACK.md`](reports/FEASIBILITY-AND-STACK.md)**
Full analysis: what REA is, what it found in the bundle, the complete architecture matrix,
the legal position, the recommended stack, measured performance, and risks.

**→ [`reports/60FPS-OUTPUT.md`](reports/60FPS-OUTPUT.md)**
60 fps-only output: which source rates are easy, which are hard, measured throughput per
conversion, and the API resolution ceilings. *Partly superseded — see the correction banner.*

## Key findings at a glance

- **77 of 87** Mach-O binaries in SVP 4 Mac are already universal (x86_64 + arm64).
- Only **9** files are Intel-only, and they are the GUI, four optional extensions, and three
  third-party utilities — not the interpolation engine.
- `libsvpflow1/2` (the core engine) and `libRIFE` (neural interpolation) **already ship arm64
  slices**. SVP's build system carries a distinct `libsvpflow2_arm.1.dylib` target.
- **SVP 4 Mac does not use MVTools at all.** Its motion engine is its own `libsvpflow1/2`; MVTools
  belongs to SVP's Windows/AviSynth setups and is GPL-2.0, which blocks App Store distribution.
- SVP's licence forbids reverse engineering. The legitimate path is clean-room, on published
  algorithms plus MIT/GPL upstreams and Apple's public APIs.
- **Keeping two requests in flight lifts throughput 35%** — a single lock-step
  `VTFrameProcessor` session leaves a third of the hardware idle. This is the difference between
  23.976 → 60 passing (77 fps) and failing (57 fps).
- **Pre-computed optical flow is 14% *slower* than the default** — measured, and it contradicts
  the earlier recommendation in `60FPS-OUTPUT.md`.
- **For NTSC-family sources, targeting 59.94 instead of 60.000 is much cheaper** — 29.97 → 59.94
  runs at 139 fps via the low-latency path versus 65.7 fps for 29.97 → 60.000.
- **RIFE (ncnn + Vulkan/MoltenVK) runs at 0.47× real-time** at 1080p and peaks at 42 fps aggregate
  against `VTFrameProcessor`'s 247 fps — a **5.9× deficit** — and it needs VapourSynth plus a
  Homebrew Vulkan loader to run at all. RIFE is a *quality* option, not a performance one.
- Four sharp edges in `VTFrameProcessor` were reproduced and documented: the Swift `async`
  `process()` silently does no work; per-frame buffer allocation causes crashes; the low-latency
  path **silently** fails above 1920×1080 while `startSession` still reports success; and the
  `frameSupportedPixelFormats` property misreports which formats actually work.
- **RIFE converts to CoreML completely** — all 18 `grid_sample` warps become `resample`, zero
  leftovers, and the result is **68.0 dB PSNR** against PyTorch fp32. fp16 is *not* a quality
  problem, contrary to the MLX port's warning.
- **But CoreML RIFE is not real-time at 1080p**: 25.9 calls/s against the 47.9–59.8 required. RIFE
  is GPU-compute-bound at a hard **~50 Mpx/s** ceiling, so the quality tier is **batch-only**.
- **`.all` compute units — the CoreML default — is 8× slower than `.cpuAndGPU`** (307 ms vs 39 ms)
  for this graph. The ANE is worse still: 30× slower than the GPU.
- **RIFE needs frame dimensions divisible by 64**, not 16: `IFBlock.conv0` runs two stride-2 convs
  at scale=16, so 544 silently restores to 576 and the warp breaks.
- **One `VTFrameProcessor` session cannot be hurried; several overlap.** Requests in flight is
  inert — at 4K, depths 2, 4 and 8 all give 13.4–13.5 source frames/s. Separate sessions do
  overlap: 1 → 13.4/s, 2 → 21.5, 4 → **23.8 (1.78×)**, 6 → **17.0 — slower than four.** The
  optimum is a knee, not a core count, which is what `RenderWorkers` encodes.
- **`SubmissionMode` is a statement of fact, not a hint.** The SDK defines `.sequential` as
  "without jump or skip" and acts on it by keeping internal caches. The first pool told four
  strided sessions `.sequential` and produced **894 of 1198 frames below 40 dB** (mean 36 dB)
  against a **58.2 dB control** for two runs of the identical configuration.
- **The pipeline is never sequential, pool or no pool.** `if wanted, !resolved.isEmpty` skips
  the interval a scene cut forces — all its frames are passthroughs — so the session's next
  submission is a jump. Saying otherwise cost **two frames of plain cross-fade after every cut**
  in the shipped code, since before the pool existed. Found only by comparing two *encoded*
  conversions of the same film; no test had ever done that.
- **In the app, that is 1.2 of 12 cores → 2.4, and half the GPU → 72%.** 55.7 s against 91.0 s
  for the same 50 s of real 4K HDR film, reproducible to the tenth across four runs.
- **A TCC permission check *is* the question.** There is no API to read macOS's answer: the
  attempt is the query and the query is the prompt. It prompts one folder at a time, it remembers
  one answer per app, and once the answer is no it never asks again — a second attempt fails
  immediately and silently, which is why a refused film gives no error at all.
- **The conversion is GPU-bound, and the CPU headroom is not usable.** At 4K on the real film the
  driver's own serial work is **21.6 s of a 51.6 s run** — and it is *hidden*, because the engine pool
  occupies the whole 51.6 s. The CPU sits at **21% of the machine** because the work is per-pixel and
  on the GPU; deleting every CPU stage would not save a second.
- **Four sessions is the framework's ceiling, and a ceiling rather than a bubble.** 1/2/4/6 sessions →
  **12.3 / 20.2 / 23.3 / 21.8** source frames/s, with GPU device utilisation *flat* at ~72% (75 of 97
  samples in the 70–79% band) — no duty-cycling to fill. Six sessions *lower* the GPU's utilisation.
  And **two conversions in two processes at four sessions each measure 16.0 fps together against 23.3
  for one alone** — the number behind the queue's "one at a time, deliberately".
- **The scheduling policy macOS applies to the process is worth 3.5×, and nothing inside the process
  can see it.** The identical conversion, build and machine: **51.6 s** at default policy against
  **180.5 s** under background policy, with the driver's own work collapsing (read 10.2 → 75.7 s,
  sign 7.7 → 45.1 s) because those threads are demoted off the performance cores. A `.utility` tier
  alone costs ~4%, so the cliff is the background demotion — the state a conversion is in overnight
  behind a locked screen. The player has held `beginActivity` since invariant 41; the converter held
  none and now holds one. It is **protection, not speed**: neutral at default policy (51.6 s against
  51.6 s), and it does not override a *forced* background policy — `taskpolicy -b` with the assertion
  still takes 273.5 s, because that forces the background I/O tier instead. It moves no pixels
  either: **56.43 dB** against a **56.41 dB** two-identical-runs control.
- **SVP plays this film at 60 fps because it matches motion 185× more coarsely — not because it
  resizes.** SVP's own log shows it interpolates at **3384×1440** after scaling, but that exact
  resolution still costs **81.55 ms per interval** here against the film's **41.7 ms** budget —
  1.96× too slow, so the resize does not explain its speed. Its profile says `mv_grid: 12,
  mv_refine: 0`: motion on a **12-pixel block grid, ~33,840 vectors per frame**.
  `VTFrameProcessor` computes **dense per-pixel optical flow — 6,266,880 vectors per frame, 185× as
  many** — and the API exposes no cheaper model. SVP is also permitted to lower quality to hold the
  rate (`fi_auto_adjust`); this engine is not. Not a tuning problem, and not fixable from inside the
  app. (§29) — but read §30 before concluding the resize is worthless: it is worth **22%** of the
  gap, and 22% is exactly the margin this machine needed.
- **And it is not the decode, and it is not the pipe.** The obvious alternative story — "the frames
  cross a pipe to the CPU, so of course 4K is slow" — is measurably wrong. 600 frames of the real 4K
  HDR film: **decode alone 2.67 ms/frame** (375 fps, hardware), **decode plus the rawvideo pipe
  4.62 ms/frame** (217 fps), **interpolation at 3840×1632 84.15 ms**. The plumbing is **11%** of the
  film's 41.71 ms interval and the engine is **89%**. A pipe optimisation can buy at most 11% of a 2×
  miss, so it cannot be the fix. (§34, invariant 68) And there is no Apple API to reach for: re-checked
  on macOS 27.0.1, the low-latency path still **stops dead at 1920×1080** — 1280×720 works at 7.99 ms
  and 1920×1080 at 22.24 ms, while 2048×1080 upward fails *silently* with `-19730`. (invariant 69)
- **Playback now does what SVP does, as behaviour: measure the film, then interpolate at the widest
  width that holds real time.** The default changed from "true 4K, accept the drops" to
  **Automatic**, which probes the real pipeline at each width rung widest-first and takes the first
  that fits. On the real 4K film: **3840 → 80.85 ms/interval (0.52× real time), 2560 → 80.18
  (0.52×), 1920 → 33.30 (1.25× — 75.1 output fps against the 59.94 needed)**. It settles on
  **1920×816 in ~7 s**, once per film, and the readout names the size. Full 4K is still one click
  away. (§30, invariants 51, 53, 54) **What that measurement could not tell it is §31.**
- **The prediction was still wrong, so the player now watches its own output.** §30's calibration is
  a measurement taken *before* the thing it predicts exists, and it drives the real engine into a
  **sink that discards frames** — so it never runs the queue, the presenter or the display, and
  everything the player does that is not interpolation is missing from the number that decides how
  much interpolation it may be given. At 1920 the engine alone costs **31.74 ms/interval** against a
  **41.71 ms** budget (24% spare) while the whole player presents **59.4 fps of 59.94** — the
  non-engine half spends the entire spare. No margin constant repairs that, because the cost it must
  cover depends on the window, the display and the machine's load. So `.automatic` closes the loop:
  sample the **presented** rate every 1.5 s, and on two consecutive samples below 97% of target,
  narrow one rung of the ladder and rebuild at the same instant of film. Verified on the real film
  with the display's cost simulated at 22 ms per frame: **34 fps at 1920 → narrowed to 960×408
  within 3 s → 60.0 fps for the remaining 37 s**; with the cost removed it never fires, and the
  picture stays at 1920. **In the installed app on the real film the loop never fires at all** — the
  size stayed at `1920×816 · measured` while the position advanced **0.998 ± 0.003×** the wall clock's
  rate over 33 s. (§31, invariants 56–58)
- **The native-resolution question has a measured answer, and it is a trade rather than a limit.** On the
  real film, same build, same start point: **Automatic → `1920×816`, 1166 frames shown, 0 intervals
  skipped, 56.4 fps of 59.94, lag 16 ms**; **Full → `3840×1632`, 384 frames shown, 233 intervals
  skipped, 18.2 fps, lag 113 ms** — both real time, neither lag growing. So "play it in native
  resolution while interpolating" is already exactly what Full does; what no setting can do is native
  resolution *and* 59.94, because the engine costs **84.15 ms** per interval against a **41.71 ms**
  budget. The readout offers both as a one-click picker. (§33)
- **And the answer to "why can SVP play 4K" is now a setting, not an explanation.** §34 split a 4K
  interval into **decode 2.67 ms, decode+pipe 4.62 ms, interpolation 84.15 ms** against a 41.71 ms
  budget — 11% plumbing, 89% engine — so the plumbing was never the fix. §35 builds SVP's *other*
  lever: the delivered size and the interpolation size are now **two separate settings**. A conversion
  can interpolate at 1920 wide (**37.05 ms**/interval) and deliver **3440×1440**, because the upscale is
  `VTPixelTransferSession`'s at **2.71 ms**/frame — 4–5% of the interpolation it sits behind. Measured
  on the real 4K HDR film: `plain 1920×816`, `fit 3440×1440`, `fill 3440×1440`, with the picture starting
  at **x = 26** — exactly the bar width the geometry predicts, and a jump from 868 to 19066. In the
  installed app the player's readout states what the mode is doing to *this* picture in *this* window,
  computed from the layer's own bounds: **`fit · 500 high picture, 47 px bars top and bottom`** and
  **`fill · 1398 wide picture, 109 px cropped each side`**, both matching the geometry exactly, with the
  picture measured to confirm it. The settings screen lists connected displays by name and native size —
  **"LG ULTRAGEAR — 3440 × 1440"** — which is `CGDisplayPixelsWide/High` and *not* the largest mode the
  display accepts (that is 3840×2160, a scaled mode, and using it would over-report by 38%). (§35,
  invariants 70–75)
- **And "would the Apple Media Engine make conversions smaller?" now has a measured answer: no.** §36 ran
  the shipping converter with the decoder forced onto the CPU — seven interleaved repetitions, 1200 frames
  of the real film — and got **51.89 s with `-hwaccel videotoolbox` against 51.89 s without**: zero, to the
  resolution of the measurement. The software decoder's extra 0.29 s of `read` is cancelled by 0.33 s less
  `slotWait`. The media engine is already doing all the codec work there is (decode, and the HEVC encode),
  and the one stage it cannot touch — interpolation — is the 89%. At 1080p it is a different regime and the
  same A/B costs **+18%**, because the driver's own serial work is 83% of the wall there and there is no
  pool slack left to absorb the decoder. The lever that moves conversion time is the width ladder, and it
  moves it by **2.3×**. (§36, invariants 76–78)
- **`Process.terminate()` does not end a child that is blocked writing into a full pipe — and a frame is
  bigger than a pipe.** **12,582,912 bytes** against **64 KB** means ffmpeg is *always* mid-write when a
  reader stops, so SIGTERM, SIGTERM twice, and SIGTERM with **764 MB drained past it** all left it alive
  indefinitely while `close()` waited in `waitUntilExit()`. That was the app hanging on a resolution
  change, and it is why the calibration probe — which reads a few frames and stops — wedged it every
  time. SIGKILL ends it in **13–23 ms**. The handler was never the problem: an ffmpeg with no output pipe
  at all dies on SIGTERM in **43 ms, exit 255**. (§33, invariants 64–65)
- **A rate verified on a short clip is not verified, and 99% is not a pass.** The previous claim that
  playback held real time came from a run on a short `/tmp` clip presenting **59.6 fps of 59.94 —
  99.4%**, and the next thing heard from the user was *"still not being able to play it in real time."*
  The user was right. A short clip has no time to fall behind — startup, a seek or a warm cache covers
  the whole of it — and a number at the edge of the target reads as success until the deficit has room
  to accumulate. The verification is now on the **real film** (6411 s, 153,721 intervals), for minutes
  rather than seconds, and it treats a rate below target as a failure with a cause. (invariant 58)
- **Four calibration defects and one settings bug, all silent — three of which looked like
  properties of the film.** (a) An **8-interval probe is noise**, one-sided and >30% run to run, so it
  under-reports what the machine can afford; it is now 20 intervals. (b) Probing the whole ladder at
  five positions gives **three cost treads, not six** — 1920, 1600 and 1280 *all* cost ~33–37 ms — so
  the ladder's extra rungs wasted the probe budget and never reached 960. (c) The fallback **guessed**
  at the narrowest rung instead of taking the fastest *measured* one. (d) The 0.85 margin was sized
  from a 4K gap that §25 had already shown was not there ("two instruments, one number"). Together
  these made a 4K film fall back to **960×408**. (e) Adding a required `Codable` field to
  `AppSettings` made every stored setting **silently reset on upgrade** — volume, speed, output
  folder, worker count and the rest. (invariants 53, 54, 55)
- **Conversion offers both methods: Quality (source resolution) and Fast (1080p), 3.8× apart.**
  Measured end to end on the real film, 288 source frames: **Quality 12.4 s / 23.2 source frames/s
  (2.1 h for a 2 h film)** against **Fast 3.2 s / 88.8 source frames/s (0.5 h)** — better than the
  3.3× the interpolation cost alone predicts, because the 1080p encode is cheaper too. Both outputs
  verified 60000/1001, 718 frames, 10-bit, with **`smpte2084`/`bt2020` intact**, so the HDR
  description survives the new scale path. Quality stays the default. (§30)
- **ffmpeg's `minterpolate` is not a fast path at any resolution.** It is a genuine block matcher
  (MVTools lineage), which is why it was worth measuring: **2.09 s per interval at 4K, 511 ms at
  1920×816** — **16× slower** than this engine's 31.87 ms at the same size, 20× at 4K — and
  single-threaded scalar C, so `-threads 8` barely moves it. The VideoToolbox headers contain no
  `MotionEstimation` symbol, so there is no hardware estimator either. (invariant 52)
- **Cost is a step function of frame *width*, not of pixel count.** **2560×816 and 1920×1088 are both
  2,088,960 px and cost 78.53 against 40.73 ms — 1.93×.** The table is not even monotonic in pixels
  (2048×870 beats 1984×844), and 1920 → 1984 is **+3.3% width for +28% cost**, because the engine
  partitions its work along width. Only the 1920-wide resolutions meet the 41.7 ms budget; 3840 wide
  is ~2.5× over. That is the whole case for the one-click 1080p path, now measured at **80.2 fps**.
  (invariant 49)
- **The player was decoding in software.** Plain ffmpeg against `-hwaccel videotoolbox`, 600 frames
  of the real 4K HEVC 10-bit film to raw P010: **4.40 s / 939% CPU against 1.53 s / 98% CPU — 2.9×
  and nine cores back, bit-identical** (same MD5 both ways). ffmpeg falls back by itself for codecs
  the decoder cannot take, so no fallback logic is needed. It does **not** speed up conversion —
  wall stayed 53.7 → 53.5 s because `slotWait` grew to absorb it — which is §28's pool ceiling
  stated from the other side. (invariant 50)

## Layout

```
60FPSVideo/
├── Sources/
│   ├── Interpolator/                 the library: engine, pipeline, player, batch, audio
│   ├── InterpolatorApp/              the SwiftUI shell (player, queue, settings, about)
│   └── interp-harness/               headless measurement harness (--play, --convert,
│                                     --calibrate, --measure-widths, …)
├── Tests/InterpolatorTests/          451 tests in 37 suites
├── packaging/Info.plist              the bundle's plist, read before the process exists
├── scripts/
│   ├── bundle.sh                     assemble 60FPS.app, sign it ad-hoc, write the .dmg
│   └── make-icon.py                  draw the icon from code
├── reports/
│   ├── BUILD-DECISIONS.md            §§0–35, invariants 1–75 — read before touching the pipeline
│   ├── ENGINE-EQUIVALENCE.md         RIFE vs VTFrameProcessor, closed
│   ├── REAL-CONTENT-AB.md            real 4K HDR film, both engines
│   ├── PLAYBACK-AND-BATCH.md         feasibility + §12, what was actually built
│   ├── PHASE0-COREML-RIFE.md         CoreML conversion + speed spike
│   ├── WHY-NOT-RIFE.md               RIFE/MVTools measured vs VTFrameProcessor
│   ├── 60FPS-OUTPUT.md               60 fps-only output, per-rate ceilings   (partly superseded)
│   └── FEASIBILITY-AND-STACK.md      architecture, legal position, stack
├── analysis/
│   ├── arch-matrix.tsv               87 Mach-O binaries + architecture slices
│   ├── rea/                          REA evidence bundles
│   ├── benchmarks/                   throughput data, method, stability findings
│   ├── probes/                       Swift benchmark / probe source
│   │   └── rife/                     RIFE benchmark (Python + VapourSynth, ncnn)
│   └── coreml/                       RIFE → CoreML conversion + benchmark
│       ├── convert_rife.py           converter (constant-grid, timestep-as-input)
│       ├── bench_coreml.py           speed harness
│       ├── parity_check.py           CoreML vs PyTorch correctness
│       ├── build/                    8 converted .mlpackage models
│       └── results/                  raw Phase 0 measurements
└── docs/
```

## Environment used

Mac14,6 — Apple M2 Max (38-core GPU, 64 GB), macOS 27.0.1 (26A434), Xcode 27.1 / Swift 6.4.

**A note on measurement.** This machine carries other load, and `VTFrameProcessor` clocks shift
between runs. Absolute figures move a few percent; depth-1/depth-2 comparisons were therefore run
*interleaved* so drift affects both arms equally. Treat ratios as solid and absolute values as
±5%.
