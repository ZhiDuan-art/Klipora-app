#!/usr/bin/env python3
"""
Standalone Apple Silicon MLX runner & installer for Qwen3-TTS-12Hz-1.7B-VoiceDesign (8-bit).
Creates completely custom voices from natural language descriptions (age, gender, accent, personality, emotion)
without needing any reference audio sample.

Subcommands:
  status
  install
  generate --text "..." --instruct "..." --language Chinese --output /path/to/out.wav
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "Klipora"
VENV_DIR = APP_SUPPORT / "voicedesign-venv"
MODEL_DIR = APP_SUPPORT / "voicedesign-models" / "Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"
REPO_ID = "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit"


def emit(obj: dict):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def find_uv() -> Optional[str]:
    for c in (
        shutil.which("uv"),
        str(Path.home() / ".local" / "bin" / "uv"),
        "/opt/homebrew/bin/uv",
        "/usr/local/bin/uv",
    ):
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def find_arm64_python() -> str:
    candidates = [
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3.11",
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3.12",
        "/usr/local/bin/python3.11",
        "/usr/local/bin/python3",
        sys.executable,
    ]
    for c in candidates:
        if not c or not os.path.isfile(c) or not os.access(c, os.X_OK):
            continue
        try:
            out = subprocess.check_output(
                [c, "-c", "import platform, sys; print(sys.version_info.major, sys.version_info.minor, platform.machine())"],
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=5,
            ).strip()
            parts = out.split()
            if len(parts) == 3:
                maj, minor, arch = int(parts[0]), int(parts[1]), parts[2].lower()
                if maj == 3 and minor >= 10 and arch in ("arm64", "aarch64"):
                    return c
        except Exception:
            continue
    raise RuntimeError("找不到支援 MLX 的 Apple Silicon Python 3.10+（請先透過 Homebrew 安裝 python@3.12 或 uv）。")


def venv_python() -> Path:
    return VENV_DIR / "bin" / "python3"


def is_model_complete() -> bool:
    if not MODEL_DIR.is_dir():
        return False
    has_config = (MODEL_DIR / "config.json").is_file()
    has_weights = any(MODEL_DIR.glob("*.safetensors"))
    return has_config and has_weights


def cmd_status():
    vpy = venv_python()
    venv_ok = vpy.is_file() and os.access(vpy, os.X_OK)
    mlx_ok = False
    if venv_ok:
        p = subprocess.run(
            [str(vpy), "-c", "import mlx_audio, soundfile"],
            capture_output=True,
            text=True,
        )
        mlx_ok = p.returncode == 0
    model_ok = is_model_complete()
    emit({
        "installed": bool(venv_ok and mlx_ok and model_ok),
        "venv": venv_ok,
        "mlx_audio": mlx_ok,
        "model": model_ok,
        "model_dir": str(MODEL_DIR),
        "repo_id": REPO_ID,
    })


def cmd_install():
    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    vpy = venv_python()
    uv = find_uv()

    emit({"stage": "建立 VoiceDesign MLX 隔離環境…", "progress": 0.08})
    if not vpy.is_file():
        if uv:
            subprocess.run([uv, "venv", "--python", "3.12", str(VENV_DIR)], check=True)
        else:
            py = find_arm64_python()
            subprocess.run([py, "-m", "venv", str(VENV_DIR)], check=True)

    emit({"stage": "安裝 mlx-audio 與語音套件…", "progress": 0.25})
    pkgs = ["mlx-audio", "soundfile", "numpy", "huggingface_hub"]
    if uv:
        subprocess.run([uv, "pip", "install", "--python", str(vpy), *pkgs], check=True)
    else:
        subprocess.run([str(vpy), "-m", "pip", "install", "--upgrade", *pkgs], check=True)

    emit({"stage": "下載 Qwen3-TTS 1.7B VoiceDesign (8-bit · ~2.1 GB)…", "progress": 0.48})
    MODEL_DIR.parent.mkdir(parents=True, exist_ok=True)
    dl_code = (
        "from huggingface_hub import snapshot_download; "
        f"snapshot_download(repo_id={REPO_ID!r}, local_dir={str(MODEL_DIR)!r})"
    )
    subprocess.run([str(vpy), "-c", dl_code], check=True)

    if not is_model_complete():
        raise RuntimeError("模型下載後未偵測到完整的 config.json 與 safetensors 權重。")

    emit({"stage": "Qwen3-TTS 1.7B VoiceDesign 安裝完成！", "progress": 1.0, "ok": True})


def cmd_generate(args):
    vpy = venv_python()
    if not vpy.is_file() or not is_model_complete():
        emit({"error": "Qwen3-TTS 1.7B VoiceDesign 尚未安裝，請先點「一鍵安裝」。"})
        sys.exit(1)

    if Path(sys.prefix).resolve() != VENV_DIR.resolve():
        cmd = [
            str(vpy), str(Path(__file__).resolve()), "generate",
            "--text", args.text,
            "--instruct", args.instruct,
            "--language", args.language,
            "--output", args.output,
        ]
        os.execve(str(vpy), cmd, os.environ.copy())

    import numpy as np
    import soundfile as sf
    from mlx_audio.tts.utils import load_model

    emit({"stage": "載入 Qwen3-TTS 1.7B VoiceDesign (MLX)…", "progress": 0.25})
    model = load_model(str(MODEL_DIR))

    lang_map = {
        "auto": "Auto",
        "zh": "Chinese",
        "zh-tw": "Chinese",
        "zh-cn": "Chinese",
        "zh-hant": "Chinese",
        "zh-hans": "Chinese",
        "en": "English",
        "ja": "Japanese",
        "ko": "Korean",
        "de": "German",
        "fr": "French",
        "es": "Spanish",
        "it": "Italian",
        "pt": "Portuguese",
        "ru": "Russian",
    }
    lang_name = lang_map.get(args.language.strip().lower(), args.language.strip() or "Chinese")

    emit({"stage": "依角色描述生成自創聲線…", "progress": 0.62})
    chunks = []
    sample_rate = 24000
    gen_fn = getattr(model, "generate_voice_design", None) or getattr(model, "generate")
    for result in gen_fn(
        text=args.text.strip(),
        language=lang_name,
        instruct=args.instruct.strip(),
    ):
        arr = np.atleast_1d(np.asarray(result.audio, dtype=np.float32).squeeze())
        if arr.size > 0:
            chunks.append(arr)
        if getattr(result, "sample_rate", None):
            sample_rate = int(result.sample_rate)

    if not chunks:
        raise RuntimeError("VoiceDesign 未產生音訊資料，請調整角色描述或台詞後重試。")

    audio = np.concatenate(chunks)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    sf.write(str(out_path), audio, sample_rate, subtype="PCM_16")
    duration = float(len(audio)) / float(sample_rate)
    emit({"stage": "完成", "progress": 1.0, "ok": True, "output": str(out_path), "duration": round(duration, 2)})


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("install")
    g = sub.add_parser("generate")
    g.add_argument("--text", required=True)
    g.add_argument("--instruct", required=True)
    g.add_argument("--language", default="Chinese")
    g.add_argument("--output", required=True)
    args = ap.parse_args()
    try:
        if args.cmd == "status":
            cmd_status()
        elif args.cmd == "install":
            cmd_install()
        elif args.cmd == "generate":
            cmd_generate(args)
    except Exception as exc:
        emit({"error": str(exc)})
        sys.exit(1)


if __name__ == "__main__":
    main()
