#!/usr/bin/env python3
"""
MotionDesk V4 Local Neural Audio AI Engine (audio_ai.py)

Provides isolated, reversible, CPU-friendly ONNX / CTranslate2 neural audio
pipelines without PyTorch duplication or GPU contention with ComfyUI:
  1. vocal_sep   : UVR MDX-Net ONNX (UVR-MDX-NET-Inst_HQ_3.onnx / Kim_Vocal_2.onnx)
  2. asr         : Faster-Whisper Base INT8 (CTranslate2 CPU, Traditional Chinese)
  3. tts         : Sherpa-ONNX Kokoro INT8 Multi-Lang v1.0 (8 Chinese speakers)
  4. voice_clone : Sherpa-ONNX ZipVoice-Distill INT8 zh-en + Vocos 24kHz vocoder

Dispatcher commands (`status`, `install`, `uninstall`) run under macOS
`/usr/bin/python3` (Python 3.9+) using stdlib only, creating/managing an
isolated venv at `~/Library/Application Support/Klipora/ai-audio-venv`
derived from the system base Python 3.10-3.12 (NEVER installing packages into
ComfyUI's `.venv`).

Inference commands (`separate`, `asr`, `tts`, `voice-clone`) automatically
re-exec into the isolated venv Python so all neural runtime dependencies stay
strictly isolated. All progress logs go to stderr; stdout emits JSON only.
"""

from __future__ import annotations

import argparse
import contextlib
import glob
import json
import math
import os
import re
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Paths, Constants, Verified Upstream Model Registry
# ---------------------------------------------------------------------------

DEFAULT_AI_ROOT = Path.home() / "Library" / "Application Support" / "MotionDesk"
AI_ROOT = Path(os.environ.get("MOTIONDESK_AI_ROOT", str(DEFAULT_AI_ROOT))).expanduser()
VENV_DIR = AI_ROOT / "ai-audio-venv"
MODELS_DIR = AI_ROOT / "ai-models"

COMFYUI_VENV_DIR = Path("/Users/zhangzhiduan/Documents/ComfyUI/.venv")

VENV_PACKAGES = [
    "numpy",
    "scipy",
    "soundfile",
    "onnxruntime",
    "sherpa-onnx",
    "faster-whisper",
]

VENV_IMPORT_CHECKS = {
    "onnxruntime": "onnxruntime",
    "sherpa_onnx": "sherpa_onnx",
    "faster_whisper": "faster_whisper",
    "soundfile": "soundfile",
    "numpy": "numpy",
    "scipy": "scipy",
}

# Verified UVR MDX-Net model specs & official TRvlvr/model_repo release URLs
MDX_MODELS: Dict[str, Dict[str, Any]] = {
    "UVR-MDX-NET-Inst_HQ_3.onnx": {
        "url": "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/UVR-MDX-NET-Inst_HQ_3.onnx",
        "primary_stem": "instrumental",
        "n_fft": 6144,
        "hop_length": 1024,
        "dim_f": 3072,
        "dim_t": 256,
        "compensate": 1.035,
        "min_bytes": 20 * 1024 * 1024,
        "estimated_mb": 55,
    },
    "Kim_Vocal_2.onnx": {
        "url": "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/Kim_Vocal_2.onnx",
        "primary_stem": "vocals",
        "n_fft": 7680,
        "hop_length": 1024,
        "dim_f": 3072,
        "dim_t": 256,
        "compensate": 1.009,
        "min_bytes": 25 * 1024 * 1024,
        "estimated_mb": 67,
    },
}
MDX_PRIMARY_MODEL = "UVR-MDX-NET-Inst_HQ_3.onnx"
MDX_FALLBACK_MODEL = "Kim_Vocal_2.onnx"

# Verified Kokoro v1.0 INT8 multi-lang archive & exact Chinese speaker IDs
KOKORO_ARCHIVE_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    "tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2"
)
KOKORO_SUBDIR = "kokoro-int8-multi-lang-v1_0"

KOKORO_ZH_SPEAKERS: List[Dict[str, Any]] = [
    {"id": 45, "code": "zf_xiaobei", "name": "小北（中文女聲）", "gender": "female", "language": "zh"},
    {"id": 46, "code": "zf_xiaoni", "name": "小妮（中文女聲）", "gender": "female", "language": "zh"},
    {"id": 47, "code": "zf_xiaoxiao", "name": "曉曉（中文女聲）", "gender": "female", "language": "zh"},
    {"id": 48, "code": "zf_xiaoyi", "name": "小藝（中文女聲）", "gender": "female", "language": "zh"},
    {"id": 49, "code": "zm_yunjian", "name": "雲健（中文男聲）", "gender": "male", "language": "zh"},
    {"id": 50, "code": "zm_yunxi", "name": "雲希（中文男聲）", "gender": "male", "language": "zh"},
    {"id": 51, "code": "zm_yunxia", "name": "雲夏（中文男聲）", "gender": "male", "language": "zh"},
    {"id": 52, "code": "zm_yunyang", "name": "雲揚（中文男聲）", "gender": "male", "language": "zh"},
]

# Verified Sherpa-ONNX ZipVoice-Distill INT8 zh-en + Vocos 24kHz vocoder URLs
ZIPVOICE_ARCHIVE_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    "tts-models/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2"
)
ZIPVOICE_SUBDIR = "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia"
VOCOS_24KHZ_URL = (
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/"
    "vocoder-models/vocos_24khz.onnx"
)

ASR_SUBDIR = "faster-whisper-base"
ASR_SMALL_SUBDIR = "faster-whisper-small"
DEFAULT_ZH_PROMPT = "以下是繁體中文的字幕內容，請使用自然流暢的台灣繁體中文與標準標點符號。"


# ---------------------------------------------------------------------------
# Utility Helpers (Stdlib Only)
# ---------------------------------------------------------------------------

def log(msg: str) -> None:
    """Emit diagnostic/progress messages strictly to stderr."""
    sys.stderr.write(f"[audio_ai] {msg}\n")
    sys.stderr.flush()


def emit_json(payload: Dict[str, Any], exit_code: int = 0) -> None:
    """Emit structured JSON strictly to stdout and exit."""
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    sys.stdout.flush()
    if exit_code != 0:
        sys.exit(exit_code)


def emit_error(
    message: str,
    *,
    module: Optional[str] = None,
    needs_install: bool = False,
    details: Optional[str] = None,
    exit_code: int = 1,
) -> None:
    payload: Dict[str, Any] = {
        "ok": False,
        "error": message,
        "needsInstall": needs_install,
    }
    if module is not None:
        payload["module"] = module
    if details:
        payload["details"] = details
    emit_json(payload, exit_code=exit_code)


CACHE_DIR = AI_ROOT / "cache"
SIZE_CACHE_FILE = CACHE_DIR / "audio_ai_dir_sizes.json"


def _load_size_cache() -> Dict[str, Any]:
    try:
        if SIZE_CACHE_FILE.is_file():
            data = json.loads(SIZE_CACHE_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
    except Exception:
        pass
    return {}


def _save_size_cache(data: Dict[str, Any]) -> None:
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp_path = CACHE_DIR / f".size_cache.{os.getpid()}.tmp"
        tmp_path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(str(tmp_path), str(SIZE_CACHE_FILE))
    except OSError:
        pass


def invalidate_size_cache(path: Optional[Path] = None) -> None:
    """Explicitly invalidate directory size cache after any managed install/uninstall."""
    try:
        if path is None:
            if SIZE_CACHE_FILE.exists():
                SIZE_CACHE_FILE.unlink()
            return
        cache = _load_size_cache()
        key = str(path.resolve())
        if key in cache:
            del cache[key]
            _save_size_cache(cache)
    except Exception:
        pass


def _dir_signature(path: Path) -> str:
    """
    Compute a fast signature across the root directory, key sentinel subdirectories
    (e.g. site-packages, bin, model subdirs), and immediate child entries so nested
    package updates or model downloads invalidate the cached size estimate.
    """
    parts: List[str] = []
    probe_targets: List[Path] = [path]
    # Check standard venv site-packages & bin dirs
    for rel in ("bin", "lib", "pyvenv.cfg", ASR_SUBDIR, ASR_SMALL_SUBDIR, KOKORO_SUBDIR, ZIPVOICE_SUBDIR):
        cand = path / rel
        if cand.exists():
            probe_targets.append(cand)
    for sp in path.glob("lib/python*/site-packages"):
        probe_targets.append(sp)
    try:
        for child in sorted(path.iterdir())[:64]:
            probe_targets.append(child)
    except OSError:
        pass

    seen = set()
    for target in probe_targets:
        t_str = str(target)
        if t_str in seen:
            continue
        seen.add(t_str)
        try:
            st = target.stat()
            child_count = len(os.listdir(target)) if target.is_dir() else 0
            parts.append(f"{target.name}:{int(st.st_mtime_ns)}:{st.st_size}:{child_count}")
        except OSError:
            continue
    return "|".join(parts)


def dir_size_bytes(path: Path, *, use_cache: bool = True, force_refresh: bool = False) -> int:
    if not path.exists():
        return 0
    if path.is_file():
        try:
            return path.stat().st_size
        except OSError:
            return 0

    # Clean up any legacy in-directory cache file from earlier draft
    legacy_in_dir = path / ".motiondesk_size_cache.json"
    if legacy_in_dir.is_file():
        with contextlib.suppress(OSError):
            legacy_in_dir.unlink()

    cache_key = str(path.resolve())
    sig = _dir_signature(path)
    if use_cache and not force_refresh:
        cache = _load_size_cache()
        entry = cache.get(cache_key)
        if isinstance(entry, dict) and entry.get("signature") == sig:
            size_val = int(entry.get("sizeBytes", 0))
            if size_val > 0:
                return size_val

    total = 0
    for root, _dirs, files in os.walk(path):
        for fname in files:
            if fname == ".motiondesk_size_cache.json":
                continue
            fpath = os.path.join(root, fname)
            try:
                if not os.path.islink(fpath):
                    total += os.path.getsize(fpath)
            except OSError:
                pass
    if use_cache and total > 0:
        cache = _load_size_cache()
        cache[cache_key] = {
            "signature": sig,
            "sizeBytes": total,
            "updatedAt": int(time.time()),
            "isEstimate": True,
        }
        _save_size_cache(cache)
    return total


def find_ffmpeg() -> Optional[str]:
    candidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/opt/homebrew/Cellar/ffmpeg/8.1_1/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        shutil.which("ffmpeg"),
    ]
    for cand in candidates:
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def _run_subprocess(
    cmd: List[str],
    *,
    timeout: Optional[int] = None,
    check: bool = True,
    capture: bool = True,
    env: Optional[Dict[str, str]] = None,
) -> subprocess.CompletedProcess:
    kwargs: Dict[str, Any] = {
        "stdin": subprocess.DEVNULL,
        "timeout": timeout,
        "env": env,
    }
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
        kwargs["text"] = True
    else:
        # Redirect child stdout to stderr so our JSON stdout is never polluted
        kwargs["stdout"] = sys.stderr
        kwargs["stderr"] = sys.stderr
    proc = subprocess.run(cmd, **kwargs)
    if check and proc.returncode != 0:
        err_out = ""
        if capture:
            err_out = ((proc.stderr or "") + "\n" + (proc.stdout or "")).strip()
        raise RuntimeError(
            f"Command failed (exit {proc.returncode}): {' '.join(cmd)}"
            + (f"\n{err_out[-1500:]}" if err_out else "")
        )
    return proc


