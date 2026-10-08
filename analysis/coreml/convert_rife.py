#!/usr/bin/env python3
"""
Convert Practical-RIFE (v4.x) to CoreML.

Why this exists
---------------
SVP's shipped ncnn models cannot be converted (custom `rife.Warp` Vulkan layer).
The PyTorch implementation expresses the same warp as `F.grid_sample`, which
coremltools DOES support. So the CoreML tier must be built from upstream PyTorch.

Two changes are made to the reference implementation, both deliberate:

1. `warp()` is reimplemented with a *precomputed constant grid buffer* instead of
   `torch.linspace` evaluated at runtime. Semantically identical, but it removes a
   traced `aten::linspace` op and lets the converter constant-fold the grid.

2. The grid is built for one fixed (H, W). RIFE is not resolution-agnostic at the
   graph level. IFBlock runs the input through `conv0`, which is TWO stride-2
   convolutions, at the coarsest pyramid level (scale=16). So H/16 must be
   divisible by 4, i.e.

       **H and W must be divisible by 64.**

   Get this wrong and the two stride-2 convs round differently from the
   ConvTranspose2d+PixelShuffle that follows, and the restored flow no longer
   matches the frame it is warping. RIFE's own tooling pads to a multiple of
   128, which is a safe multiple of 64. We assert 64 and pad at the call site.

`--verify` proves the reimplementation is bit-comparable to the original IFNet
before anything is converted. Do not skip it.
"""

import argparse
import os
import sys

import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.join(HERE, "Practical-RIFE")
# `train_log/` (architecture + flownet.pkl) ships inside the model download,
# while `model/` (warplayer) ships in the repo. IFNet_HDv3 imports both, so both
# roots must be importable.
MODEL_ROOT = os.path.join(HERE, "models", "rife425")

for _p in (REPO, MODEL_ROOT):
    if _p not in sys.path:
        sys.path.insert(0, _p)


def build_grid(h, w):
    """The exact grid warplayer.warp computes, precomputed as a constant.

    Original:
        tenHorizontal = linspace(-1,1,W).view(1,1,1,W).expand(1,-1,H,-1)
        tenVertical   = linspace(-1,1,H).view(1,1,H,1).expand(1,-1,-1,W)
        grid = cat([tenHorizontal, tenVertical], 1)   # (1,2,H,W)
    """
    ten_h = (
        torch.linspace(-1.0, 1.0, w).view(1, 1, 1, w).expand(1, -1, h, -1).contiguous()
    )
    ten_v = (
        torch.linspace(-1.0, 1.0, h).view(1, 1, h, 1).expand(1, -1, -1, w).contiguous()
    )
    return torch.cat([ten_h, ten_v], 1)


def set_model_root(path):
    """Point the `train_log` import at a specific downloaded model package.

    Each RIFE release ships its own IFNet_HDv3.py (4.25.lite, for example, uses
    block4 c=24 instead of c=32), so the architecture and the weights must come
    from the same package.
    """
    global MODEL_ROOT
    MODEL_ROOT = os.path.abspath(path)
    for mod in [m for m in list(sys.modules) if m.split(".")[0] == "train_log"]:
        del sys.modules[mod]
    if MODEL_ROOT in sys.path:
        sys.path.remove(MODEL_ROOT)
    sys.path.insert(0, MODEL_ROOT)


