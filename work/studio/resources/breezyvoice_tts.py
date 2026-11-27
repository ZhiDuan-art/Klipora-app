#!/usr/bin/env python3
"""
Klipora Local BreezyVoice Runner (MediaTek-Research/BreezyVoice)
Zero-shot Taiwanese Mandarin TTS sharing Klipora's 68-voice profile library.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Klipora"
VENV_DIR = APP_SUPPORT / "breezyvoice-venv"
REPO_DIR = APP_SUPPORT / "breezyvoice-repo"
MODEL_DIR = APP_SUPPORT / "breezyvoice-models" / "BreezyVoice"
HF_REPO_ID = "MediaTek-Research/BreezyVoice"
GIT_REPO_URL = "https://github.com/mtkresearch/BreezyVoice.git"


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def dir_size_bytes(path: Path) -> int:
    if not path.exists():
        return 0
    total = 0
    for root, _, files in os.walk(path):
        for fn in files:
            try:
                total += (Path(root) / fn).stat().st_size
            except OSError:
                pass
    return total


def venv_python() -> Path:
    return VENV_DIR / "bin" / "python3"


def is_model_ready() -> bool:
    return (
        (MODEL_DIR / "llm.pt").is_file()
        and (MODEL_DIR / "flow.pt").is_file()
        and (MODEL_DIR / "hift.pt").is_file()
        and (MODEL_DIR / "cosyvoice.yaml").is_file()
    )


def is_repo_ready() -> bool:
    return (REPO_DIR / "single_inference.py").is_file() and (REPO_DIR / "cosyvoice").is_dir()


def is_venv_ready() -> bool:
    return venv_python().is_file()


def cmd_status(_args):
    venv_ok = is_venv_ready()
    repo_ok = is_repo_ready()
    model_ok = is_model_ready()
    disk = dir_size_bytes(MODEL_DIR) + dir_size_bytes(REPO_DIR) + dir_size_bytes(VENV_DIR)
    emit(
        {
            "installed": venv_ok and repo_ok and model_ok,
            "venv_ready": venv_ok,
            "repo_ready": repo_ok,
            "model_ready": model_ok,
            "disk_bytes": disk,
            "repo_id": HF_REPO_ID,
            "model_dir": str(MODEL_DIR),
        }
    )


def find_suitable_python() -> str:
    candidates = [
        "/opt/homebrew/bin/python3.11",
        "/opt/homebrew/bin/python3.10",
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3.11",
        "/usr/local/bin/python3.10",
        "/usr/local/bin/python3",
        sys.executable,
    ]
    for c in candidates:
        if c and Path(c).is_file():
            try:
                out = subprocess.check_output(
                    [c, "-c", "import sys; print(sys.version_info.major, sys.version_info.minor)"],
                    stderr=subprocess.DEVNULL,
                ).decode().strip()
                maj, minor = map(int, out.split())
                if maj == 3 and 10 <= minor <= 12:
                    return c
            except Exception:
                continue
    return sys.executable


def cmd_install(_args):
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)

    # 1. Python venv
    if not is_venv_ready():
        py = find_suitable_python()
        emit({"stage": f"正在建立 BreezyVoice 獨立環境 ({Path(py).name})…", "progress": 0.08})
        subprocess.run([py, "-m", "venv", str(VENV_DIR)], check=True)

    vpy = str(venv_python())
    emit({"stage": "正在安裝 PyTorch / ONNX / BreezyVoice 依賴套件…", "progress": 0.18})
    subprocess.run([vpy, "-m", "pip", "install", "--upgrade", "pip", "wheel"], check=True)

    # Apple Silicon compatible dependency set (no CUDA/deepspeed/Linux-only ttsfrd wheel)
    pkgs = [
        "torch>=2.3.0,<2.7.0",
        "torchaudio>=2.3.0,<2.7.0",
        "onnxruntime",
        "huggingface_hub",
        "HyperPyYAML",
        "conformer==0.3.2",
        "diffusers>=0.29.0",
        "hydra-core",
        "omegaconf",
        "inflect",
        "librosa",
        "soundfile",
        "scipy",
        "opencc-python-reimplemented",
        "g2pw",
        "WeTextProcessing",
        "pyarrow",
        "pydantic",
        "rich",
        "openai-whisper",
    ]
    subprocess.run([vpy, "-m", "pip", "install", "--prefer-binary", *pkgs], check=True)

    # 2. Clone mtkresearch/BreezyVoice
    if not is_repo_ready():
        emit({"stage": "正在下載聯發創新基地 BreezyVoice 推論框架…", "progress": 0.45})
        if REPO_DIR.exists():
            shutil.rmtree(REPO_DIR)
        subprocess.run(
            ["git", "clone", "--depth", "1", "--recursive", GIT_REPO_URL, str(REPO_DIR)],
            check=True,
        )

    # 3. Download HuggingFace weights (MediaTek-Research/BreezyVoice)
    emit({"stage": "正在從 HuggingFace 下載 MediaTek-Research/BreezyVoice 權重 (~2.8 GB)…", "progress": 0.58})
    MODEL_DIR.parent.mkdir(parents=True, exist_ok=True)
    dl_code = f"""
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id={HF_REPO_ID!r},
    local_dir={str(MODEL_DIR)!r},
)
"""
    subprocess.run([vpy, "-c", dl_code], check=True)
    emit({"stage": "BreezyVoice 台灣國語引擎安裝完成！", "progress": 1.0, "ok": True})


def cmd_uninstall(args):
    removed = []
    if MODEL_DIR.exists():
        shutil.rmtree(MODEL_DIR, ignore_errors=True)
        removed.append(str(MODEL_DIR))
    if args.all:
        for d in (REPO_DIR, VENV_DIR):
            if d.exists():
                shutil.rmtree(d, ignore_errors=True)
                removed.append(str(d))
    emit({"ok": True, "removed": removed})


def cmd_synthesize(args):
    if not (is_venv_ready() and is_repo_ready() and is_model_ready()):
        emit({"ok": False, "error": "BreezyVoice 尚未安裝完成，請先於語音工作室或語音模型管理頁下載安裝。"})
        sys.exit(2)

    ref_audio = Path(args.ref_audio).expanduser().resolve()
    if not ref_audio.is_file():
        emit({"ok": False, "error": f"找不到聲音角色參考音檔：{ref_audio}"})
        sys.exit(2)

    out_path = Path(args.output).expanduser().resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Re-exec inside breezyvoice-venv so all torch/cosyvoice imports resolve cleanly
    if Path(sys.prefix).resolve() != VENV_DIR.resolve():
        env = os.environ.copy()
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        cmd = [
            str(venv_python()),
            str(Path(__file__).resolve()),
            "synthesize",
            "--ref-audio",
            str(ref_audio),
            "--ref-text",
            args.ref_text or "",
            "--text",
            args.text,
            "--output",
            str(out_path),
        ]
        if args.seed is not None:
            cmd += ["--seed", str(args.seed)]
        os.execve(str(venv_python()), cmd, env)

    # Running inside breezyvoice-venv
    os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
    sys.path.insert(0, str(REPO_DIR))
    matcha_dir = REPO_DIR / "third_party" / "Matcha-TTS"
    if matcha_dir.is_dir():
        sys.path.insert(0, str(matcha_dir))

    import inspect
    import torch
    import torchaudio
    from cosyvoice.utils.file_utils import load_wav

    if args.seed is not None:
        torch.manual_seed(int(args.seed))

    emit({"stage": "正在載入 MediaTek BreezyVoice 模型…", "progress": 0.25})
    # mtkresearch/BreezyVoice defines CustomCosyVoice in single_inference.py with the updated frontend signature
    try:
        from single_inference import CustomCosyVoice
        cosyvoice = CustomCosyVoice(str(MODEL_DIR))
    except Exception:
        from cosyvoice.cli.cosyvoice import CosyVoice
        cosyvoice = CosyVoice(str(MODEL_DIR))

    # Load reference audio at 16 kHz mono as expected by CosyVoice / BreezyVoice
    prompt_speech_16k = load_wav(str(ref_audio), 16000)
    prompt_text = (args.ref_text or "").strip()

    # If reference transcript is empty, transcribe quickly with bundled whisper so zero-shot aligns cleanly
    if not prompt_text:
        try:
            import whisper
            emit({"stage": "正在辨識參考音檔逐字稿…", "progress": 0.40})
            wmodel = whisper.load_model("base")
            wres = wmodel.transcribe(str(ref_audio), language="zh")
            prompt_text = (wres.get("text") or "").strip()
        except Exception:
            prompt_text = ""

    emit({"stage": "正在以台灣國語聲紋合成語音…", "progress": 0.55})
    target_text = args.text.strip()

    chunks = []
    if prompt_text:
        fn = cosyvoice.inference_zero_shot
        sig = inspect.signature(fn)
        if "stream" in sig.parameters:
            res = fn(target_text, prompt_text, prompt_speech_16k, stream=False)
        else:
            res = fn(target_text, prompt_text, prompt_speech_16k)
    else:
        fn = cosyvoice.inference_cross_lingual
        sig = inspect.signature(fn)
        if "stream" in sig.parameters:
            res = fn(target_text, prompt_speech_16k, stream=False)
        else:
            res = fn(target_text, prompt_speech_16k)

    # Upstream BreezyVoice returns a single dict {"tts_speech": tensor}; older CosyVoice yields dicts
    if isinstance(res, dict):
        if "tts_speech" in res:
            chunks.append(res["tts_speech"])
    else:
        for item in res:
            if isinstance(item, dict) and "tts_speech" in item:
                chunks.append(item["tts_speech"])

    if not chunks:
        emit({"ok": False, "error": "BreezyVoice 未產生音訊輸出。"})
        sys.exit(1)

    wav = torch.cat(chunks, dim=1) if len(chunks) > 1 else chunks[0]
    sr = getattr(cosyvoice, "sample_rate", 22050)
    torchaudio.save(str(out_path), wav.cpu(), sr)
    duration = float(wav.shape[1]) / float(sr)
    emit({"ok": True, "output": str(out_path), "duration": round(duration, 3), "sample_rate": sr})


def main():
    parser = argparse.ArgumentParser(description="Klipora BreezyVoice Local TTS Runner")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status")
    sub.add_parser("install")
    p_un = sub.add_parser("uninstall")
    p_un.add_argument("--all", action="store_true")

    p_syn = sub.add_parser("synthesize")
    p_syn.add_argument("--ref-audio", required=True)
    p_syn.add_argument("--ref-text", default="")
    p_syn.add_argument("--text", required=True)
    p_syn.add_argument("--output", required=True)
    p_syn.add_argument("--seed", type=int, default=None)

    args = parser.parse_args()
    try:
        if args.cmd == "status":
            cmd_status(args)
        elif args.cmd == "install":
            cmd_install(args)
        elif args.cmd == "uninstall":
            cmd_uninstall(args)
        elif args.cmd == "synthesize":
            cmd_synthesize(args)
    except Exception as exc:
        emit({"ok": False, "error": str(exc)})
        sys.exit(1)


if __name__ == "__main__":
    main()