def _probe_python_version(exe: str) -> Optional[Tuple[int, int, int]]:
    if not exe or not os.path.isfile(exe) or not os.access(exe, os.X_OK):
        return None
    try:
        proc = _run_subprocess(
            [exe, "-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}')"],
            timeout=10,
            check=True,
            capture=True,
        )
        parts = proc.stdout.strip().split(".")
        if len(parts) >= 3:
            return (int(parts[0]), int(parts[1]), int(parts[2]))
    except Exception:
        return None
    return None


def _is_inside_comfy_venv(path_str: str) -> bool:
    try:
        resolved = Path(path_str).resolve()
        comfy_resolved = COMFYUI_VENV_DIR.resolve()
        return resolved == comfy_resolved or comfy_resolved in resolved.parents
    except Exception:
        return str(COMFYUI_VENV_DIR) in path_str


def _extract_comfy_base_python() -> Optional[str]:
    """
    Safely discover the underlying real base Python 3.12 executable used by
    ComfyUI's `.venv`, WITHOUT ever modifying or installing into ComfyUI's venv.
    """
    # 1. Inspect pyvenv.cfg (pure file read, works even if venv exe is restricted)
    pyvenv_cfg = COMFYUI_VENV_DIR / "pyvenv.cfg"
    if pyvenv_cfg.is_file():
        try:
            home_dir = None
            base_exec = None
            for line in pyvenv_cfg.read_text(encoding="utf-8", errors="ignore").splitlines():
                if "=" not in line:
                    continue
                k, v = [p.strip() for p in line.split("=", 1)]
                if k == "home":
                    home_dir = Path(v)
                elif k == "base-executable":
                    base_exec = Path(v)
            if base_exec and base_exec.is_file() and os.access(str(base_exec), os.X_OK):
                if not _is_inside_comfy_venv(str(base_exec)):
                    return str(base_exec)
            if home_dir and home_dir.is_dir():
                for name in ("python3.12", "python3.11", "python3.10", "python3"):
                    cand = home_dir / name
                    if cand.is_file() and os.access(str(cand), os.X_OK):
                        real_cand = os.path.realpath(str(cand))
                        if not _is_inside_comfy_venv(real_cand):
                            return real_cand
        except OSError:
            pass

    # 2. Check symlink target of ComfyUI/.venv/bin/python3.12
    for name in ("python3.12", "python3.11", "python3"):
        venv_py = COMFYUI_VENV_DIR / "bin" / name
        if venv_py.exists():
            real_py = os.path.realpath(str(venv_py))
            if real_py and not _is_inside_comfy_venv(real_py) and os.path.isfile(real_py):
                return real_py

    # 3. Last resort read-only query of sys.base_prefix
    comfy_py = COMFYUI_VENV_DIR / "bin" / "python3.12"
    if comfy_py.is_file() and os.access(str(comfy_py), os.X_OK):
        try:
            proc = _run_subprocess(
                [
                    str(comfy_py),
                    "-c",
                    "import os, sys; "
                    "p = os.path.join(sys.base_prefix, 'bin', 'python3.12'); "
                    "p = p if os.path.isfile(p) else os.path.join(sys.base_prefix, 'bin', 'python3'); "
                    "print(os.path.realpath(p))",
                ],
                timeout=10,
                check=True,
                capture=True,
            )
            real_py = proc.stdout.strip()
            if real_py and not _is_inside_comfy_venv(real_py) and os.path.isfile(real_py):
                return real_py
        except Exception:
            pass

    return None


def detect_base_python() -> Dict[str, Any]:
    """
    Detect best standalone base Python (preferring 3.12 -> 3.11 -> 3.10) for
    creating our isolated `ai-audio-venv`. Never returns a path inside
    ComfyUI's `.venv`.
    """
    candidates: List[Tuple[str, str]] = []

    env_override = os.environ.get("MOTIONDESK_BASE_PYTHON")
    if env_override:
        candidates.append((env_override, "env_override"))

    comfy_base = _extract_comfy_base_python()
    if comfy_base:
        candidates.append((comfy_base, "comfyui_base_prefix"))

    # Homebrew / Framework / uv / pyenv standard paths
    static_paths = [
        ("/opt/homebrew/bin/python3.12", "homebrew"),
        ("/opt/homebrew/bin/python3.11", "homebrew"),
        ("/opt/homebrew/bin/python3.10", "homebrew"),
        ("/usr/local/bin/python3.12", "usr_local"),
        ("/usr/local/bin/python3.11", "usr_local"),
        ("/usr/local/bin/python3.10", "usr_local"),
        ("/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12", "framework"),
        ("/Library/Frameworks/Python.framework/Versions/3.11/bin/python3.11", "framework"),
        ("/Library/Frameworks/Python.framework/Versions/3.10/bin/python3.10", "framework"),
    ]
    candidates.extend(static_paths)

    # Check uv managed Pythons & pyenv
    for pattern, src in [
        (str(Path.home() / ".local/share/uv/python/cpython-3.12*/bin/python3*"), "uv"),
        (str(Path.home() / ".local/share/uv/python/cpython-3.11*/bin/python3*"), "uv"),
        (str(Path.home() / ".pyenv/versions/3.12*/bin/python3*"), "pyenv"),
        (str(Path.home() / ".pyenv/versions/3.11*/bin/python3*"), "pyenv"),
    ]:
        for matched in sorted(glob.glob(pattern), reverse=True):
            if not matched.endswith("-config"):
                candidates.append((matched, src))

    for name in ("python3.12", "python3.11", "python3.10"):
        found = shutil.which(name)
        if found:
            candidates.append((found, "system_path"))

    seen = set()
    best_39: Optional[Dict[str, Any]] = None

    for raw_path, source in candidates:
        if not raw_path or not os.path.isfile(raw_path):
            continue
        real_path = os.path.realpath(raw_path)
        if real_path in seen or _is_inside_comfy_venv(real_path):
            continue
        seen.add(real_path)
        ver = _probe_python_version(real_path)
        if not ver:
            continue
        ver_str = f"{ver[0]}.{ver[1]}.{ver[2]}"
        if (3, 10, 0) <= ver < (3, 14, 0):
            return {
                "path": real_path,
                "version": ver_str,
                "source": source,
                "recommended": True,
                "warning": None,
            }
        if ver >= (3, 9, 0) and best_39 is None:
            best_39 = {
                "path": real_path,
                "version": ver_str,
                "source": source,
                "recommended": False,
                "warning": f"偵測到 Python {ver_str}；建議使用 Python 3.10–3.12 以取得完整 onnxruntime / sherpa-onnx 套件支援。",
            }

    # Final fallback: /usr/bin/python3 or current interpreter
    fallback_py = os.path.realpath(sys.executable)
    ver = _probe_python_version(fallback_py)
    ver_str = f"{ver[0]}.{ver[1]}.{ver[2]}" if ver else "unknown"
    if best_39:
        return best_39
    return {
        "path": fallback_py,
        "version": ver_str,
        "source": "system_fallback",
        "recommended": bool(ver and (3, 10, 0) <= ver < (3, 14, 0)),
        "warning": (
            None
            if (ver and (3, 10, 0) <= ver < (3, 14, 0))
            else f"僅找到系統 Python {ver_str}（建議安裝 Python 3.12 或確認 ComfyUI 基礎 Python 3.12 路徑）。"
        ),
    }


def venv_python_path() -> Path:
    return VENV_DIR / "bin" / "python"


def is_running_in_venv() -> bool:
    try:
        return Path(sys.prefix).resolve() == VENV_DIR.resolve()
    except Exception:
        return False


