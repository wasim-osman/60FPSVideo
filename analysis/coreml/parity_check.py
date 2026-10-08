#!/usr/bin/env python3
"""
Does the CoreML model still produce RIFE's output?

Conversion success is not correctness. This runs the same inputs through the
original PyTorch IFNet and through the converted CoreML model and compares.

The PyTorch side uses the *unmodified* upstream code path (`model.warplayer.warp`
with its runtime linspace grid, float timestep, default scale_list), so a match
here also validates the constant-grid rewrite and the timestep-as-tensor change.
"""

import argparse
import os
import sys

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "Practical-RIFE"))


def psnr(a, b, peak=1.0):
    mse = float(np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2))
    if mse == 0:
        return float("inf")
    return 10.0 * np.log10(peak * peak / mse)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--model-dir", default=os.path.join(HERE, "models", "rife425"))
    ap.add_argument("--height", type=int, default=576)
    ap.add_argument("--width", type=int, default=960)
    ap.add_argument("--timestep", type=float, default=0.5)
    args = ap.parse_args()

    import coremltools as ct

    sys.path.insert(0, os.path.abspath(args.model_dir))
    from train_log.IFNet_HDv3 import IFNet

    h, w = args.height, args.width
    torch.manual_seed(1234)

    # Deterministic, structured inputs: random noise is unrealistically hard for
    # a flow network, so use smooth gradients plus a moving block - closer to
    # real footage and a fairer test.
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    base = np.stack([xx / w, yy / h, (xx + yy) / (w + h)], 0)[None]
    blk = np.zeros((1, 3, h, w), np.float32)
    blk[:, :, h // 4: h // 2, w // 4: w // 2] = 1.0
    img0 = np.clip(base + blk, 0, 1).astype(np.float32)
    blk2 = np.zeros((1, 3, h, w), np.float32)
    blk2[:, :, h // 4: h // 2, w // 4 + 23: w // 2 + 23] = 1.0
    img1 = np.clip(base + blk2, 0, 1).astype(np.float32)

    # --- PyTorch reference: the untouched upstream path ---
    ref = IFNet().eval()
    sd = torch.load(os.path.join(args.model_dir, "train_log", "flownet.pkl"),
                    map_location="cpu", weights_only=True)
    if all(k.startswith("module.") for k in sd):
        sd = {k[len("module."):]: v for k, v in sd.items()}
    ref.load_state_dict(sd, strict=False)
    with torch.no_grad():
        t0 = torch.from_numpy(img0)
        t1 = torch.from_numpy(img1)
        torch_out = ref(torch.cat((t0, t1), 1), args.timestep, [16, 8, 4, 2, 1])[2][-1]
        torch_out = torch_out.numpy()

    # --- CoreML ---
    model = ct.models.MLModel(args.model, compute_units=ct.ComputeUnit.CPU_AND_GPU)
    cm_out = model.predict({
        "img0": img0,
        "img1": img1,
        "timestep": np.full((1, 1, 1, 1), args.timestep, np.float32),
    })["frame"]

    d = np.abs(torch_out - cm_out)
    print(f"model        : {os.path.basename(args.model)}")
    print(f"size         : {w}x{h}  t={args.timestep}")
    print(f"max abs diff : {d.max():.6f}   ({d.max()*255:.2f}/255)")
    print(f"mean abs diff: {d.mean():.6f}   ({d.mean()*255:.3f}/255)")
    print(f"PSNR         : {psnr(torch_out, cm_out):.2f} dB")
    print(f"p99.9 diff   : {np.percentile(d, 99.9):.6f}")
    print(f"range torch  : [{torch_out.min():.4f}, {torch_out.max():.4f}]")
    print(f"range coreml : [{cm_out.min():.4f}, {cm_out.max():.4f}]")

    verdict = "PASS" if psnr(torch_out, cm_out) > 40 else "REVIEW"
    print(f"verdict      : {verdict} (threshold 40 dB)")


if __name__ == "__main__":
    main()
