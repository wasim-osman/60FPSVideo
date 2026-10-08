# The two engines are the same picture

You watched `FNF_60FPS_COMPARE.mp4` and said *"they look identical to me."*

**You are right, and it is measurable.** VTFrameProcessor and CoreML RIFE 4.25 agree
to within **3/255** on 463 of the 475 output frames. The remaining 12 are the scene
cuts, where both engines fail in the same way for the same reason.

This closes the last open question in `WHY-NOT-RIFE.md` §9. That report recommended
keeping RIFE as an optional CoreML quality tier on the grounds that *"RIFE's value is
quality, not speed."* It was the right call to make before measuring. It is not
supported by the measurement.

---

## 1. First, a correction to my own instrument

The first pass said the engines differed by **MAE 12.9/255** on every frame — which
would have been a big deal. It was wrong, and the way it was wrong is worth recording
because it very nearly became a product decision.

The tell was frame **k=0**. That is a *passthrough* frame: 23.976 → 59.94 is exactly
2.5×, so every fifth output frame lands precisely on a source frame and needs no
interpolation at all. Both engines should emit source frame 0 verbatim, so the
difference there must be ~0. It measured 12.9.

Fitting one against the other:

```
luma_rife = 1.16485 × y_vt − 19.170
```

A pure limited→full-range conversion is `1.16438 × y − 18.628`. **The fit is the range
conversion.** VT writes NV12, whose Y plane is studio range (16..235); RIFE writes
rgb24, which ffmpeg expands to full range (0..255). Comparing the two raw invents a
~16/255 offset on every pixel — and this film is *dark*, so most pixels sit near black
where the offset is proportionally largest.

After normalising: **12.928 → 0.516.** 96% of the apparent difference was the
instrument.

| | as measured | range-corrected |
|---|---|---|
| k=0 (passthrough) | 12.928 | **0.516** |
| k=1 (interpolated) | 12.920 | **0.682** |
| k=254 (worst frame, a cut) | 30.149 | 21.332 |

The delivered `FNF_60FPS_VT.mp4` / `FNF_60FPS_RIFE.mp4` were **not** affected — both
were encoded through the same swscale path, and their k=0 luma means agree to 0.01
(58.92 vs 58.93). The error was only ever in my analysis, never in what you watched.

---

## 2. Engine vs engine, range-corrected

475 output frames = 380 interpolated + 95 passthrough.

| | MAE mean | MAE median | MAE p95 | MAE max |
|---|---|---|---|---|
| all frames | 1.294 | 0.979 | 1.628 | 22.460 |
| **interpolated** (n=380) | **1.524** | **1.072** | 1.681 | 22.460 |
| **passthrough** (n=95) | **0.377** | **0.373** | 0.412 | 0.516 |

Whole-clip PSNR: **34.01 dB**.

The passthrough figure of 0.377 is not an image difference — it is 8-bit studio-range
quantisation. VT stores luma in 219 levels, RIFE in 256; the round trip costs ~0.4/255
and nothing else. RIFE's passthrough frames are byte-exact copies of their input
(verified: MAE 0.0000 against the decimated source).

On a typical interpolated frame the two engines differ by **one least-significant
bit**. That is the same picture.

### Where they differ

Twelve frames exceed **3/255** — 3× the typical interpolated value — and they fall into
five tight groups:

| output frames | source frame(s) | peak MAE | local source motion |
|---|---|---|---|
| 16–17 | 6 | 22.46 | **66.46** |
| 173–174 | 69 | 20.42 | **63.22** |
| 253–254 | 101 | 21.33 | **58.34** |
| 268–272 | 107–108 | 15.95 | **40.08** |
| 421–422 | 168 | 17.62 | **36.52** |

Source-motion p95 across the clip is 14.08. Every one of these five sits at 2.6–4.7×
that. **They are the five scene cuts.** The engines do not disagree about
interpolation; they disagree about which shot they are interpolating.

The largest disagreement *anywhere else in the clip* is **1.777/255** (frame 71).
Excluding the 13 cut-adjacent frames entirely, the median difference is **0.964** and
the 95th percentile is **1.554** — nothing exceeds two least-significant bits.

---

## 3. Ground truth: who is actually right?

Agreement is not correctness. Two engines can agree perfectly and both be wrong. So I
built a test where the answer is known.

**Holdout:** delete every odd source frame. You now have a source at exactly half the
rate. Ask each engine to double it back up — the interpolated frames land at **t=0.5
exactly**, which is precisely where the deleted frames used to be. Compare against the
real frames.

95 held-out frames, 4K, same content. Two naive baselines for context:

| | MAE mean | MAE median | PSNR mean |
|---|---|---|---|
| repeat previous frame | 8.628 | 7.692 | 24.12 |
| 50/50 linear blend | 6.686 | 5.894 | 26.74 |
| **VTFrameProcessor** | 4.237 | **2.572** | 32.17 |
| **CoreML RIFE 4.25** | **4.132** | 2.581 | **32.25** |

Excluding the five cut frames:

| | MAE mean | MAE median | PSNR mean |
|---|---|---|---|
| repeat previous frame | 7.316 | 7.269 | 24.61 |
| 50/50 linear blend | 5.531 | 5.635 | 27.33 |
| **VTFrameProcessor** | 2.654 | 2.549 | 33.18 |
| **CoreML RIFE 4.25** | **2.607** | **2.457** | **33.28** |