def ensure_venv_reexec(module_name: str) -> None:
    """
    For neural inference commands, ensure execution runs inside the isolated
    `ai-audio-venv`. Re-execs cleanly if invoked by `/usr/bin/python3`.
    """
    if is_running_in_venv():
        return
    vpy = venv_python_path()
    if not vpy.is_file() or not os.access(str(vpy), os.X_OK):
        emit_error(
            f"隔離音訊 AI 環境尚未安裝（{VENV_DIR}）。請先執行安裝步驟。",
            module=module_name,
            needs_install=True,
        )
    env = os.environ.copy()
    env.setdefault("ORT_LOG_SEVERITY_LEVEL", "3")
    env.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    os.execve(str(vpy), [str(vpy), os.path.abspath(__file__), *sys.argv[1:]], env)


def probe_venv_status(*, force_refresh_size: bool = False) -> Dict[str, Any]:
    vpy = venv_python_path()
    pkg_status = {k: False for k in VENV_IMPORT_CHECKS}
    if not vpy.is_file() or not os.access(str(vpy), os.X_OK):
        return {
            "installed": False,
            "ready": False,
            "pythonPath": str(vpy),
            "pythonVersion": None,
            "packages": pkg_status,
            "estimatedSizeMB": 180,
            "diskSizeBytes": dir_size_bytes(VENV_DIR, force_refresh=force_refresh_size),
            "sizeIsEstimate": True,
        }

    probe_code = "\n".join([
        "import importlib.util, json, sys",
        f"mods = {repr(VENV_IMPORT_CHECKS)}",
        "res = {k: (importlib.util.find_spec(m) is not None) for k, m in mods.items()}",
        "print(json.dumps({'version': f'{sys.version_info[0]}.{sys.version_info[1]}.{sys.version_info[2]}', 'packages': res}))",
    ])
    py_ver = None
    try:
        proc = _run_subprocess([str(vpy), "-c", probe_code], timeout=30, check=True, capture=True)
        data = json.loads(proc.stdout.strip().splitlines()[-1])
        py_ver = data.get("version")
        pkg_status.update(data.get("packages", {}))
    except Exception as exc:
        log(f"venv probe warning: {exc}")

    installed = bool(py_ver) and all(pkg_status.values())
    return {
        "installed": installed,
        "ready": installed,
        "pythonPath": str(vpy),
        "pythonVersion": py_ver,
        "packages": pkg_status,
        "estimatedSizeMB": 180,
        "diskSizeBytes": dir_size_bytes(VENV_DIR, force_refresh=force_refresh_size),
        "sizeIsEstimate": True,
    }


# ---------------------------------------------------------------------------
# Model Inspection Helpers
# ---------------------------------------------------------------------------

def _find_vocal_sep_model() -> Tuple[Optional[Path], Optional[str]]:
    mod_dir = MODELS_DIR / "vocal_sep"
    for name in (MDX_PRIMARY_MODEL, MDX_FALLBACK_MODEL):
        p = mod_dir / name
        if p.is_file() and p.stat().st_size >= 10 * 1024 * 1024:
            return p, name
    return None, None


def _find_asr_model_dir() -> Optional[Path]:
    for sub in (ASR_SMALL_SUBDIR, ASR_SUBDIR):
        cand = MODELS_DIR / "asr" / sub
        if cand.is_dir() and (cand / "model.bin").is_file():
            return cand
    return None


def _find_kokoro_assets() -> Optional[Dict[str, str]]:
    base = MODELS_DIR / "tts" / KOKORO_SUBDIR
    if not base.is_dir():
        # Check if extracted directly into MODELS_DIR / "tts"
        alt = MODELS_DIR / "tts"
        if (alt / "voices.bin").is_file():
            base = alt
        else:
            return None

    model_file = None
    for cand in ("model.int8.onnx", "model.onnx"):
        p = base / cand
        if p.is_file():
            model_file = p
            break
    voices = base / "voices.bin"
    tokens = base / "tokens.txt"
    if not (model_file and voices.is_file() and tokens.is_file()):
        return None

    data_dir = base / "espeak-ng-data"
    dict_dir = base / "dict"
    lexicons = [
        str(base / fname)
        for fname in ("lexicon-us-en.txt", "lexicon-zh.txt")
        if (base / fname).is_file()
    ]
    rule_fsts = [
        str(base / fname)
        for fname in ("phone-zh.fst", "date-zh.fst", "number-zh.fst")
        if (base / fname).is_file()
    ]
    return {
        "root": str(base),
        "model": str(model_file),
        "voices": str(voices),
        "tokens": str(tokens),
        "data_dir": str(data_dir) if data_dir.is_dir() else "",
        "dict_dir": str(dict_dir) if dict_dir.is_dir() else "",
        "lexicon": ",".join(lexicons),
        "rule_fsts": ",".join(rule_fsts),
    }


def _find_zipvoice_assets() -> Optional[Dict[str, str]]:
    vc_root = MODELS_DIR / "voice_clone"
    if not vc_root.is_dir():
        return None
    sub = vc_root / ZIPVOICE_SUBDIR
    search_dirs = [sub, vc_root] if sub.is_dir() else [vc_root]

    def _first_match(patterns: List[str]) -> Optional[Path]:
        for d in search_dirs:
            for pat in patterns:
                matches = sorted(d.glob(pat))
                for m in matches:
                    if m.is_file():
                        return m
        return None

    encoder = _first_match([
        "encoder*.int8.onnx",
        "text_encoder*.int8.onnx",
        "encoder*.onnx",
        "text_encoder*.onnx",
    ])
    decoder = _first_match([
        "decoder*.int8.onnx",
        "fm_decoder*.int8.onnx",
        "decoder*.onnx",
        "fm_decoder*.onnx",
    ])
    vocoder = _first_match(["vocos_24khz.onnx", "vocos*.onnx"])
    tokens = _first_match(["tokens.txt"])
    lexicon = _first_match(["lexicon.txt", "lexicon*.txt"])
    pinyin = _first_match(["pinyin.raw", "pinyin*.txt"])

    data_dir = ""
    for d in search_dirs:
        cand = d / "espeak-ng-data"
        if cand.is_dir():
            data_dir = str(cand)
            break

    if not (encoder and decoder and vocoder and tokens):
        return None

    return {
        "root": str(sub if sub.is_dir() else vc_root),
        "encoder": str(encoder),
        "decoder": str(decoder),
        "vocoder": str(vocoder),
        "tokens": str(tokens),
        "lexicon": str(lexicon) if lexicon else "",
        "pinyin_dict": str(pinyin) if pinyin else "",
        "data_dir": data_dir,
    }


def collect_status(*, force_refresh_size: bool = False) -> Dict[str, Any]:
    if force_refresh_size:
        invalidate_size_cache()
    venv_info = probe_venv_status(force_refresh_size=force_refresh_size)
    if venv_info.get("installed"):
        # Known valid audio venv already exists: avoid needless ComfyUI / system base Python discovery subprocesses.
        base_py = {
            "path": os.path.realpath(venv_info["pythonPath"]),
            "version": venv_info.get("pythonVersion") or "3.12",
            "source": "existing_audio_venv",
            "recommended": True,
            "warning": None,
        }
    else:
        base_py = detect_base_python()
    venv_pkgs = venv_info["packages"]
    ffmpeg_path = find_ffmpeg()

    vocal_path, vocal_model_name = _find_vocal_sep_model()
    vocal_installed = vocal_path is not None
    vocal_venv_ok = bool(venv_pkgs.get("onnxruntime") and venv_pkgs.get("soundfile") and venv_pkgs.get("numpy"))

    asr_dir = _find_asr_model_dir()
    asr_installed = asr_dir is not None
    asr_venv_ok = bool(venv_pkgs.get("faster_whisper"))

    kokoro_assets = _find_kokoro_assets()
    tts_installed = kokoro_assets is not None
    tts_venv_ok = bool(venv_pkgs.get("sherpa_onnx") and venv_pkgs.get("soundfile"))

    zipvoice_assets = _find_zipvoice_assets()
    vc_installed = zipvoice_assets is not None
    vc_venv_ok = bool(venv_pkgs.get("sherpa_onnx") and venv_pkgs.get("soundfile") and venv_pkgs.get("numpy"))

    modules: Dict[str, Dict[str, Any]] = {
        "vocal_sep": {
            "id": "vocal_sep",
            "title": "人聲與伴奏分離 (UVR MDX-Net ONNX)",
            "engine": "ONNX Runtime + UVR-MDX-NET-Inst_HQ_3",
            "license": "MIT",
            "installed": vocal_installed,
            "ready": vocal_installed and vocal_venv_ok and bool(ffmpeg_path),
            "needsVenv": not vocal_venv_ok,
            "estimatedSizeMB": 55,
            "diskSizeBytes": dir_size_bytes(MODELS_DIR / "vocal_sep", force_refresh=force_refresh_size),
            "modelPath": str(vocal_path) if vocal_path else str(MODELS_DIR / "vocal_sep" / MDX_PRIMARY_MODEL),
            "activeModel": vocal_model_name or MDX_PRIMARY_MODEL,
            "sourceUrl": MDX_MODELS[MDX_PRIMARY_MODEL]["url"],
            "fallbackUrl": MDX_MODELS[MDX_FALLBACK_MODEL]["url"],
        },
        "asr": {
            "id": "asr",
            "title": "自動字幕 ASR (Faster-Whisper Base INT8)",
            "engine": "CTranslate2 INT8 CPU (Systran/faster-whisper-base)",
            "license": "MIT",
            "installed": asr_installed,
            "ready": asr_installed and asr_venv_ok and bool(ffmpeg_path),
            "needsVenv": not asr_venv_ok,
            "estimatedSizeMB": 145,
            "diskSizeBytes": dir_size_bytes(MODELS_DIR / "asr", force_refresh=force_refresh_size),
            "modelPath": str(asr_dir) if asr_dir else str(MODELS_DIR / "asr" / ASR_SUBDIR),
            "sourceUrl": "https://huggingface.co/Systran/faster-whisper-base",
        },
        "tts": {
            "id": "tts",
            "title": "中文神經網路 TTS (Sherpa-ONNX Kokoro INT8)",
            "engine": "Sherpa-ONNX Kokoro v1.0 Multi-Lang INT8",
            "license": "Apache-2.0 (bundles espeak-ng-data GPL-3.0)",
            "installed": tts_installed,
            "ready": tts_installed and tts_venv_ok,
            "needsVenv": not tts_venv_ok,
            "estimatedSizeMB": 132,
            "diskSizeBytes": dir_size_bytes(MODELS_DIR / "tts", force_refresh=force_refresh_size),
            "modelPath": kokoro_assets["root"] if kokoro_assets else str(MODELS_DIR / "tts" / KOKORO_SUBDIR),
            "sourceUrl": KOKORO_ARCHIVE_URL,
            "speakers": KOKORO_ZH_SPEAKERS,
        },
        "voice_clone": {
            "id": "voice_clone",
            "title": "零樣本聲音複製 (Sherpa-ONNX ZipVoice-Distill INT8)",
            "engine": "Sherpa-ONNX ZipVoice-Distill INT8 zh-en + Vocos 24kHz",
            "license": "Apache-2.0",
            "installed": vc_installed,
            "ready": vc_installed and vc_venv_ok and bool(ffmpeg_path),
            "needsVenv": not vc_venv_ok,
            "estimatedSizeMB": 160,
            "diskSizeBytes": dir_size_bytes(MODELS_DIR / "voice_clone", force_refresh=force_refresh_size),
            "modelPath": zipvoice_assets["root"] if zipvoice_assets else str(MODELS_DIR / "voice_clone" / ZIPVOICE_SUBDIR),
            "sourceUrl": ZIPVOICE_ARCHIVE_URL,
            "vocoderUrl": VOCOS_24KHZ_URL,
        },
    }

    total_installed = venv_info["diskSizeBytes"] + sum(m["diskSizeBytes"] for m in modules.values())
    return {
        "ok": True,
        "rootDir": str(AI_ROOT),
        "venvDir": str(VENV_DIR),
        "modelsDir": str(MODELS_DIR),
        "ffmpegPath": ffmpeg_path,
        "basePython": base_py,
        "venv": venv_info,
        "modules": modules,
        "totalEstimatedModelsMB": sum(m["estimatedSizeMB"] for m in modules.values()),
        "totalInstalledBytes": total_installed,
        "sizeIsEstimate": not force_refresh_size,
    }


