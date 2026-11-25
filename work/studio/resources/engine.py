"""Start a private loopback-only ComfyUI instance and report its actual port."""
import os
import runpy
import sys
import tempfile
from pathlib import Path

import torch
from aiohttp import web

ready = Path(sys.argv[1])
main = Path(sys.argv[2]).resolve()
original_start = web.TCPSite.start
_fp8_hook_installed = False


def _install_mps_fp8_hook():
    """Make scaled FP8 models (e.g. Wan 2.2 14B FP8) run cleanly & low-RAM on Apple Silicon MPS.

    Apple Silicon PyTorch MPS does not support Float8_e4m3fn / Float8_e5m2 tensors.
    Patching TensorCoreFP8Layout.dequantize / quantize and QuantizedTensor._handle_to keeps
    14B FP8 weights compact (~14 GB) on CPU while dequantizing per-layer on CPU -> FP16 on MPS.
    """
    global _fp8_hook_installed
    if _fp8_hook_installed or not torch.backends.mps.is_available():
        return
    try:
        import comfy_kitchen.tensor.base as _ck_base
        import comfy_kitchen.tensor.fp8 as _ck_fp8

        _fp8_dtypes = tuple(
            dt for dt in (getattr(torch, "float8_e4m3fn", None), getattr(torch, "float8_e5m2", None))
            if dt is not None
        )
        if not _fp8_dtypes:
            return

        _layout = _ck_fp8.TensorCoreFP8Layout
        _orig_deq = _layout.dequantize.__func__
        _orig_quant = _layout.quantize.__func__

        @classmethod
        def _mps_safe_dequantize(cls, qdata, params):
            if qdata.device.type == "mps" or params.scale.device.type == "mps":
                dev = qdata.device if qdata.device.type == "mps" else params.scale.device
                out_dtype = params.orig_dtype if params.orig_dtype not in _fp8_dtypes else torch.float16
                if qdata.device.type == "mps":
                    q_cpu = qdata.view(torch.uint8).to(device="cpu").view(qdata.dtype)
                else:
                    q_cpu = qdata
                s_cpu = params.scale.to(device="cpu", dtype=out_dtype)
                dq = q_cpu.to(dtype=out_dtype) * s_cpu
                return dq.to(device=dev)
            return _orig_deq(cls, qdata, params)

        @classmethod
        def _mps_safe_quantize(cls, tensor, scale=None, dtype=torch.float8_e4m3fn, **kwargs):
            if tensor.device.type == "mps" or (isinstance(scale, torch.Tensor) and scale.device.type == "mps"):
                cpu_t = tensor.to(device="cpu")
                cpu_s = scale.to(device="cpu") if isinstance(scale, torch.Tensor) else scale
                return _orig_quant(cls, cpu_t, scale=cpu_s, dtype=dtype, **kwargs)
            return _orig_quant(cls, tensor, scale=scale, dtype=dtype, **kwargs)

        _layout.dequantize = _mps_safe_dequantize
        _layout.quantize = _mps_safe_quantize

        # Also patch ComfyUI's comfy.quant_ops FP8 layout subclass(es) and comfy.float.stochastic_rounding
        try:
            import comfy.quant_ops as _c_qops
            for _attr_name in dir(_c_qops):
                _cls = getattr(_c_qops, _attr_name, None)
                if isinstance(_cls, type) and issubclass(_cls, _layout) and _cls is not _layout:
                    if "quantize" in _cls.__dict__:
                        _sub_orig_q = _cls.quantize.__func__
                        def _make_sub_q(orig_fn):
                            @classmethod
                            def _sub_mps_q(cls, tensor, *args, **kwargs):
                                scale = kwargs.get("scale")
                                if tensor.device.type == "mps" or (isinstance(scale, torch.Tensor) and scale.device.type == "mps"):
                                    cpu_t = tensor.to(device="cpu")
                                    if isinstance(scale, torch.Tensor):
                                        kwargs = dict(kwargs)
                                        kwargs["scale"] = scale.to(device="cpu")
                                    return orig_fn(cls, cpu_t, *args, **kwargs)
                                return orig_fn(cls, tensor, *args, **kwargs)
                            return _sub_mps_q
                        _cls.quantize = _make_sub_q(_sub_orig_q)
                    if "dequantize" in _cls.__dict__:
                        _cls.dequantize = _mps_safe_dequantize
        except Exception as _qops_exc:
            print(f"[Klipora] Note: comfy.quant_ops patch skipped ({_qops_exc})", flush=True)

        try:
            import comfy.float as _c_float
            _orig_sr = getattr(_c_float, "stochastic_rounding", None)
            if _orig_sr is not None:
                def _mps_safe_sr(value, dtype, seed=0, *args, **kwargs):
                    if dtype in _fp8_dtypes and hasattr(value, "device") and value.device.type == "mps":
                        return _orig_sr(value.to(device="cpu"), dtype, seed, *args, **kwargs)
                    return _orig_sr(value, dtype, seed, *args, **kwargs)
                _c_float.stochastic_rounding = _mps_safe_sr
        except Exception as _sr_exc:
            print(f"[Klipora] Note: stochastic_rounding patch skipped ({_sr_exc})", flush=True)

        # Intercept QuantizedTensor -> MPS moves so _qdata (FP8) never attempts .to("mps")
        _parse_to = getattr(_ck_base, "_parse_to_args", None)
        if _parse_to is not None and hasattr(_ck_base, "_DISPATCH_TABLE"):
            for op in (torch.ops.aten._to_copy.default,):
                if op in _ck_base._DISPATCH_TABLE:
                    _orig_op = _ck_base._DISPATCH_TABLE[op]
                    def _make_safe(orig_fn):
                        def _safe_op(qt, args, kwargs):
                            target_device, target_dtype = _parse_to(args, kwargs)
                            if (
                                target_device is not None
                                and target_device.type == "mps"
                                and getattr(qt._qdata, "dtype", None) in _fp8_dtypes
                            ):
                                out_dtype = target_dtype or getattr(qt._params, "orig_dtype", torch.float16)
                                if out_dtype in _fp8_dtypes:
                                    out_dtype = torch.float16
                                dq = qt.to(device="cpu", dtype=out_dtype).dequantize()
                                return dq.to(device=target_device, dtype=out_dtype)
                            return orig_fn(qt, args, kwargs)
                        return _safe_op
                    _ck_base._DISPATCH_TABLE[op] = _make_safe(_orig_op)

        _fp8_hook_installed = True
        print("[Klipora] Installed TensorCoreFP8Layout MPS-safe CPU dequantize hook.", flush=True)
    except Exception as _exc:
        print(f"[Klipora] Note: skipped MPS FP8 hook ({_exc})", flush=True)


async def report_ready(site):
    _install_mps_fp8_hook()
    await original_start(site)
    if not site.name.startswith("http://127.0.0.1:"):
        return
    port = site._server.sockets[0].getsockname()[1]
    with tempfile.NamedTemporaryFile(mode="w", dir=ready.parent, delete=False) as marker:
        marker.write(str(port))
    os.replace(marker.name, ready)


web.TCPSite.start = report_ready
sys.path.insert(0, str(main.parent))
options = [] if torch.backends.mps.is_available() else ["--cpu"]
sys.argv = [str(main), *sys.argv[3:], "--listen", "127.0.0.1", "--port", "0", *options]
runpy.run_path(str(main), run_name="__main__")