Head to head over the 95 frames:

- VT wins 28, RIFE wins 67, 22 within 0.05 MAE
- mean(VT − RIFE) = **+0.105 MAE**, std 0.965
- paired statistic **|t| = 1.06** — not significant (needs ≈2.0)

**Both engines are real interpolators.** They beat a plain 50/50 blend by **5.7 dB**,
which is the difference between "motion-compensated" and "cross-fade" and is exactly
why this project is worth building. The two of them, however, are **within noise of
each other**: a 2.5% difference in mean error, in the wrong direction on median.

RIFE's edge, such as it is, is **0.105 MAE out of 2.6**. It is invisible.

---

## 4. Visual proof

`out/ENGINE-EQUIVALENCE.png` — panel A is per-frame MAE across the clip (a flat line
at ~1/255 with five spikes); panel B is the holdout result.

`out/FNF_60FPS_CUTS.mp4` — the twelve cut frames at quarter speed, three rows: VT, RIFE,
and `|difference| ×4`. The diff row is **3–7/255 on ordinary frames and 47–74/255 at
the cuts** — a 10–15× contrast. It reads as black with five flares.

`out/FNF_60FPS_DIFF.mp4` — the same difference over the whole clip.

> A note on gain. An earlier build of these used ×32, which made the 1/255 rounding
> difference visible as grey noise across every frame — visually implying the engines
> disagreed everywhere, the opposite of the truth. ×4 is the honest setting: it keeps a
> typical difference nearly black while letting a real one show.

---

## 5. What this does to the cost argument

| | VTFrameProcessor | CoreML RIFE 4.25 |
|---|---|---|
| 4K, 190 intervals | 15.2 s | 61.8 s |
| per interpolated frame | **40.1 ms** | **162.6 ms** |
| **penalty** | — | **4.06×** |
| 2-hour film at 4K | 3.8 h | 15.6 h |

The engines are the same picture, and one of them costs **four times** as much and
four times the electricity. There is no quality argument left to pay it with.

One asymmetry worth noting for the record: VT's cost is **per interval, not per output
frame**. In the 2.5× case one call produces two output frames (t=0.4 and t=0.8) for
80.2 ms; in the 2.0× holdout it produced one for 81.0 ms. RIFE pays per output frame
either way (162.6 and 186.7 ms). So VT's advantage *grows* with the interpolation
ratio — at 24→120 fps it would be roughly 8×, not 4×.

---

## 6. Recommendation

**Do not build the RIFE tier. Ship VTFrameProcessor alone.**

This reverses the conclusion of `WHY-NOT-RIFE.md` §9, and the reason is simply that
the premise got tested. That report said RIFE's value is quality — reasonable, and
untested. Now it is tested, on real 4K HDR film, against ground truth, and the quality
is the same.

Concretely:

- **Engine:** VTFrameProcessor, single tier. No CoreML, no model download, no second
  code path, no second set of failure modes.
- **The CoreML conversion work is not wasted.** `analysis/coreml/` stays in the tree as
  the instrument that proved this, and as the starting point if a future title shows a
  gap. Converting RIFE to CoreML was the only way to make this comparison possible —
  the Vulkan build is 5.9× slower and could not have been run at 4K in reasonable time.
- **Scene-change detection moves from "important" to "the whole ballgame."** It is now
  the *only* measured quality difference between the engines' outputs, and it is a
  difference between two flavours of wrong. Both engines must stop interpolating across
  a cut and pass the source frame through. That is Phase 1, and it is not optional.

### What would change this answer

One 8-second clip from one film is one data point. The result is decisive *for this
content*; it is not a universal law. RIFE's reputation is built on hard cases —
occlusion, large displacement, animation, film grain — and this clip is a dark,
mostly-translational shot. If a future title shows visible ghosting where VT struggles,
the comparison harness (`analysis/gt_holdout.py`) is the thing to re-run, and it takes
about four minutes.

That is a much better position than shipping a 4× tier on a hunch.

---

## Reproduce

```bash
cd /Users/Wasim/Documents/Projects/60FPSVideo

PY=/Users/Wasim/.workbuddy-ai/binaries/python/envs/coreml/bin/python

# 1. engine vs engine, range-corrected, per frame
$PY analysis/ab_diff.py --vt work/FNF_60FPS_vt.nv12 --rife work/FNF_60FPS_rife.rgb24 \
    --src work/FNF_60FPS.rgb24 --width 3840 --height 1632 --n-src 191 \
    --csv out/ab_diff.csv

# 2. why the first pass was wrong
$PY analysis/ab_range_probe.py --vt work/FNF_60FPS_vt.nv12 \
    --rife work/FNF_60FPS_rife.rgb24 --width 3840 --height 1632 --frames 0,254,1

# 3. ground truth: decimate, re-interpolate, score  (renders + scores, ~4 min)
$PY analysis/gt_holdout.py --src-rgb work/FNF_60FPS.rgb24 --src-nv12 work/FNF_60FPS.nv12 \
    --width 3840 --height 1632 --n-src 191

# 4. artifacts
$PY analysis/engine_equivalence_chart.py
$PY analysis/cut_montage.py
```

Raw output: `out/ab_diff.csv`, `out/gt_holdout.txt`.