# ---------------------------------------------------------------------------
# Atomic Download & Safe Archive Extraction
# ---------------------------------------------------------------------------

def _ssl_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    try:
        import certifi  # type: ignore
        ctx.load_verify_locations(certifi.where())
    except Exception:
        pass
    return ctx


def download_file_atomic(
    url: str,
    dest: Path,
    *,
    min_bytes: int = 1024,
    label: Optional[str] = None,
    timeout: int = 60,
) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    part_path = dest.parent / f".{dest.name}.part.{os.getpid()}"
    tag = label or dest.name
    log(f"Downloading {tag} from {url} ...")

    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "MotionDesk/0.2 (macOS arm64; Local Audio AI)",
            "Accept": "*/*",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_ssl_context()) as resp:
            total_hdr = resp.headers.get("Content-Length")
            total_bytes = int(total_hdr) if total_hdr and total_hdr.isdigit() else 0
            downloaded = 0
            last_pct = -1
            last_report = time.monotonic()

            with open(part_path, "wb") as out_f:
                while True:
                    chunk = resp.read(256 * 1024)
                    if not chunk:
                        break
                    out_f.write(chunk)
                    downloaded += len(chunk)
                    now = time.monotonic()
                    if total_bytes > 0:
                        pct = int(downloaded * 100 / total_bytes)
                        if pct >= last_pct + 5 or now - last_report >= 2.0:
                            last_pct = pct
                            last_report = now
                            log(
                                f"  {tag}: {pct}% "
                                f"({downloaded / (1024 * 1024):.1f} / {total_bytes / (1024 * 1024):.1f} MB)"
                            )
                    elif now - last_report >= 2.0:
                        last_report = now
                        log(f"  {tag}: {downloaded / (1024 * 1024):.1f} MB")

        if downloaded < min_bytes:
            raise RuntimeError(
                f"Downloaded file {tag} is unexpectedly small ({downloaded} bytes < {min_bytes})."
            )
        os.replace(str(part_path), str(dest))
        log(f"Completed {tag} ({downloaded / (1024 * 1024):.1f} MB)")
        return dest
    except Exception:
        if part_path.exists():
            try:
                part_path.unlink()
            except OSError:
                pass
        raise


def extract_tar_bz2_atomic(archive_path: Path, dest_parent: Path, expected_subdir: str) -> Path:
    dest_parent.mkdir(parents=True, exist_ok=True)
    tmp_dir = dest_parent / f".extracting.{expected_subdir}.{os.getpid()}"
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
    tmp_dir.mkdir(parents=True, exist_ok=True)
    log(f"Extracting {archive_path.name} ...")

    try:
        with tarfile.open(str(archive_path), "r:bz2") as tf:
            tmp_root = tmp_dir.resolve()
            for member in tf.getmembers():
                target = (tmp_root / member.name).resolve()
                if tmp_root != target and tmp_root not in target.parents:
                    raise RuntimeError(f"Unsafe archive path detected: {member.name}")
            tf.extractall(path=str(tmp_dir))

        extracted_sub = tmp_dir / expected_subdir
        if not extracted_sub.is_dir():
            # Fallback: find first top-level directory inside tmp_dir
            dirs = [p for p in tmp_dir.iterdir() if p.is_dir()]
            if len(dirs) == 1:
                extracted_sub = dirs[0]
            else:
                extracted_sub = tmp_dir

        final_dir = dest_parent / expected_subdir
        backup_dir = dest_parent / f".backup.{expected_subdir}.{os.getpid()}"
        if final_dir.exists():
            if backup_dir.exists():
                shutil.rmtree(backup_dir)
            os.replace(str(final_dir), str(backup_dir))
        try:
            os.replace(str(extracted_sub), str(final_dir))
        except Exception:
            if backup_dir.exists() and not final_dir.exists():
                os.replace(str(backup_dir), str(final_dir))
            raise
        if backup_dir.exists():
            shutil.rmtree(backup_dir, ignore_errors=True)
        return final_dir
    finally:
        if tmp_dir.exists():
            shutil.rmtree(tmp_dir, ignore_errors=True)


# ---------------------------------------------------------------------------
# Install & Uninstall Commands
# ---------------------------------------------------------------------------

def install_venv() -> Dict[str, Any]:
    existing = probe_venv_status()
    if existing["installed"]:
        log(f"Isolated venv already ready at {VENV_DIR} (Python {existing['pythonVersion']})")
        return existing

    base = detect_base_python()
    base_exe = base["path"]
    if not base_exe or not os.path.isfile(base_exe):
        raise RuntimeError("找不到可用的系統 Python 以建立隔離音訊 AI 環境。")
    if _is_inside_comfy_venv(base_exe):
        raise RuntimeError("安全防護：拒絕直接使用 ComfyUI .venv 建立環境。")

    AI_ROOT.mkdir(parents=True, exist_ok=True)
    log(f"Creating isolated venv at {VENV_DIR} using base Python {base_exe} ({base['version']}) ...")
    _run_subprocess([base_exe, "-m", "venv", "--clear", str(VENV_DIR)], check=True, capture=False)

    vpy = str(venv_python_path())
    log("Upgrading pip inside isolated venv ...")
    _run_subprocess([vpy, "-m", "pip", "install", "--upgrade", "pip", "wheel"], check=True, capture=False)

    log(f"Installing isolated CPU/ONNX audio AI packages (NO PyTorch): {', '.join(VENV_PACKAGES)} ...")
    _run_subprocess(
        [vpy, "-m", "pip", "install", "--no-cache-dir", *VENV_PACKAGES],
        check=True,
        capture=False,
    )
    return probe_venv_status()


def install_vocal_sep() -> None:
    install_venv()
    target_dir = MODELS_DIR / "vocal_sep"
    target_dir.mkdir(parents=True, exist_ok=True)

    primary = MDX_MODELS[MDX_PRIMARY_MODEL]
    primary_dest = target_dir / MDX_PRIMARY_MODEL
    if primary_dest.is_file() and primary_dest.stat().st_size >= primary["min_bytes"]:
        log(f"{MDX_PRIMARY_MODEL} already installed.")
        return

    try:
        download_file_atomic(
            primary["url"],
            primary_dest,
            min_bytes=primary["min_bytes"],
            label=MDX_PRIMARY_MODEL,
        )
    except Exception as primary_exc:
        log(f"Primary model download failed ({primary_exc}); trying fallback {MDX_FALLBACK_MODEL} ...")
        fallback = MDX_MODELS[MDX_FALLBACK_MODEL]
        fallback_dest = target_dir / MDX_FALLBACK_MODEL
        download_file_atomic(
            fallback["url"],
            fallback_dest,
            min_bytes=fallback["min_bytes"],
            label=MDX_FALLBACK_MODEL,
        )