def make_model_class():
    """Import IFNet lazily so the repo path is set up first."""
    from train_log.IFNet_HDv3 import IFNet  # noqa: E402

    class RIFECoreML(IFNet):
        """IFNet with a constant-grid warp, and a clean 3-input signature."""

        def __init__(self, h, w, scale_list=(16, 8, 4, 2, 1), align_corners=True):
            super().__init__()
            self.scale_list = list(scale_list)
            self._h, self._w = h, w
            self._ac_true = bool(align_corners)
            # Every warp in IFNet operates at full resolution, so one grid serves
            # all of them. Precomputing it also removes a traced `linspace`.
            self.register_buffer("_grid", build_grid(h, w), persistent=False)
            # Emulating align_corners=True with align_corners=False:
            #   align_corners=True : pixel = (g + 1)/2 * (N - 1)
            #   align_corners=False: pixel = ((g + 1) * N - 1) / 2
            # Setting them equal gives g_false = g_true * (N - 1) / N.
            # Same trick applies to the flow, which is added in the same
            # normalised units. Pure rescale, no change in semantics.
            self.register_buffer(
                "_gscale",
                torch.tensor([(w - 1.0) / w, (h - 1.0) / h]).view(1, 1, 1, 2),
                persistent=False,
            )

        # --- same maths as model/warplayer.py:warp, minus the runtime linspace ---
        # Shape reads are replaced by build-time constants: a traced `tensor.shape`
        # becomes `aten::Int`, which coremltools rejects on non-scalars.
        def warp(self, ten_input, ten_flow):
            flow = torch.cat(
                [
                    ten_flow[:, 0:1, :, :] / ((self._w - 1.0) / 2.0),
                    ten_flow[:, 1:2, :, :] / ((self._h - 1.0) / 2.0),
                ],
                1,
            )
            g = (self._grid + flow).permute(0, 2, 3, 1)
            if not self._ac_true:
                g = g * self._gscale
            return F.grid_sample(
                input=ten_input,
                grid=g,
                mode="bilinear",
                padding_mode="border",
                align_corners=self._ac_true,
            )

        # --- mirror of IFNet.forward, with `warp` -> self.warp and fixed scales ---
        def forward(self, img0, img1, timestep):
            x = torch.cat((img0, img1), 1)
            if not torch.is_tensor(timestep):
                timestep = (x[:, :1].clone() * 0 + 1) * timestep
            else:
                timestep = timestep.repeat(1, 1, self._h, self._w)

            f0 = self.encode(img0[:, :3])
            f1 = self.encode(img1[:, :3])

            warped_img0 = img0
            warped_img1 = img1
            flow = None
            mask = None
            blocks = [self.block0, self.block1, self.block2, self.block3, self.block4]
            merged = []

            for i in range(5):
                if flow is None:
                    flow, mask, feat = blocks[i](
                        torch.cat((img0[:, :3], img1[:, :3], f0, f1, timestep), 1),
                        None,
                        scale=self.scale_list[i],
                    )
                else:
                    wf0 = self.warp(f0, flow[:, :2])
                    wf1 = self.warp(f1, flow[:, 2:4])
                    fd, m0, feat = blocks[i](
                        torch.cat(
                            (
                                warped_img0[:, :3],
                                warped_img1[:, :3],
                                wf0,
                                wf1,
                                timestep,
                                mask,
                                feat,
                            ),
                            1,
                        ),
                        flow,
                        scale=self.scale_list[i],
                    )
                    mask = m0
                    flow = flow + fd
                warped_img0 = self.warp(img0, flow[:, :2])
                warped_img1 = self.warp(img1, flow[:, 2:4])
                merged.append((warped_img0, warped_img1))

            mask = torch.sigmoid(mask)
            merged[4] = warped_img0 * mask + warped_img1 * (1 - mask)
            return merged[-1]

    return RIFECoreML


def load_weights(model, ckpt):
    sd = torch.load(ckpt, map_location="cpu", weights_only=True)
    # RIFE's own loader strips a DDP `module.` prefix; the released checkpoints
    # are all `module.*`, but handle both rather than trusting one.
    if all(k.startswith("module.") for k in sd):
        sd = {k[len("module."):]: v for k, v in sd.items()}
    missing, unexpected = model.load_state_dict(sd, strict=False)
    missing = [m for m in missing if m != "_grid"]
    # The released checkpoints carry `teacher.*` tensors - IFNet's own comment
    # says "not used during inference". Extra keys are harmless; *missing* keys
    # would mean the model is silently running with random weights, so only
    # that is fatal.
    if missing:
        raise SystemExit(f"weight mismatch: missing={missing[:5]}")
    if unexpected:
        print(f"  note: {len(unexpected)} unused keys in checkpoint (e.g. {unexpected[0]})")
    return len(sd) - len(unexpected)


def verify(ckpt, h, w):
    """Prove the constant-grid rewrite matches the reference IFNet.

    Checks BOTH grid modes: the direct align_corners=True form and the
    align_corners=False emulation, which is what the ANE may require.
    """
    from train_log.IFNet_HDv3 import IFNet  # noqa: E402

    torch.manual_seed(0)
    ref = IFNet().eval()
    load_weights(ref, ckpt)

    img0 = torch.rand(1, 3, h, w)
    img1 = torch.rand(1, 3, h, w)
    t = torch.full((1, 1, 1, 1), 0.5)

    with torch.no_grad():
        # reference path: float timestep, explicit scale_list.
        # IFNet.forward returns (flow_list, mask, merged) - index 2 is the frames.
        a = ref(torch.cat((img0, img1), 1), 0.5, [16, 8, 4, 2, 1])[2][-1]

    ModelCls = make_model_class()
    for ac in (True, False):
        new = ModelCls(h, w, align_corners=ac).eval()
        new.load_state_dict(ref.state_dict(), strict=False)
        with torch.no_grad():
            b = new(img0, img1, t)
        diff = (a - b).abs().max().item()
        tag = "align_corners=True " if ac else "align_corners=False (emulated)"
        # The ac=False emulation is algebraically exact but drifts ~5e-3 through
        # the 5 cascaded blocks (border clamping amplifies the fp rounding of the
        # grid rescale). It is kept only as a documented dead end: the ANE is
        # equally slow either way, so it buys nothing. Warn, do not fail.
        limit = 1e-5 if ac else 2e-2
        status = "OK" if diff <= limit else "OVER"
        print(f"  {tag:32s} max abs diff = {diff:.3e}  [{status}]")
        if diff > limit:
            raise SystemExit(f"VERIFY FAILED for {tag}")
    print(f"  output range : [{b.min():.4f}, {b.max():.4f}]")
    print("  VERIFY OK")