def install_asr() -> None:
    install_venv()
    asr_parent = MODELS_DIR / "asr"
    asr_parent.mkdir(parents=True, exist_ok=True)
    final_dir = asr_parent / ASR_SUBDIR
    if final_dir.is_dir() and (final_dir / "model.bin").is_file():
        log(f"Faster-Whisper base already installed at {final_dir}.")
        return

    tmp_dir = asr_parent / f".downloading.{ASR_SUBDIR}.{os.getpid()}"
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
    tmp_dir.mkdir(parents=True, exist_ok=True)

    vpy = str(venv_python_path())
    dl_script = (
        "from faster_whisper import download_model; "
        f"p = download_model('base', output_dir={repr(str(tmp_dir))}); "
        "print('Downloaded ASR model to:', p)"
    )
    log("Downloading Systran/faster-whisper-base (~145 MB) into isolated model cache ...")
    env = os.environ.copy()
    env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
    try:
        _run_subprocess([vpy, "-c", dl_script], check=True, capture=False, env=env)
        if not (tmp_dir / "model.bin").is_file():
            raise RuntimeError("faster-whisper base download completed without model.bin")
        if final_dir.exists():
            shutil.rmtree(final_dir)
        os.replace(str(tmp_dir), str(final_dir))
    finally:
        if tmp_dir.exists():
            shutil.rmtree(tmp_dir, ignore_errors=True)


def install_tts() -> None:
    install_venv()
    if _find_kokoro_assets() is not None:
        log("Kokoro INT8 multi-lang v1.0 already installed.")
        return

    tts_dir = MODELS_DIR / "tts"
    tts_dir.mkdir(parents=True, exist_ok=True)
    archive = tts_dir / f".{KOKORO_SUBDIR}.tar.bz2"
    try:
        download_file_atomic(
            KOKORO_ARCHIVE_URL,
            archive,
            min_bytes=40 * 1024 * 1024,
            label=f"{KOKORO_SUBDIR}.tar.bz2",
        )
        extract_tar_bz2_atomic(archive, tts_dir, KOKORO_SUBDIR)
    finally:
        if archive.exists():
            try:
                archive.unlink()
            except OSError:
                pass
    if _find_kokoro_assets() is None:
        raise RuntimeError("Kokoro 模型解壓後缺少必要檔案（model.int8.onnx / voices.bin / tokens.txt）。")


def install_voice_clone() -> None:
    install_venv()
    if _find_zipvoice_assets() is not None:
        log("ZipVoice-Distill INT8 zh-en + Vocos 24kHz already installed.")
        return

    vc_dir = MODELS_DIR / "voice_clone"
    vc_dir.mkdir(parents=True, exist_ok=True)
    archive = vc_dir / f".{ZIPVOICE_SUBDIR}.tar.bz2"
    try:
        if not (vc_dir / ZIPVOICE_SUBDIR).is_dir():
            download_file_atomic(
                ZIPVOICE_ARCHIVE_URL,
                archive,
                min_bytes=20 * 1024 * 1024,
                label=f"{ZIPVOICE_SUBDIR}.tar.bz2",
            )
            extract_tar_bz2_atomic(archive, vc_dir, ZIPVOICE_SUBDIR)
    finally:
        if archive.exists():
            try:
                archive.unlink()
            except OSError:
                pass

    # Download Vocos 24kHz vocoder if not already included inside the tarball
    assets = _find_zipvoice_assets()
    if assets is None:
        vocoder_dest = vc_dir / "vocos_24khz.onnx"
        if not vocoder_dest.is_file() or vocoder_dest.stat().st_size < 10 * 1024 * 1024:
            download_file_atomic(
                VOCOS_24KHZ_URL,
                vocoder_dest,
                min_bytes=10 * 1024 * 1024,
                label="vocos_24khz.onnx",
            )

    if _find_zipvoice_assets() is None:
        raise RuntimeError(
            "ZipVoice 模型安裝後仍缺少必要檔案（encoder / decoder / vocos_24khz.onnx / tokens.txt）。"
        )


def cmd_install(module: str) -> None:
    dispatch = {
        "venv": install_venv,
        "vocal_sep": install_vocal_sep,
        "asr": install_asr,
        "tts": install_tts,
        "voice_clone": install_voice_clone,
    }
    if module not in dispatch:
        emit_error(f"不支援的安裝模組：{module}", module=module)
    try:
        dispatch[module]()
        invalidate_size_cache()
        status = collect_status(force_refresh_size=True)
        status["installedModule"] = module
        emit_json(status)
    except Exception as exc:
        emit_error(f"安裝 {module} 失敗：{exc}", module=module)


def cmd_uninstall(module: str) -> None:
    try:
        if module == "all":
            for target in (VENV_DIR, MODELS_DIR):
                if target.exists():
                    log(f"Removing {target} ...")
                    shutil.rmtree(target)
        elif module in ("vocal_sep", "asr", "tts", "voice_clone"):
            target = MODELS_DIR / module
            if target.exists():
                log(f"Removing {target} ...")
                shutil.rmtree(target)
        else:
            emit_error(f"不支援的移除模組：{module}", module=module)
            return

        invalidate_size_cache()
        status = collect_status(force_refresh_size=True)
        status["uninstalledModule"] = module
        emit_json(status)
    except Exception as exc:
        emit_error(f"移除 {module} 失敗：{exc}", module=module)


# ---------------------------------------------------------------------------
# Neural Inference 1: UVR MDX-Net Vocal / Accompaniment Separation (ONNX)
# ---------------------------------------------------------------------------

def _decode_audio_ffmpeg(
    input_path: Path,
    out_wav: Path,
    *,
    sample_rate: int,
    channels: int,
    codec: str = "pcm_f32le",
) -> None:
    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        raise RuntimeError("找不到 FFmpeg（預期 /opt/homebrew/bin/ffmpeg）。")
    _run_subprocess(
        [
            ffmpeg,
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(input_path),
            "-vn",
            "-ac",
            str(channels),
            "-ar",
            str(sample_rate),
            "-c:a",
            codec,
            str(out_wav),
        ],
        check=True,
        capture=True,
    )


def _mdx_stft_np(chunk: Any, n_fft: int, hop_length: int, dim_f: int, window: Any) -> Any:
    """
    Exact NumPy equivalent of PyTorch UVR MDX-Net STFT:
      torch.stft(..., n_fft=n_fft, hop_length=hop_length,
                 window=hann_window(n_fft, periodic=True),
                 center=True, pad_mode="reflect", normalized=False, onesided=True)
    Input:  chunk float32 (2, chunk_size)
    Output: spec  float32 (1, 4, dim_f, dim_t) ordered [L_real, L_imag, R_real, R_imag]
    """
    import numpy as np
    from numpy.lib.stride_tricks import sliding_window_view

    pad = n_fft // 2
    padded = np.pad(chunk, ((0, 0), (pad, pad)), mode="reflect")
    # sliding_window_view -> (2, num_positions, n_fft), slice by hop_length
    frames = sliding_window_view(padded, window_shape=n_fft, axis=-1)[:, ::hop_length, :]
    windowed = frames * window[None, None, :]
    # rfft over last axis -> (2, dim_t, n_bins), transpose -> (2, n_bins, dim_t)
    spec = np.fft.rfft(windowed, n=n_fft, axis=-1).transpose(0, 2, 1)
    spec = spec[:, :dim_f, :]

    out = np.empty((1, 4, dim_f, spec.shape[-1]), dtype=np.float32)
    out[0, 0] = spec[0].real
    out[0, 1] = spec[0].imag
    out[0, 2] = spec[1].real
    out[0, 3] = spec[1].imag
    return out


def _mdx_istft_np(spec: Any, n_fft: int, hop_length: int, chunk_size: int, window: Any) -> Any:
    """
    Exact NumPy equivalent of PyTorch UVR MDX-Net ISTFT (center=True, NOLA).
    Input:  spec float32 (1, 4, dim_f, dim_t)
    Output: wav  float32 (2, chunk_size)
    """
    import numpy as np

    n_bins = n_fft // 2 + 1
    dim_f = spec.shape[2]
    dim_t = spec.shape[3]
    pad = n_fft // 2

    full_complex = np.zeros((2, n_bins, dim_t), dtype=np.complex64)
    full_complex[0, :dim_f, :] = spec[0, 0] + 1j * spec[0, 1]
    full_complex[1, :dim_f, :] = spec[0, 2] + 1j * spec[0, 3]

    # irfft over frequency axis -> (2, dim_t, n_fft)
    frames = np.fft.irfft(full_complex.transpose(0, 2, 1), n=n_fft, axis=-1).astype(np.float32)
    frames *= window[None, None, :]

    out_len = (dim_t - 1) * hop_length + n_fft
    wav_buf = np.zeros((2, out_len), dtype=np.float32)
    win_sq = (window * window).astype(np.float32)
    win_buf = np.zeros((out_len,), dtype=np.float32)

    for t in range(dim_t):
        pos = t * hop_length
        wav_buf[:, pos : pos + n_fft] += frames[:, t, :]
        win_buf[pos : pos + n_fft] += win_sq

    wav_buf /= np.maximum(win_buf[None, :], 1e-8)
    return wav_buf[:, pad : pad + chunk_size]


def _rms_db(wav: Any) -> float:
    import numpy as np

    rms = float(np.sqrt(np.mean(np.square(wav, dtype=np.float64))))
    if rms <= 1e-12:
        return -120.0
    return round(20.0 * math.log10(rms), 3)


def _compute_separation_metrics(vocals: Any, accompaniment: Any, sr: int) -> Dict[str, Any]:
    import numpy as np

    v_mono = np.mean(vocals, axis=0)
    a_mono = np.mean(accompaniment, axis=0)
    n_fft = 2048
    hop = 512
    win = np.hanning(n_fft + 1)[:-1].astype(np.float32)

    def _mean_mag_spec(sig: Any) -> Any:
        if len(sig) < n_fft:
            sig = np.pad(sig, (0, n_fft - len(sig)))
        from numpy.lib.stride_tricks import sliding_window_view
        frames = sliding_window_view(sig, n_fft)[::hop] * win[None, :]
        mag = np.abs(np.fft.rfft(frames, axis=-1))
        return np.mean(mag, axis=0)

    v_spec = _mean_mag_spec(v_mono)
    a_spec = _mean_mag_spec(a_mono)

    v_log = np.log1p(v_spec)
    a_log = np.log1p(a_spec)
    v_centered = v_log - np.mean(v_log)
    a_centered = a_log - np.mean(a_log)
    denom = float(np.linalg.norm(v_centered) * np.linalg.norm(a_centered))
    corr = float(np.dot(v_centered, a_centered) / denom) if denom > 1e-12 else 0.0

    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sr)

    def _band_ratios(spec: Any) -> Dict[str, float]:
        power = spec * spec
        total = float(np.sum(power)) + 1e-12
        low = float(np.sum(power[freqs < 300.0])) / total
        mid = float(np.sum(power[(freqs >= 300.0) & (freqs <= 3400.0)])) / total
        high = float(np.sum(power[freqs > 3400.0])) / total
        return {
            "lowLt300Hz": round(low, 4),
            "midVocal300To3400Hz": round(mid, 4),
            "highGt3400Hz": round(high, 4),
        }

    return {
        "vocalRmsDb": _rms_db(vocals),
        "accompanimentRmsDb": _rms_db(accompaniment),
        "spectralCorrelation": round(corr, 4),
        "bandEnergy": {
            "vocals": _band_ratios(v_spec),
            "accompaniment": _band_ratios(a_spec),
        },
    }


def _unique_output_path(directory: Path, stem: str, ext: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    clean_ext = ext if ext.startswith(".") else f".{ext}"
    candidate = directory / f"{stem}{clean_ext}"
    if not candidate.exists():
        return candidate
    for idx in range(2, 10000):
        candidate = directory / f"{stem}-{idx}{clean_ext}"
        if not candidate.exists():
            return candidate
    return directory / f"{stem}-{int(time.time())}{clean_ext}"


def cmd_separate(
    input_path_str: str,
    output_dir_str: str,
    vocals_output_str: Optional[str] = None,
    accompaniment_output_str: Optional[str] = None,
) -> None:
    ensure_venv_reexec("vocal_sep")
    model_path, model_name = _find_vocal_sep_model()
    if not model_path or not model_name:
        emit_error(
            "尚未安裝人聲分離模型 (UVR-MDX-NET-Inst_HQ_3.onnx)。請先執行 install --module vocal_sep。",
            module="vocal_sep",
            needs_install=True,
        )
        return

    input_path = Path(input_path_str).expanduser().resolve()
    if not input_path.is_file():
        emit_error(f"找不到輸入音訊／影片檔案：{input_path}", module="vocal_sep")
        return

    output_dir = Path(output_dir_str).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    spec_cfg = MDX_MODELS[model_name]
    n_fft = int(spec_cfg["n_fft"])
    hop_length = int(spec_cfg["hop_length"])
    dim_f = int(spec_cfg["dim_f"])
    dim_t = int(spec_cfg["dim_t"])
    compensate = float(spec_cfg["compensate"])
    primary_stem = str(spec_cfg["primary_stem"])
    sr = 44100

    with contextlib.redirect_stdout(sys.stderr):
        import numpy as np
        import onnxruntime as ort
        import soundfile as sf

        with tempfile.TemporaryDirectory(prefix="md_vocal_sep_") as td:
            decoded_wav = Path(td) / "mix_44k.wav"
            log(f"Decoding {input_path.name} to 44.1kHz stereo float32 WAV ...")
            _decode_audio_ffmpeg(input_path, decoded_wav, sample_rate=sr, channels=2)
            mix_hw, read_sr = sf.read(str(decoded_wav), dtype="float32", always_2d=True)
            if read_sr != sr:
                raise RuntimeError(f"Expected 44100 Hz audio, got {read_sr}")
            # Shape -> (2, num_samples)
            mix = mix_hw.T.copy()

        num_samples = mix.shape[1]
        if num_samples == 0:
            raise RuntimeError("輸入檔案沒有可讀取的音訊取樣。")

        sess_opts = ort.SessionOptions()
        sess_opts.intra_op_num_threads = min(4, os.cpu_count() or 4)
        sess_opts.log_severity_level = 3
        available = ort.get_available_providers()
        providers = ["CPUExecutionProvider"]
        if "CoreMLExecutionProvider" in available and os.environ.get("MOTIONDESK_USE_COREML") == "1":
            providers = ["CoreMLExecutionProvider", "CPUExecutionProvider"]

        log(f"Loading ONNX MDX-Net model {model_name} (providers={providers}) ...")
        session = ort.InferenceSession(str(model_path), sess_options=sess_opts, providers=providers)
        input_info = session.get_inputs()[0]
        input_name = input_info.name
        # Verify dim_f / dim_t from ONNX metadata if static
        if len(input_info.shape) == 4:
            if isinstance(input_info.shape[2], int) and input_info.shape[2] > 0:
                dim_f = int(input_info.shape[2])
            if isinstance(input_info.shape[3], int) and input_info.shape[3] > 0:
                dim_t = int(input_info.shape[3])

        chunk_size = hop_length * (dim_t - 1)
        overlap = chunk_size // 4
        step = chunk_size - overlap
        window = np.hanning(n_fft + 1)[:-1].astype(np.float32)

        # Pad left & right so every sample is covered cleanly with crossfade overlap
        pad_left = overlap
        min_total = pad_left + num_samples + overlap
        n_chunks = max(1, math.ceil((min_total - chunk_size) / step) + 1)
        padded_len = (n_chunks - 1) * step + chunk_size
        pad_right = padded_len - pad_left - num_samples

        padded_mix = np.pad(mix, ((0, 0), (pad_left, pad_right)), mode="constant")
        accum = np.zeros_like(padded_mix, dtype=np.float32)
        weight_accum = np.zeros((padded_len,), dtype=np.float32)

        # Smooth raised-cosine fade in/out mask for overlap-add chunk stitching
        fade = np.linspace(0.0, 1.0, overlap, dtype=np.float32)
        fade = 0.5 - 0.5 * np.cos(math.pi * fade)
        chunk_weight = np.ones((chunk_size,), dtype=np.float32)
        chunk_weight[:overlap] = fade
        chunk_weight[-overlap:] = fade[::-1]

        log(f"Running MDX-Net separation across {n_chunks} chunk(s) ({num_samples / sr:.2f}s) ...")
        for idx in range(n_chunks):
            start = idx * step
            chunk = padded_mix[:, start : start + chunk_size]
            spec = _mdx_stft_np(chunk, n_fft, hop_length, dim_f, window)
            pred_spec = session.run(None, {input_name: spec})[0]
            pred_chunk = _mdx_istft_np(pred_spec, n_fft, hop_length, chunk_size, window)

            accum[:, start : start + chunk_size] += pred_chunk * chunk_weight[None, :]
            weight_accum[start : start + chunk_size] += chunk_weight
            log(f"  chunk {idx + 1}/{n_chunks} complete")

        pred_full = accum / np.maximum(weight_accum[None, :], 1e-8)
        pred_wave = pred_full[:, pad_left : pad_left + num_samples] * compensate

        if primary_stem == "instrumental":
            accompaniment = pred_wave
            vocals = mix - accompaniment
        else:
            vocals = pred_wave
            accompaniment = mix - vocals

        # Prevent hard digital clipping while preserving relative level
        peak = max(float(np.max(np.abs(vocals))), float(np.max(np.abs(accompaniment))), 1.0)
        if peak > 1.0:
            vocals = vocals / peak
            accompaniment = accompaniment / peak

        if vocals_output_str:
            vocals_path = Path(vocals_output_str).expanduser().resolve()
            vocals_path.parent.mkdir(parents=True, exist_ok=True)
        else:
            vocals_path = output_dir / "vocals.wav"
        if accompaniment_output_str:
            accompaniment_path = Path(accompaniment_output_str).expanduser().resolve()
            accompaniment_path.parent.mkdir(parents=True, exist_ok=True)
        else:
            accompaniment_path = output_dir / "accompaniment.wav"
        sf.write(str(vocals_path), vocals.T, sr, subtype="PCM_16")
        sf.write(str(accompaniment_path), accompaniment.T, sr, subtype="PCM_16")

        metrics = _compute_separation_metrics(vocals, accompaniment, sr)

    emit_json(
        {
            "ok": True,
            "module": "vocal_sep",
            "model": model_name,
            "primaryStem": primary_stem,
            "sampleRate": sr,
            "duration": round(num_samples / sr, 4),
            "vocalsPath": str(vocals_path),
            "accompanimentPath": str(accompaniment_path),
            **metrics,
        }
    )


# ---------------------------------------------------------------------------
# Neural Inference 2: Faster-Whisper Base INT8 ASR
# ---------------------------------------------------------------------------

def _format_srt_timestamp(seconds: float) -> str:
    ms_total = max(0, int(round(seconds * 1000.0)))
    hours = ms_total // 3_600_000
    ms_total %= 3_600_000
    minutes = ms_total // 60_000
    ms_total %= 60_000
    secs = ms_total // 1000
    millis = ms_total % 1000
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}"


def _write_srt(segments: List[Dict[str, Any]], srt_path: Path) -> None:
    lines: List[str] = []
    for idx, seg in enumerate(segments, start=1):
        lines.append(str(idx))
        lines.append(f"{_format_srt_timestamp(seg['start'])} --> {_format_srt_timestamp(seg['end'])}")
        lines.append(seg["text"])
        lines.append("")
    srt_path.write_text("\n".join(lines), encoding="utf-8")