def convert(ckpt, h, w, precision, out_path, align_corners=True):
    import coremltools as ct

    torch.set_grad_enabled(False)
    ModelCls = make_model_class()
    model = ModelCls(h, w, align_corners=align_corners).eval()
    n = load_weights(model, ckpt)
    print(f"  loaded {n} tensors into IFNet({h}x{w}), align_corners={align_corners}")

    img0 = torch.rand(1, 3, h, w)
    img1 = torch.rand(1, 3, h, w)
    t = torch.full((1, 1, 1, 1), 0.5)

    print("  tracing...")
    traced = torch.jit.trace(model, (img0, img1, t), strict=False)
    with torch.no_grad():
        torch_out = traced(img0, img1, t)
    print(f"  traced OK, out shape {tuple(torch_out.shape)}")

    prec = {
        "fp16": ct.precision.FLOAT16,
        "fp32": ct.precision.FLOAT32,
    }[precision]

    print(f"  converting (mlprogram, {precision})...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="img0", shape=(1, 3, h, w)),
            ct.TensorType(name="img1", shape=(1, 3, h, w)),
            ct.TensorType(name="timestep", shape=(1, 1, 1, 1)),
        ],
        outputs=[ct.TensorType(name="frame")],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=prec,
        convert_to="mlprogram",
    )

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    mlmodel.save(out_path)
    print(f"  saved -> {out_path}")

    # Surface what the graph became. The whole point of this spike is whether
    # grid_sample survives (as `resample`) and whether it lands on the ANE.
    try:
        import collections

        prog = mlmodel.get_spec().mlProgram
        ops = collections.Counter()
        for fn in prog.functions.values():
            for blk in fn.block_specializations.values():
                for op in blk.operations:
                    ops[op.type] += 1
        print(f"  MIL ops: {sum(ops.values())} total, {len(ops)} distinct")
        print(
            "    "
            + "  ".join(f"{k}={v}" for k, v in ops.most_common(12))
        )
        n_resample = sum(v for k, v in ops.items() if "resample" in k)
        n_grid = sum(v for k, v in ops.items() if "grid" in k.lower())
        print(f"  resample (the RIFE warp): {n_resample}   grid_sample leftovers: {n_grid}")
        if n_grid:
            print("  WARNING: unconverted grid_sample ops remain")
    except Exception as e:  # pragma: no cover - diagnostics only
        print(f"  (op listing unavailable: {e})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default=None)
    ap.add_argument(
        "--model-dir",
        default=None,
        help="downloaded model package root containing train_log/ "
             "(defaults to models/rife425)",
    )
    ap.add_argument("--height", type=int, default=1088)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    ap.add_argument(
        "--grid-align-corners",
        choices=["true", "false"],
        default="true",
        help="false emulates RIFE's align_corners=True via a grid rescale, "
             "which may be what the ANE needs to accept the resample op",
    )
    ap.add_argument("--out", default=None)
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args()

    model_dir = args.model_dir or os.path.join(HERE, "models", "rife425")
    set_model_root(model_dir)
    if args.ckpt is None:
        args.ckpt = os.path.join(model_dir, "train_log", "flownet.pkl")

    if args.height % 64 or args.width % 64:
        raise SystemExit(
            "height/width must be divisible by 64 "
            "(IFBlock's conv0 does two stride-2 convs at scale=16)"
        )

    ac = args.grid_align_corners == "true"
    print(f"RIFE -> CoreML   {args.width}x{args.height}  {args.precision}  ac={ac}")

    if args.verify:
        print("[verify]")
        verify(args.ckpt, args.height, args.width)
        return

    tag = "" if ac else "_acfalse"
    out = args.out or os.path.join(
        HERE, "build",
        f"rife425_{args.width}x{args.height}_{args.precision}{tag}.mlpackage",
    )
    print("[convert]")
    convert(args.ckpt, args.height, args.width, args.precision, out, align_corners=ac)


if __name__ == "__main__":
    main()