def _build_asr_prompt(language: Optional[str], initial_prompt: Optional[str]) -> Optional[str]:
    user_hint = (initial_prompt or "").strip()
    is_zh = bool(language and language.lower().startswith("zh"))
    if is_zh:
        if user_hint:
            return f"{DEFAULT_ZH_PROMPT}專有名詞與關鍵字：{user_hint}。"
        return DEFAULT_ZH_PROMPT
    return user_hint or None


def _run_faster_whisper(
    input_path: Path,
    *,
    language: Optional[str] = "zh",
    initial_prompt: Optional[str] = None,
) -> Tuple[List[Dict[str, Any]], str, float, float, str, Optional[str]]:
    asr_dir = _find_asr_model_dir()
    if not asr_dir:
        raise RuntimeError("ASR_NOT_INSTALLED")

    from faster_whisper import WhisperModel  # type: ignore

    effective_prompt = _build_asr_prompt(language, initial_prompt)
    model_label = f"Systran/{asr_dir.name} (INT8)"

    with tempfile.TemporaryDirectory(prefix="md_asr_") as td:
        wav_16k = Path(td) / "input_16k.wav"
        _decode_audio_ffmpeg(input_path, wav_16k, sample_rate=16000, channels=1, codec="pcm_s16le")
        import numpy as np
        import soundfile as sf

        audio_np, _sr = sf.read(str(wav_16k), dtype="float32", always_2d=False)
        if getattr(audio_np, "ndim", 1) > 1:
            audio_np = audio_np.mean(axis=1)
        audio_np = np.ascontiguousarray(audio_np, dtype=np.float32)

        threads = min(4, os.cpu_count() or 4)
        log(f"Loading {model_label} ({asr_dir}, threads={threads}) ...")
        model = WhisperModel(
            str(asr_dir),
            device="cpu",
            compute_type="int8",
            cpu_threads=threads,
            local_files_only=True,
        )

        lang_arg = None if (not language or language.lower() == "auto") else language

        def _do_transcribe(use_vad: bool) -> Tuple[List[Dict[str, Any]], Any]:
            seg_iter, info = model.transcribe(
                audio_np,
                language=lang_arg,
                initial_prompt=effective_prompt,
                beam_size=5,
                best_of=5,
                temperature=0.0,
                vad_filter=use_vad,
                condition_on_previous_text=True,
            )
            collected: List[Dict[str, Any]] = []
            for seg in seg_iter:
                txt = (seg.text or "").strip()
                if not txt:
                    continue
                collected.append(
                    {
                        "start": round(float(seg.start), 3),
                        "end": round(float(seg.end), 3),
                        "text": txt,
                    }
                )
            return collected, info

        segments, info = _do_transcribe(use_vad=True)
        if not segments:
            log("VAD yielded 0 segments; retrying without VAD filter ...")
            segments, info = _do_transcribe(use_vad=False)

        detected_lang = str(getattr(info, "language", lang_arg or "zh"))
        lang_prob = round(float(getattr(info, "language_probability", 1.0)), 4)
        duration = round(float(getattr(info, "duration", 0.0)), 4)
        return segments, detected_lang, lang_prob, duration, model_label, effective_prompt


def cmd_asr(
    input_path_str: str,
    output_dir_str: str,
    language: str,
    initial_prompt: Optional[str],
    output_srt_str: Optional[str] = None,
) -> None:
    ensure_venv_reexec("asr")
    if _find_asr_model_dir() is None:
        emit_error(
            "尚未安裝自動字幕 ASR 模型 (Faster-Whisper INT8)。請先執行 install --module asr。",
            module="asr",
            needs_install=True,
        )
        return

    input_path = Path(input_path_str).expanduser().resolve()
    if not input_path.is_file():
        emit_error(f"找不到輸入音訊／影片檔案：{input_path}", module="asr")
        return

    output_dir = Path(output_dir_str).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    if output_srt_str:
        srt_path = Path(output_srt_str).expanduser().resolve()
        srt_path.parent.mkdir(parents=True, exist_ok=True)
    else:
        srt_path = output_dir / f"{input_path.stem}.srt"

    with contextlib.redirect_stdout(sys.stderr):
        segments, detected_lang, lang_prob, duration, model_label, prompt_used = _run_faster_whisper(
            input_path,
            language=language,
            initial_prompt=initial_prompt,
        )
        _write_srt(segments, srt_path)

    emit_json(
        {
            "ok": True,
            "module": "asr",
            "model": model_label,
            "promptUsed": prompt_used,
            "segments": segments,
            "segmentCount": len(segments),
            "srtPath": str(srt_path),
            "language": detected_lang,
            "languageProbability": lang_prob,
            "duration": duration,
        }
    )


# ---------------------------------------------------------------------------
# Neural Inference 3: Sherpa-ONNX Kokoro INT8 Chinese/Multilingual TTS
# ---------------------------------------------------------------------------

def _set_if_exists(obj: Any, values: Dict[str, Any]) -> None:
    for k, v in values.items():
        if v is None:
            continue
        if hasattr(obj, k):
            setattr(obj, k, v)


def _speaker_lookup(sid: int) -> Dict[str, Any]:
    for sp in KOKORO_ZH_SPEAKERS:
        if sp["id"] == sid:
            return sp
    return {"id": sid, "code": f"speaker_{sid}", "name": f"說話人 #{sid}", "gender": "unknown", "language": "multi"}


def cmd_tts(text: str, output_str: str, speaker: int, speed: float) -> None:
    ensure_venv_reexec("tts")
    assets = _find_kokoro_assets()
    if assets is None:
        emit_error(
            "尚未安裝中文 TTS 模型 (Sherpa-ONNX Kokoro INT8)。請先執行 install --module tts。",
            module="tts",
            needs_install=True,
        )
        return

    clean_text = text.strip()
    if not clean_text:
        emit_error("請輸入要合成語音的文字內容。", module="tts")
        return

    output_path = Path(output_str).expanduser().resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with contextlib.redirect_stdout(sys.stderr):
        import numpy as np
        import sherpa_onnx  # type: ignore
        import soundfile as sf

        kokoro_cfg = sherpa_onnx.OfflineTtsKokoroModelConfig()
        _set_if_exists(
            kokoro_cfg,
            {
                "model": assets["model"],
                "voices": assets["voices"],
                "tokens": assets["tokens"],
                "data_dir": assets["data_dir"],
                "dict_dir": assets["dict_dir"],
                "lexicon": assets["lexicon"],
                "length_scale": 1.0,
            },
        )

        model_cfg = sherpa_onnx.OfflineTtsModelConfig()
        _set_if_exists(
            model_cfg,
            {
                "kokoro": kokoro_cfg,
                "num_threads": min(4, os.cpu_count() or 4),
                "debug": False,
                "provider": "cpu",
            },
        )

        tts_cfg = sherpa_onnx.OfflineTtsConfig()
        _set_if_exists(
            tts_cfg,
            {
                "model": model_cfg,
                "rule_fsts": assets["rule_fsts"],
                "max_num_sentences": 1,
            },
        )
        if hasattr(tts_cfg, "validate") and not tts_cfg.validate():
            raise RuntimeError(f"OfflineTtsConfig 驗證失敗：{assets}")

        log(f"Synthesizing Kokoro INT8 TTS (sid={speaker}, speed={speed}) ...")
        tts = sherpa_onnx.OfflineTts(tts_cfg)
        try:
            audio = tts.generate(clean_text, sid=int(speaker), speed=float(speed))
        except TypeError:
            if hasattr(sherpa_onnx, "GenerationConfig"):
                gen_cfg = sherpa_onnx.GenerationConfig()
                _set_if_exists(gen_cfg, {"sid": int(speaker), "speed": float(speed)})
                audio = tts.generate(clean_text, gen_cfg)
            else:
                raise

        samples = np.asarray(audio.samples, dtype=np.float32)
        if samples.size == 0:
            raise RuntimeError("Kokoro TTS 輸出音訊為空。")
        sr = int(audio.sample_rate)
        sf.write(str(output_path), samples, sr, subtype="PCM_16")
        duration = round(float(samples.size) / float(sr), 4)

    sp_meta = _speaker_lookup(int(speaker))
    emit_json(
        {
            "ok": True,
            "module": "tts",
            "model": KOKORO_SUBDIR,
            "path": str(output_path),
            "duration": duration,
            "sampleRate": sr,
            "speaker": int(speaker),
            "speakerName": sp_meta["code"],
            "speakerLabel": sp_meta["name"],
            "speed": float(speed),
        }
    )


# ---------------------------------------------------------------------------
# Neural Inference 4: Sherpa-ONNX ZipVoice-Distill INT8 Zero-Shot Voice Clone
# ---------------------------------------------------------------------------

def cmd_voice_clone(
    ref_audio_str: str,
    text: str,
    output_str: str,
    ref_text: str,
    speed: float,
    num_steps: int,
) -> None:
    ensure_venv_reexec("voice_clone")
    assets = _find_zipvoice_assets()
    if assets is None:
        emit_error(
            "尚未安裝零樣本聲音複製模型 (Sherpa-ONNX ZipVoice-Distill INT8)。請先執行 install --module voice_clone。",
            module="voice_clone",
            needs_install=True,
        )
        return

    ref_audio = Path(ref_audio_str).expanduser().resolve()
    if not ref_audio.is_file():
        emit_error(f"找不到參考音訊檔案：{ref_audio}", module="voice_clone")
        return

    target_text = text.strip()
    if not target_text:
        emit_error("請輸入要以複製聲線合成的目標文字。", module="voice_clone")
        return

    output_path = Path(output_str).expanduser().resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    ref_text_clean = ref_text.strip()
    auto_transcribed = False

    with contextlib.redirect_stdout(sys.stderr):
        import numpy as np
        import sherpa_onnx  # type: ignore
        import soundfile as sf

        with tempfile.TemporaryDirectory(prefix="md_voice_clone_") as td:
            ref_24k = Path(td) / "ref_24k.wav"
            log(f"Resampling reference audio {ref_audio.name} to 24kHz mono WAV ...")
            _decode_audio_ffmpeg(ref_audio, ref_24k, sample_rate=24000, channels=1, codec="pcm_s16le")

            if not ref_text_clean:
                if _find_asr_model_dir() is not None:
                    log("Reference text empty; auto-transcribing reference audio via Faster-Whisper ...")
                    segs, _lang, _prob, _dur, _mdl, _pmt = _run_faster_whisper(
                        ref_24k,
                        language="zh",
                        initial_prompt="",
                    )
                    ref_text_clean = "".join(s["text"] for s in segs).strip()
                    auto_transcribed = True
                    log(f"Auto-transcribed ref_text: {ref_text_clean}")

            if not ref_text_clean:
                raise RuntimeError(
                    "ZipVoice 聲音複製需要參考音訊的逐字稿 (--ref-text)，"
                    "或請先安裝自動字幕 (ASR) 模組以自動辨識參考音訊。"
                )

            ref_samples, ref_sr = sf.read(str(ref_24k), dtype="float32")
            if ref_samples.ndim > 1:
                ref_samples = np.mean(ref_samples, axis=1).astype(np.float32)
            # Keep up to 15 seconds for stable flow-matching conditioning
            max_ref_samples = int(15 * ref_sr)
            if ref_samples.size > max_ref_samples:
                ref_samples = ref_samples[:max_ref_samples]
            if ref_samples.size < int(0.3 * ref_sr):
                raise RuntimeError("參考音訊過短（需至少 0.3 秒有效人聲）。")

            zv_cfg = sherpa_onnx.OfflineTtsZipvoiceModelConfig()
            _set_if_exists(
                zv_cfg,
                {
                    "tokens": assets["tokens"],
                    "encoder": assets["encoder"],
                    "decoder": assets["decoder"],
                    "vocoder": assets["vocoder"],
                    "lexicon": assets["lexicon"],
                    "pinyin_dict": assets["pinyin_dict"],
                    "data_dir": assets["data_dir"],
                    "feat_scale": 0.1,
                    "t_shift": 0.5,
                    "target_rms": 0.1,
                    "guidance_scale": 1.0,
                },
            )

            model_cfg = sherpa_onnx.OfflineTtsModelConfig()
            _set_if_exists(
                model_cfg,
                {
                    "zipvoice": zv_cfg,
                    "num_threads": min(4, os.cpu_count() or 4),
                    "debug": False,
                    "provider": "cpu",
                },
            )

            tts_cfg = sherpa_onnx.OfflineTtsConfig()
            _set_if_exists(tts_cfg, {"model": model_cfg, "max_num_sentences": 1})
            if hasattr(tts_cfg, "validate") and not tts_cfg.validate():
                raise RuntimeError(f"ZipVoice OfflineTtsConfig 驗證失敗：{assets}")

            log(f"Running ZipVoice-Distill INT8 voice clone (steps={num_steps}, speed={speed}) ...")
            tts = sherpa_onnx.OfflineTts(tts_cfg)

            audio = None
            if hasattr(sherpa_onnx, "GenerationConfig"):
                gen_cfg = sherpa_onnx.GenerationConfig()
                _set_if_exists(
                    gen_cfg,
                    {
                        "speed": float(speed),
                        "num_steps": int(num_steps),
                        "reference_audio": ref_samples.tolist(),
                        "reference_sample_rate": int(ref_sr),
                        "reference_text": ref_text_clean,
                    },
                )
                try:
                    audio = tts.generate(target_text, gen_cfg)
                except TypeError:
                    try:
                        audio = tts.generate(target_text, config=gen_cfg)
                    except TypeError:
                        if hasattr(tts, "generate_with_config"):
                            audio = tts.generate_with_config(target_text, gen_cfg)
                        else:
                            raise
            else:
                audio = tts.generate(
                    target_text,
                    reference_audio=ref_samples.tolist(),
                    reference_sample_rate=int(ref_sr),
                    reference_text=ref_text_clean,
                    num_steps=int(num_steps),
                    speed=float(speed),
                )

            samples = np.asarray(audio.samples, dtype=np.float32)
            if samples.size == 0:
                raise RuntimeError("ZipVoice 聲音複製輸出音訊為空。")
            sr = int(audio.sample_rate)
            sf.write(str(output_path), samples, sr, subtype="PCM_16")
            duration = round(float(samples.size) / float(sr), 4)

    emit_json(
        {
            "ok": True,
            "module": "voice_clone",
            "model": ZIPVOICE_SUBDIR,
            "path": str(output_path),
            "duration": duration,
            "sampleRate": sr,
            "refTextUsed": ref_text_clean,
            "refTextAutoTranscribed": auto_transcribed,
            "numSteps": int(num_steps),
            "speed": float(speed),
        }
    )


# ---------------------------------------------------------------------------
# CLI Entrypoint
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="audio_ai.py",
        description="MotionDesk V4 Local Neural Audio AI Engine",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_stat = sub.add_parser("status", help="Inspect isolated venv and 4 neural audio AI modules.")
    p_stat.add_argument(
        "--refresh-sizes",
        action="store_true",
        help="Force full disk size recalculation instead of using signature-validated metadata cache.",
    )

    p_inst = sub.add_parser("install", help="Install isolated venv or a specific audio AI module.")
    p_inst.add_argument(
        "--module",
        required=True,
        choices=["venv", "vocal_sep", "asr", "tts", "voice_clone"],
    )

    p_uninst = sub.add_parser("uninstall", help="Remove a specific audio AI module or entire isolated env.")
    p_uninst.add_argument(
        "--module",
        required=True,
        choices=["vocal_sep", "asr", "tts", "voice_clone", "all"],
    )

    p_sep = sub.add_parser("separate", help="Separate vocals and accompaniment via UVR MDX-Net ONNX.")
    p_sep.add_argument("--input", required=True, help="Input audio or video file path.")
    p_sep.add_argument("--output-dir", required=True, help="Directory to write vocals.wav and accompaniment.wav.")
    p_sep.add_argument("--vocals-output", default=None, help="Optional explicit output path for vocals WAV.")
    p_sep.add_argument("--accompaniment-output", default=None, help="Optional explicit output path for accompaniment WAV.")

    p_asr = sub.add_parser("asr", help="Transcribe speech to timestamped segments + SRT via Faster-Whisper.")
    p_asr.add_argument("--input", required=True, help="Input audio or video file path.")
    p_asr.add_argument("--output-dir", required=True, help="Directory to write <stem>.srt.")
    p_asr.add_argument("--output-srt", default=None, help="Optional explicit output path for SRT.")
    p_asr.add_argument("--language", default="zh", help="Language code (default: zh, or auto).")
    p_asr.add_argument("--initial-prompt", default=None, help="Optional Whisper initial prompt.")

    p_tts = sub.add_parser("tts", help="Synthesize Chinese/multilingual speech via Sherpa-ONNX Kokoro INT8.")
    p_tts.add_argument("--text", required=True, help="Input text to synthesize.")
    p_tts.add_argument("--output", required=True, help="Output WAV file path.")
    p_tts.add_argument("--speaker", type=int, default=45, help="Kokoro speaker ID (45-52 Chinese, default 45 zf_xiaobei).")
    p_tts.add_argument("--speed", type=float, default=1.0, help="Speech rate multiplier (default 1.0).")

    p_vc = sub.add_parser("voice-clone", help="Zero-shot voice cloning via Sherpa-ONNX ZipVoice-Distill INT8.")
    p_vc.add_argument("--ref-audio", required=True, help="Reference voice audio/video file.")
    p_vc.add_argument("--text", required=True, help="Target text to synthesize in cloned voice.")
    p_vc.add_argument("--output", required=True, help="Output WAV file path.")
    p_vc.add_argument("--ref-text", default="", help="Reference transcript (auto-transcribed if ASR installed).")
    p_vc.add_argument("--speed", type=float, default=1.0, help="Speech rate multiplier (default 1.0).")
    p_vc.add_argument("--num-steps", type=int, default=4, help="Flow matching steps (default 4).")

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.command == "status":
            emit_json(collect_status(force_refresh_size=bool(getattr(args, "refresh_sizes", False))))
        elif args.command == "install":
            cmd_install(args.module)
        elif args.command == "uninstall":
            cmd_uninstall(args.module)
        elif args.command == "separate":
            cmd_separate(args.input, args.output_dir, args.vocals_output, args.accompaniment_output)
        elif args.command == "asr":
            cmd_asr(args.input, args.output_dir, args.language, args.initial_prompt, args.output_srt)
        elif args.command == "tts":
            cmd_tts(args.text, args.output, args.speaker, args.speed)
        elif args.command == "voice-clone":
            cmd_voice_clone(
                args.ref_audio,
                args.text,
                args.output,
                args.ref_text,
                args.speed,
                args.num_steps,
            )
        else:
            emit_error(f"未知指令：{args.command}")
    except SystemExit:
        raise
    except Exception as exc:
        emit_error(str(exc), module=getattr(args, "module", args.command))


if __name__ == "__main__":
    main()
