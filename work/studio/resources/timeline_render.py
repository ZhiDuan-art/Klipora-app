"""Multi-track timeline renderer and SRT utilities for MotionDesk 0.2.

Pure Python 3 standard library module (Python 3.9+ compatible).
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any, Callable, Optional
from uuid import uuid4

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff", ".heic", ".bmp"}
VIDEO_EXT = {".mp4", ".mov", ".m4v", ".webm", ".mkv"}
AUDIO_EXT = {".mp3", ".wav", ".m4a", ".aac", ".flac"}

ASPECT_DIMENSIONS: dict[str, tuple[int, int]] = {
    "16:9": (1920, 1080),
    "9:16": (1080, 1920),
    "1:1": (1080, 1080),
}

TIMELINE_EFFECTS: dict[str, str] = {
    "dissolve": "fade",
    "fadeblack": "fadeblack",
    "fadewhite": "fadewhite",
    "wipeleft": "wipeleft",
    "wiperight": "wiperight",
    "wipeup": "wipeup",
    "wipedown": "wipedown",
    "slideleft": "slideleft",
    "slideright": "slideright",
    "circleopen": "circleopen",
    "circleclose": "circleclose",
    "pixelize": "pixelize",
    "smoothleft": "smoothleft",
    "zoomin": "zoomin",
}

FILTER_PRESETS: dict[str, str] = {
    "none": "",
    "warm_film": "eq=contrast=1.08:saturation=1.18:brightness=0.02,colorbalance=rs=0.06:gs=0.02:bs=-0.06",
    "cool_cinema": "eq=contrast=1.12:saturation=0.92,colorbalance=rs=-0.06:gs=0.01:bs=0.08",
    "bw_high": "hue=s=0,eq=contrast=1.25:brightness=0.02",
    "vintage": "eq=contrast=0.92:saturation=0.72:brightness=0.03,colorbalance=rs=0.08:gs=0.04:bs=-0.08,vignette=PI/4",
    "vivid": "eq=contrast=1.12:saturation=1.42",
    "soft_blur": "gblur=sigma=3.5",
    "vignette": "vignette=PI/3.5",
}

CLIP_ANIMATIONS: set[str] = {"none", "fade", "slide_left", "slide_up", "zoom"}

_DEFAULT_VISUAL_EFFECTS: dict[str, str] = {
    "none": "",
    "rgb_split": "format=rgba,rgbashift=rh=-8:bv=6:bh=8",
    "vhs_scan": "format=rgb24,noise=alls=14:allf=t+u,eq=contrast=1.08:saturation=0.82,colorbalance=rs=0.05:bs=-0.04,geq=r='if(mod(Y,4),r(X,Y),r(X,Y)*0.72)':g='if(mod(Y,4),g(X,Y),g(X,Y)*0.72)':b='if(mod(Y,4),b(X,Y),b(X,Y)*0.75)'",
    "glitch_shift": "format=rgb24,geq=r='r(mod(X+if(lt(mod(Y+floor(N*17),64),8),14,0),W),Y)':g='g(X,Y)':b='b(mod(X-if(lt(mod(Y+floor(N*23),52),6),12,0),W),Y)'",
    "pixelate": "scale=max(2\\,trunc(iw/10)):max(2\\,trunc(ih/10)):flags=neighbor,scale={W}:{H}:flags=neighbor",
    "sharpen_detail": "unsharp=5:5:1.5:5:5:0.4",
    "edge_glow": "edgedetect=low=0.08:high=0.28:mode=colormix,eq=saturation=1.8:contrast=1.25",
    "posterize": "format=rgb24,lutrgb=r='trunc(val/48)*48':g='trunc(val/48)*48':b='trunc(val/48)*48'",
    "mirror_split": "split[{p}_a][{p}_b];[{p}_a]crop=trunc(iw/2):ih:0:0[{p}_l];[{p}_b]crop=trunc(iw/2):ih:0:0,hflip[{p}_r];[{p}_l][{p}_r]hstack=inputs=2",
    "film_grain": "noise=alls=18:allf=t+u,eq=contrast=1.06:saturation=0.92",
    "cinematic_teal_orange": "colorbalance=rs=-0.12:gs=0.04:bs=0.14:rm=0.04:gm=-0.02:bm=-0.06:rh=0.16:gh=0.05:bh=-0.14,eq=contrast=1.10:saturation=1.12",
    "matte_fade": "curves=all='0/0.11 0.25/0.28 0.75/0.77 1/0.91',eq=saturation=0.86",
    "noir_cinema": "hue=s=0,curves=all='0/0 0.2/0.09 0.5/0.5 0.8/0.91 1/1',vignette=PI/4",
    "sepia_warm": "colorchannelmixer=.393:.769:.189:0:.349:.686:.168:0:.272:.534:.131:0,eq=contrast=1.04",
    "negative": "negate",
    "thermal": "format=yuv420p,pseudocolor=preset=heat",
    "emboss": "format=gbrp,convolution=0m='-2 -1 0 -1 1 1 0 1 2':1m='-2 -1 0 -1 1 1 0 1 2':2m='-2 -1 0 -1 1 1 0 1 2':0bias=128:1bias=128:2bias=128",
    "bloom_soft": "format=rgb24,split[{p}_b0][{p}_b1];[{p}_b1]gblur=sigma=12,eq=brightness=0.08:contrast=1.2[{p}_b2];[{p}_b0][{p}_b2]blend=all_mode=screen:all_opacity=0.45",
    "kaleido": "split=4[{p}_k1][{p}_k2][{p}_k3][{p}_k4];[{p}_k1]crop=trunc(iw/2):trunc(ih/2):0:0[{p}_tl];[{p}_k2]crop=trunc(iw/2):trunc(ih/2):0:0,hflip[{p}_tr];[{p}_k3]crop=trunc(iw/2):trunc(ih/2):0:0,vflip[{p}_bl];[{p}_k4]crop=trunc(iw/2):trunc(ih/2):0:0,hflip,vflip[{p}_br];[{p}_tl][{p}_tr]hstack[{p}_top];[{p}_bl][{p}_br]hstack[{p}_bot];[{p}_top][{p}_bot]vstack",
    "vignette_heavy": "vignette=angle=PI/2.2:mode=forward,eq=contrast=1.08:brightness=-0.03",
    "bw_grain": "hue=s=0,noise=alls=22:allf=t+u,eq=contrast=1.18",
    "dreamy_haze": "format=rgb24,split[{p}_d0][{p}_d1];[{p}_d1]gblur=sigma=8,eq=brightness=0.10:saturation=1.2[{p}_d2];[{p}_d0][{p}_d2]blend=all_mode=lighten:all_opacity=0.38,colorbalance=rh=0.06:bh=0.08",
    "duotone_cyber": "hue=s=0,format=rgb24,lutrgb=r='clip(val*1.25+20,0,255)':g='clip(val*0.55+10,0,255)':b='clip(255-val*0.35,0,255)'",
    "warm_sunset": "colorbalance=rs=0.14:gs=0.04:bs=-0.12:rm=0.16:gm=0.05:bm=-0.14:rh=0.18:gh=0.08:bh=-0.10,eq=saturation=1.22:contrast=1.06",
    "cold_moonlight": "colorbalance=rs=-0.14:gs=-0.02:bs=0.18:rm=-0.12:gm=0.0:bm=0.16:rh=-0.08:gh=0.02:bh=0.14,eq=brightness=-0.05:contrast=1.12:saturation=0.78",
}

_GEOMETRIC_VISUAL_EFFECTS: set[str] = {"mirror_split", "kaleido"}

_DEFAULT_AUDIO_EFFECTS: dict[str, str] = {
    "none": "",
    "telephone": "highpass=f=300,lowpass=f=3000,acompressor=threshold=-18dB:ratio=4",
    "robot": "vibrato=f=35:d=0.85,aecho=0.8:0.88:20:0.4",
    "chipmunk": "asetrate=48000*1.35,aresample=48000,atempo=0.74074",
    "radio_am": "highpass=f=450,lowpass=f=2400,equalizer=f=1200:t=q:w=1.2:g=5,acrusher=bits=10:mix=0.25,acompressor=threshold=-20dB:ratio=6",
    "megaphone": "highpass=f=550,lowpass=f=3600,equalizer=f=1800:t=q:w=1.5:g=8,acrusher=bits=8:mix=0.35,acompressor=threshold=-22dB:ratio=8,alimiter=limit=0.9",
    "walkie_talkie": "bandpass=f=1400:width_type=h:w=1800,acrusher=bits=7:mix=0.4,acompressor=threshold=-24dB:ratio=10,equalizer=f=2000:t=q:w=2.0:g=4",
    "deep_voice": "asetrate=48000*0.80,aresample=48000,atempo=1.25,bass=g=4:f=120",
    "helium": "asetrate=48000*1.55,aresample=48000,atempo=0.64516,highpass=f=200",
    "monster": "asetrate=48000*0.68,aresample=48000,atempo=1.47059,bass=g=7:f=90,aecho=0.8:0.85:35:0.45,acrusher=bits=10:mix=0.25",
    "hall_reverb": "aecho=0.8:0.88:60|95|140:0.42|0.32|0.22,lowpass=f=9000",
    "room_reverb": "aecho=0.85:0.82:18|34:0.35|0.22",
    "cathedral": "aecho=0.75:0.90:90|160|250|360:0.50|0.40|0.30|0.20,lowpass=f=7500",
    "slapback_echo": "aecho=0.85:0.80:110:0.48",
    "dub_delay": "aecho=0.80:0.85:280|560|840:0.55|0.35|0.20,lowpass=f=5000",
    "underwater": "lowpass=f=420,equalizer=f=220:t=q:w=1.0:g=5,aphaser=in_gain=0.6:out_gain=0.74:delay=3.0:decay=0.4:speed=0.4",
    "chorus": "chorus=0.6:0.9:50|60|40:0.4|0.32|0.3:0.25|0.4|0.3:2|2.3|1.3",
    "flanger": "flanger=delay=4:depth=3:regen=25:width=80:speed=0.6",
    "phaser": "aphaser=in_gain=0.6:out_gain=0.8:delay=3.0:decay=0.55:speed=0.8:type=t",
    "tremolo": "tremolo=f=6.5:d=0.65",
    "vibrato": "vibrato=f=6.5:d=0.55",
    "vinyl_lofi": "highpass=f=180,lowpass=f=3800,acrusher=bits=11:mix=0.22,vibrato=f=1.2:d=0.08,equalizer=f=300:t=q:w=1.0:g=3",
    "bass_boost": "bass=g=8:f=100:w=0.7,acompressor=threshold=-14dB:ratio=3,alimiter=limit=0.95",
    "vocal_presence": "highpass=f=90,equalizer=f=2800:t=q:w=1.2:g=4.5,equalizer=f=5500:t=q:w=1.5:g=3,acompressor=threshold=-18dB:ratio=3:makeup=2",
    "podcast_warm": "highpass=f=75,bass=g=4:f=130:w=0.8,equalizer=f=3200:t=q:w=1.2:g=2.5,acompressor=threshold=-20dB:ratio=3.5:attack=10:release=120,alimiter=limit=0.95",
    "de_esser": "equalizer=f=6500:t=q:w=2.2:g=-6,equalizer=f=8500:t=q:w=2.0:g=-4,acompressor=threshold=-16dB:ratio=2.5",
}


def _load_effects_catalog() -> tuple[dict[str, str], dict[str, str], set[str], set[str], set[str]]:
    visual = dict(_DEFAULT_VISUAL_EFFECTS)
    audio = dict(_DEFAULT_AUDIO_EFFECTS)
    blend_modes: set[str] = {
        "normal", "multiply", "screen", "overlay", "darken", "lighten", "addition", "difference"
    }
    mask_kinds: set[str] = {"none", "rect", "ellipse", "linear_fade"}
    shape_kinds: set[str] = {"rect", "rounded_rect", "ellipse", "triangle", "star", "arrow", "pill", "line"}
    catalog_path = Path(__file__).resolve().parent / "effects_catalog.json"
    if catalog_path.is_file():
        try:
            data = json.loads(catalog_path.read_text(encoding="utf-8"))
            for item in data.get("visualEffects") or []:
                vid = str(item.get("id") or "").strip().lower()
                flt = str(item.get("ffmpegFilter") or "").strip()
                if vid and flt:
                    visual[vid] = flt
            for item in data.get("audioEffects") or []:
                aid = str(item.get("id") or "").strip().lower()
                flt = str(item.get("ffmpegFilter") or "").strip()
                if aid and flt:
                    audio[aid] = flt
            bm = {str(x.get("id") or "").strip().lower() for x in (data.get("blendModes") or []) if x.get("id")}
            if bm:
                blend_modes = bm | {"normal"}
            mk = {str(x.get("id") or "").strip().lower() for x in (data.get("masks") or []) if x.get("id")}
            if mk:
                mask_kinds = mk | {"none"}
            sk = {str(x.get("id") or "").strip().lower() for x in (data.get("shapes") or []) if x.get("id")}
            if sk:
                shape_kinds = sk
        except Exception:
            pass
    return visual, audio, blend_modes, mask_kinds, shape_kinds


VISUAL_EFFECTS, AUDIO_EFFECTS, BLEND_MODES, MASK_KINDS, SHAPE_KINDS = _load_effects_catalog()

KEYFRAME_PROPERTIES: set[str] = {"posX", "posY", "scale", "rotation", "opacity", "volume"}
KEYFRAME_EASINGS: set[str] = {"linear", "easeIn", "easeOut", "easeInOut"}

VOICE_CLEANUP_FILTER: str = (
    "highpass=f=80,afftdn=nf=-25,loudnorm=I=-16:TP=-1.5:LRA=11,"
    "aresample=48000,aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"
)

# (primary_encoder, cpu_fallback_encoder, supports_10bit)
SUPPORTED_CODECS: dict[str, tuple[str, Optional[str], bool]] = {
    "h264": ("libx264", None, False),
    "hevc": ("libx265", None, True),
    "h265": ("libx265", None, True),
    "h264_hw": ("h264_videotoolbox", "libx264", False),
    "hevc_hw": ("hevc_videotoolbox", "libx265", True),
    "h265_hw": ("hevc_videotoolbox", "libx265", True),
    "av1": ("libsvtav1", "libx264", True),
}

_ENCODER_CACHE: dict[str, set[str]] = {}

_HEX_COLOR_RE = re.compile(r"^(?:#|0[xX])?([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$")

_SRT_TIME_RE = re.compile(
    r"^\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})(?:\s+.*)?$"
)
_TIMECODE_RE = re.compile(r"^(?:(\d+):)?(\d{1,2}):(\d{2}(?:\.\d+)?)$")
_ALPHA_PIX_FMTS = {
    "rgba",
    "bgra",
    "argb",
    "abgr",
    "yuva420p",
    "yuva422p",
    "yuva444p",
    "yuva420p10le",
    "yuva422p10le",
    "yuva444p10le",
    "yuva444p12le",
    "yuva444p16le",
    "rgba64le",
    "rgba64be",
    "bgra64le",
    "bgra64be",
    "gbrap",
    "gbrap10le",
    "gbrap12le",
    "gbrap16le",
    "ya8",
    "ya16le",
    "ya16be",
    "pal8",
}


# ---------------------------------------------------------------------------
# SRT parsing & formatting
# ---------------------------------------------------------------------------

def _srt_parts_to_seconds(h: str, m: str, s: str, ms: str) -> float:
    ms_padded = ms.ljust(3, "0")[:3]
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms_padded) / 1000.0


def _seconds_to_srt_timestamp(seconds: float) -> str:
    total_ms = max(0, int(round(seconds * 1000.0)))
    total_sec, ms = divmod(total_ms, 1000)
    total_min, sec = divmod(total_sec, 60)
    hours, minutes = divmod(total_min, 60)
    return f"{hours:02d}:{minutes:02d}:{sec:02d},{ms:03d}"


def parse_srt(text: str) -> list[dict]:
    """Parse UTF-8 (with optional BOM) SRT subtitle text into clip dicts."""
    if not isinstance(text, str):
        raise ValueError("SRT 內容須為字串。")
    cleaned = text.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n")
    blocks = re.split(r"\n{2,}", cleaned.strip())
    clips: list[dict] = []

    for block in blocks:
        lines = [line for line in block.split("\n") if line != ""]
        if not lines:
            continue
        time_line_idx = -1
        match = None
        for idx, line in enumerate(lines[:2]):
            m = _SRT_TIME_RE.match(line)
            if m:
                time_line_idx = idx
                match = m
                break
        if match is None:
            continue

        start_sec = _srt_parts_to_seconds(match.group(1), match.group(2), match.group(3), match.group(4))
        end_sec = _srt_parts_to_seconds(match.group(5), match.group(6), match.group(7), match.group(8))
        if end_sec <= start_sec:
            continue

        body_lines = lines[time_line_idx + 1 :]
        body = "\n".join(line.rstrip() for line in body_lines).strip()
        if not body:
            continue

        clips.append(
            {
                "index": len(clips) + 1,
                "timelineStart": round(start_sec, 3),
                "duration": round(end_sec - start_sec, 3),
                "end": round(end_sec, 3),
                "text": body,
            }
        )
    return clips


def format_srt(clips: list[dict]) -> str:
    """Format a list of subtitle clip dicts into standard UTF-8 SRT text."""
    normalized: list[tuple[float, float, str]] = []
    for item in clips or []:
        if not isinstance(item, dict):
            continue
        raw_text = str(item.get("text") or "").replace("\r\n", "\n").replace("\r", "\n").strip()
        if not raw_text:
            continue
        start_val = _parse_optional_float(item.get("timelineStart"))
        if start_val is None:
            start_val = _parse_optional_float(item.get("start"))
        if start_val is None or start_val < 0:
            start_val = 0.0

        dur_val = _parse_optional_float(item.get("duration"))
        end_val = _parse_optional_float(item.get("end"))
        if dur_val is not None and dur_val > 0:
            end_sec = start_val + dur_val
        elif end_val is not None and end_val > start_val:
            end_sec = end_val
        else:
            continue
        normalized.append((start_val, end_sec, raw_text))

    normalized.sort(key=lambda entry: (entry[0], entry[1]))
    blocks: list[str] = []
    for idx, (start_sec, end_sec, body) in enumerate(normalized, 1):
        start_ts = _seconds_to_srt_timestamp(start_sec)
        end_ts = _seconds_to_srt_timestamp(end_sec)
        blocks.append(f"{idx}\n{start_ts} --> {end_ts}\n{body}")
    return "\n\n".join(blocks) + ("\n" if blocks else "")


# ---------------------------------------------------------------------------
# Internal helpers & data structures
# ---------------------------------------------------------------------------

def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _parse_optional_float(value: Any) -> Optional[float]:
    if value is None:
        return None
    if isinstance(value, bool):
        raise ValueError(f"數值格式無效：{value!r}")
    if isinstance(value, (int, float)):
        result = float(value)
    elif isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        tc = _TIMECODE_RE.match(text)
        if tc:
            hours = int(tc.group(1) or 0)
            minutes = int(tc.group(2))
            seconds = float(tc.group(3))
            result = hours * 3600.0 + minutes * 60.0 + seconds
        else:
            try:
                result = float(text)
            except ValueError as exc:
                raise ValueError(f"無法解析時間或數值：{value!r}") from exc
    else:
        raise ValueError(f"數值格式無效：{value!r}")
    if not math.isfinite(result):
        raise ValueError(f"數值須為有限數字：{value!r}")
    return result


def _parse_float(value: Any, default: float) -> float:
    parsed = _parse_optional_float(value)
    return default if parsed is None else parsed


def _clamp(value: float, lo: float, hi: float) -> float:
    return min(max(value, lo), hi)


def _run_cmd(args: list[Any], *, capture_output: bool = False) -> subprocess.CompletedProcess:
    cmd = [str(x) for x in args]
    try:
        return subprocess.run(
            cmd,
            check=True,
            stdin=subprocess.DEVNULL,
            capture_output=capture_output,
            text=capture_output,
        )
    except subprocess.CalledProcessError as exc:
        stderr_msg = (exc.stderr or "").strip() if isinstance(exc.stderr, str) else ""
        detail = f"\n{stderr_msg[-1200:]}" if stderr_msg else ""
        raise ValueError(f"外部命令執行失敗（{Path(cmd[0]).name}，代碼 {exc.returncode}）{detail}") from exc


def _probe_media(ffprobe: str, path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise ValueError(f"找不到素材檔案：{path}")
    result = _run_cmd(
        [ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)],
        capture_output=True,
    )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise ValueError(f"無法讀取媒體資訊：{path.name}") from exc


def _parse_sar(raw_sar: Optional[str]) -> float:
    if not raw_sar or raw_sar in {"N/A", "0:1", "1:1"}:
        return 1.0
    parts = raw_sar.split(":")
    if len(parts) == 2:
        try:
            num = float(parts[0])
            den = float(parts[1])
            if num > 0 and den > 0:
                return num / den
        except ValueError:
            pass
    return 1.0


def _resolve_output_size(request: dict[str, Any], size: Optional[tuple[int, int]]) -> tuple[int, int]:
    if size is not None:
        width, height = size
    else:
        pixel_size = request.get("pixelSize")
        if isinstance(pixel_size, dict):
            width = pixel_size.get("width")
            height = pixel_size.get("height")
        else:
            aspect = str(request.get("aspect") or "16:9")
            width, height = ASPECT_DIMENSIONS.get(aspect, (1920, 1080))

    if (
        type(width) is not int
        or type(height) is not int
        or not (64 <= width <= 4096)
        or not (64 <= height <= 4096)
    ):
        raise ValueError("輸出影片寬高須為 64–4096 之間的整數。")
    if width % 2 != 0 or height % 2 != 0:
        raise ValueError("輸出影片寬高須為偶數。")
    return width, height


def _resolve_textrender_bin(textrender_bin: Optional[str]) -> Optional[str]:
    if textrender_bin:
        candidate = Path(textrender_bin)
        if candidate.is_file():
            return str(candidate)
        found = shutil.which(str(textrender_bin))
        if found:
            return found
        return None
    here = Path(__file__).resolve().parent
    for candidate in (
        here / "textrender",
        here / "runtime" / "bin" / "textrender",
        here.parent / "MacOS" / "textrender",
    ):
        if candidate.is_file():
            return str(candidate)
    return shutil.which("textrender")


def _parse_hex_color(value: Any, default: str = "0x00FF00") -> str:
    if value is None:
        return default
    text = str(value).strip()
    if not text:
        return default
    m = _HEX_COLOR_RE.match(text)
    if not m:
        raise ValueError(f"色度去背顏色格式無效：{value!r}（須為 #RRGGBB 或 0xRRGGBB）。")
    digits = m.group(1)
    if len(digits) == 3:
        digits = "".join(ch * 2 for ch in digits)
    return f"0x{digits.upper()}"


def _parse_filter_preset(value: Any) -> str:
    if value is None:
        return "none"
    key = str(value).strip().lower()
    if not key:
        return "none"
    if key not in FILTER_PRESETS:
        raise ValueError(f"不支援的濾鏡預設：{value!r}。")
    return key


def _parse_clip_animation(value: Any) -> str:
    if value is None:
        return "none"
    key = str(value).strip().lower()
    if not key:
        return "none"
    if key not in CLIP_ANIMATIONS:
        raise ValueError(f"不支援的片段動畫：{value!r}。")
    return key


def _parse_audio_effect(value: Any) -> str:
    if value is None:
        return "none"
    key = str(value).strip().lower()
    if not key:
        return "none"
    if key not in AUDIO_EFFECTS:
        raise ValueError(f"不支援的音效處理：{value!r}。")
    return key


def _parse_visual_effect(value: Any) -> str:
    if value is None:
        return "none"
    key = str(value).strip().lower()
    if not key:
        return "none"
    if key not in VISUAL_EFFECTS:
        raise ValueError(f"不支援的視覺特效：{value!r}。")
    return key


def _parse_blend_mode(value: Any) -> str:
    if value is None:
        return "normal"
    key = str(value).strip().lower()
    if not key:
        return "normal"
    if key not in BLEND_MODES:
        raise ValueError(f"不支援的混合模式：{value!r}。")
    return key


def _parse_mask_kind(value: Any) -> str:
    if value is None:
        return "none"
    key = str(value).strip().lower()
    if not key:
        return "none"
    if key not in MASK_KINDS:
        raise ValueError(f"不支援的遮罩類型：{value!r}。")
    return key


def _parse_keyframes(raw_kfs: Any) -> list[dict[str, Any]]:
    if not raw_kfs or not isinstance(raw_kfs, list):
        return []
    parsed: list[dict[str, Any]] = []
    easing_aliases = {
        "linear": "linear",
        "easein": "easeIn",
        "ease_in": "easeIn",
        "easeout": "easeOut",
        "ease_out": "easeOut",
        "easeinout": "easeInOut",
        "ease_in_out": "easeInOut",
    }
    for item in raw_kfs:
        if not isinstance(item, dict):
            continue
        prop = str(item.get("property") or "").strip()
        if prop not in KEYFRAME_PROPERTIES:
            continue
        t_val = _parse_optional_float(item.get("time"))
        v_val = _parse_optional_float(item.get("value"))
        if t_val is None or v_val is None or t_val < 0.0:
            continue
        raw_ease = str(item.get("easing") or "linear").strip().lower()
        easing = easing_aliases.get(raw_ease, "linear")
        parsed.append({"property": prop, "time": float(t_val), "value": float(v_val), "easing": easing})
    return parsed


def _build_keyframe_expr(
    keyframes: list[dict[str, Any]],
    prop: str,
    default_val: float,
    timeline_start: float = 0.0,
    *,
    time_var: str = "t",
) -> Optional[str]:
    """Build a piecewise FFmpeg expression supporting linear, easeIn, easeOut, easeInOut."""
    pts_by_time: dict[float, dict[str, Any]] = {}
    for kf in keyframes or []:
        if kf.get("property") == prop:
            pts_by_time[round(float(kf["time"]), 6)] = kf
    if not pts_by_time:
        return None
    pts = [pts_by_time[k] for k in sorted(pts_by_time.keys())]
    if len(pts) == 1:
        return f"{float(pts[0]['value']):.6f}"

    tl = f"({time_var}-{timeline_start:.6f})" if abs(timeline_start) > 1e-6 else time_var

    def _eased_p(p_expr: str, easing: str) -> str:
        if easing == "easeIn":
            return f"pow({p_expr},2)"
        if easing == "easeOut":
            return f"(1-pow(1-{p_expr},2))"
        if easing == "easeInOut":
            return f"(3*pow({p_expr},2)-2*pow({p_expr},3))"
        return p_expr

    # Build from last segment backwards into nested if(lt(...), ..., ...).
    expr = f"{float(pts[-1]['value']):.6f}"
    for idx in range(len(pts) - 2, -1, -1):
        t0 = float(pts[idx]["time"])
        v0 = float(pts[idx]["value"])
        t1 = float(pts[idx + 1]["time"])
        v1 = float(pts[idx + 1]["value"])
        easing = str(pts[idx].get("easing") or "linear")
        dt = max(1e-5, t1 - t0)
        p_expr = f"clip(({tl}-{t0:.6f})/{dt:.6f},0,1)"
        ep = _eased_p(p_expr, easing)
        dv = v1 - v0
        if abs(dv) <= 1e-7:
            seg_expr = f"{v0:.6f}"
        else:
            seg_expr = f"({v0:.6f}+({dv:.6f})*{ep})"
        expr = f"if(lt({tl},{t1:.6f}),{seg_expr},{expr})"

    t_first = float(pts[0]["time"])
    v_first = float(pts[0]["value"])
    if t_first > 1e-6:
        expr = f"if(lt({tl},{t_first:.6f}),{v_first:.6f},{expr})"
    return expr


def _parse_speed_curve(raw_curve: Any) -> list[tuple[float, float]]:
    if not raw_curve or not isinstance(raw_curve, list):
        return []
    pts: list[tuple[float, float]] = []
    for item in raw_curve:
        if not isinstance(item, dict):
            continue
        p = _parse_optional_float(item.get("progress"))
        s = _parse_optional_float(item.get("speed"))
        if p is None or s is None:
            continue
        pts.append((_clamp(p, 0.0, 1.0), _clamp(s, 0.25, 4.0)))
    if len(pts) < 2:
        return []
    pts.sort(key=lambda pair: pair[0])
    # Deduplicate identical progress values keeping the last entry.
    dedup: list[tuple[float, float]] = []
    for p, s in pts:
        if dedup and abs(dedup[-1][0] - p) < 1e-6:
            dedup[-1] = (p, s)
        else:
            dedup.append((p, s))
    return dedup if len(dedup) >= 2 else []


def _eval_speed_curve(curve: list[tuple[float, float]], progress: float) -> float:
    u = _clamp(progress, 0.0, 1.0)
    if u <= curve[0][0]:
        return curve[0][1]
    if u >= curve[-1][0]:
        return curve[-1][1]
    for i in range(len(curve) - 1):
        p0, s0 = curve[i]
        p1, s1 = curve[i + 1]
        if p0 <= u <= p1:
            span = max(1e-6, p1 - p0)
            frac = (u - p0) / span
            return _clamp(s0 + (s1 - s0) * frac, 0.25, 4.0)
    return curve[-1][1]


def _speed_curve_segments(
    src_dur: float,
    curve: list[tuple[float, float]],
    fps: int,
) -> list[tuple[float, float, float]]:
    """Return list of (src_start, src_end, seg_speed) segments for piecewise speed ramp."""
    min_seg = max(0.08, 2.0 / max(1, fps))
    max_segs = max(2, min(8, int(src_dur / min_seg)))
    n_segs = max(2, min(6, max_segs))
    segs: list[tuple[float, float, float]] = []
    for k in range(n_segs):
        s0 = src_dur * k / n_segs
        s1 = src_dur * (k + 1) / n_segs
        u_mid = (k + 0.5) / n_segs
        seg_speed = _eval_speed_curve(curve, u_mid)
        segs.append((s0, s1, seg_speed))
    return segs


def _speed_curve_output_duration(
    src_dur: float,
    curve: list[tuple[float, float]],
    fps: int,
) -> float:
    return sum((s1 - s0) / spd for s0, s1, spd in _speed_curve_segments(src_dur, curve, fps))


def _probe_available_encoders(ffmpeg: str) -> set[str]:
    cached = _ENCODER_CACHE.get(ffmpeg)
    if cached is not None:
        return cached
    found: set[str] = set()
    try:
        res = subprocess.run(
            [ffmpeg, "-hide_banner", "-encoders"],
            check=False,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
        )
        for line in (res.stdout or "").splitlines():
            parts = line.split()
            if len(parts) >= 2 and len(parts[0]) == 6 and parts[0][0] in {"V", "A", "S"}:
                found.add(parts[1])
    except OSError:
        pass
    _ENCODER_CACHE[ffmpeg] = found
    return found


def _build_atempo_filters(speed: float) -> list[str]:
    """Decompose speed in [0.25, 4.0] into valid FFmpeg atempo stages in [0.5, 2.0]."""
    if abs(speed - 1.0) <= 1e-4:
        return []
    stages: list[str] = []
    rem = speed
    while rem > 2.0 + 1e-6:
        stages.append("atempo=2.0")
        rem /= 2.0
    while rem < 0.5 - 1e-6:
        stages.append("atempo=0.5")
        rem /= 0.5
    if abs(rem - 1.0) > 1e-4:
        stages.append(f"atempo={_clamp(rem, 0.5, 2.0):.6f}")
    return stages


def _build_audio_fx_filters(voice_cleanup: bool, audio_effect: str) -> list[str]:
    fx: list[str] = []
    if voice_cleanup:
        fx.append(VOICE_CLEANUP_FILTER)
    effect_str = AUDIO_EFFECTS.get(audio_effect, "")
    if effect_str:
        fx.append(effect_str)
        fx.append("aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo")
    return fx


def _resolve_video_encoder(
    request: dict[str, Any],
    log_fn: Callable[[str], Any],
    *,
    ffmpeg: Optional[str] = None,
) -> tuple[str, Optional[str], bool, int, str]:
    codec_raw = str(request.get("codec") or "h264").strip().lower()
    if codec_raw not in SUPPORTED_CODECS:
        raise ValueError(
            f"不支援的視訊編碼器：{codec_raw!r}（支援 h264 / hevc / h264_hw / hevc_hw / av1）。"
        )
    primary_enc, fallback_enc, supports_10bit = SUPPORTED_CODECS[codec_raw]

    if ffmpeg:
        avail = _probe_available_encoders(ffmpeg)
        if avail and primary_enc not in avail:
            if fallback_enc and fallback_enc in avail:
                log_fn(f"目前 FFmpeg 未內建 {primary_enc}，自動改用 CPU 編碼器 {fallback_enc}。")
                primary_enc = fallback_enc
                fallback_enc = None
                supports_10bit = primary_enc in {"libx265", "libsvtav1"}
            else:
                raise ValueError(f"目前 FFmpeg 未支援編碼器：{primary_enc}。")

    raw_bit_depth = request.get("bitDepth", 8)
    if raw_bit_depth is None:
        bit_depth = 8
    elif isinstance(raw_bit_depth, bool):
        raise ValueError(f"bitDepth 格式無效：{raw_bit_depth!r}。")
    else:
        try:
            bit_depth = int(raw_bit_depth)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"bitDepth 格式無效：{raw_bit_depth!r}。") from exc

    if bit_depth not in {8, 10}:
        raise ValueError(f"bitDepth 僅支援 8 或 10（收到 {bit_depth}）。")

    if bit_depth == 10 and not supports_10bit:
        log_fn("H.264 編碼不支援 10-bit 輸出，自動維持 8-bit yuv420p。")
        bit_depth = 8

    graph_pix_fmt = "yuv420p10le" if (bit_depth == 10 and supports_10bit) else "yuv420p"
    return primary_enc, fallback_enc, supports_10bit, bit_depth, graph_pix_fmt


def _encoder_output_args(encoder: str, supports_10bit: bool, bit_depth: int) -> list[str]:
    if encoder == "libx264":
        return [
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-preset",
            "veryfast",
            "-crf",
            "19",
            "-threads",
            "3",
        ]
    if encoder == "libx265":
        args = [
            "-c:v",
            "libx265",
            "-pix_fmt",
            "yuv420p10le" if bit_depth == 10 else "yuv420p",
            "-preset",
            "veryfast",
            "-crf",
            "22",
            "-tag:v",
            "hvc1",
            "-threads",
            "3",
        ]
        if bit_depth == 10:
            args += ["-profile:v", "main10"]
        return args
    if encoder == "h264_videotoolbox":
        return [
            "-c:v",
            "h264_videotoolbox",
            "-pix_fmt",
            "yuv420p",
            "-q:v",
            "65",
        ]
    if encoder == "hevc_videotoolbox":
        args = [
            "-c:v",
            "hevc_videotoolbox",
            "-pix_fmt",
            "p010le" if bit_depth == 10 else "yuv420p",
            "-q:v",
            "65",
            "-tag:v",
            "hvc1",
        ]
        if bit_depth == 10:
            args += ["-profile:v", "main10"]
        return args
    if encoder == "libsvtav1":
        return [
            "-c:v",
            "libsvtav1",
            "-pix_fmt",
            "yuv420p10le" if (bit_depth == 10 and supports_10bit) else "yuv420p",
            "-preset",
            "8",
            "-crf",
            "30",
        ]
    raise ValueError(f"未知的視訊編碼器：{encoder}")


@dataclass
class _PreparedVideoClip:
    clip_id: str
    track_idx: int
    track_name: str
    track_muted: bool
    path: Path
    is_image: bool
    has_audio: bool
    has_alpha: bool
    src_w: int
    src_h: int
    sar: float
    timeline_start: float
    source_start: float
    duration: float
    pos_x: float
    pos_y: float
    scale: float
    opacity: float
    volume: float
    muted: bool
    source_duration: float = 0.0
    flip_h: bool = False
    flip_v: bool = False
    rotation: float = 0.0
    crop_left: float = 0.0
    crop_right: float = 0.0
    crop_top: float = 0.0
    crop_bottom: float = 0.0
    filter_preset: str = "none"
    effect_id: str = "none"
    brightness: float = 0.0
    contrast: float = 1.0
    saturation: float = 1.0
    blur: float = 0.0
    vignette: bool = False
    stabilize_enabled: bool = False
    stabilize_strength: float = 0.5
    enhance_clarity: float = 0.0
    mask_kind: str = "none"
    mask_feather: float = 0.12
    mask_invert: bool = False
    blend_mode: str = "normal"
    chroma_key_enabled: bool = False
    chroma_key_color: str = "0x00FF00"
    chroma_key_similarity: float = 0.18
    chroma_key_blend: float = 0.08
    speed: float = 1.0
    speed_curve: list[tuple[float, float]] = field(default_factory=list)
    keyframes: list[dict[str, Any]] = field(default_factory=list)
    reversed: bool = False
    freeze_frame: bool = False
    animation_in: str = "none"
    animation_out: str = "none"
    animation_duration: float = 0.4
    voice_cleanup: bool = False
    audio_effect: str = "none"


@dataclass
class _TransitionSpec:
    after_id: str
    before_id: str
    kind_name: str
    ffmpeg_kind: str
    seconds: float
    frames: int


@dataclass
class _VideoChain:
    track_idx: int
    chain_idx: int
    track_name: str
    track_muted: bool
    clips: list[_PreparedVideoClip]
    transitions: list[_TransitionSpec] = field(default_factory=list)
    timeline_start: float = 0.0
    duration: float = 0.0
    rendered_path: Optional[Path] = None
    has_chain_audio: bool = False


@dataclass
class _PreparedAudioClip:
    clip_id: str
    track_name: str
    path: Path
    timeline_start: float
    source_start: float
    source_end: float
    duration: float
    effective_volume: float
    fade_in: float
    fade_out: float
    voice_cleanup: bool = False
    audio_effect: str = "none"
    keyframes: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class _PreparedTextClip:
    clip_id: str
    track_name: str
    text: str
    timeline_start: float
    duration: float
    spec: dict[str, Any]
    png_path: Optional[Path] = None


@dataclass
class _PreparedShapeClip:
    clip_id: str
    track_name: str
    timeline_start: float
    duration: float
    spec: dict[str, Any]
    png_path: Optional[Path] = None


def _compute_pip_geometry(
    src_w: int,
    src_h: int,
    sar: float,
    canvas_w: int,
    canvas_h: int,
    scale: float,
    pos_x: float,
    pos_y: float,
    *,
    crop_left: float = 0.0,
    crop_right: float = 0.0,
    crop_top: float = 0.0,
    crop_bottom: float = 0.0,
    rotation: float = 0.0,
) -> tuple[int, int, int, int]:
    eff_w = max(2.0, src_w * sar * max(0.1, 1.0 - crop_left - crop_right))
    eff_h = max(2.0, float(src_h) * max(0.1, 1.0 - crop_top - crop_bottom))
    if abs(rotation) > 0.01:
        rad = abs(math.radians(rotation))
        box_w = abs(eff_w * math.cos(rad)) + abs(eff_h * math.sin(rad))
        box_h = abs(eff_w * math.sin(rad)) + abs(eff_h * math.cos(rad))
    else:
        box_w, box_h = eff_w, eff_h
    fit_ratio = min(canvas_w / box_w, canvas_h / box_h)
    scaled_w = max(2, int(round(eff_w * fit_ratio * scale)))
    scaled_h = max(2, int(round(eff_h * fit_ratio * scale)))
    x = int(round((canvas_w - scaled_w) / 2.0 + pos_x * (canvas_w / 2.0)))
    y = int(round((canvas_h - scaled_h) / 2.0 + pos_y * (canvas_h / 2.0)))
    return scaled_w, scaled_h, x, y


def _has_keyframe_prop(keyframes: list[dict[str, Any]], prop: str) -> bool:
    return any(kf.get("property") == prop for kf in (keyframes or []))


def _needs_pip_or_alpha(clip: _PreparedVideoClip) -> bool:
    return (
        abs(clip.scale - 1.0) > 1e-4
        or abs(clip.pos_x) > 1e-4
        or abs(clip.pos_y) > 1e-4
        or clip.opacity < 0.999
        or clip.chroma_key_enabled
        or abs(clip.rotation) > 0.01
        or clip.mask_kind != "none"
        or clip.blend_mode != "normal"
        or bool(clip.keyframes)
        or clip.animation_in != "none"
        or clip.animation_out != "none"
        or (clip.track_idx > 0 and clip.has_alpha)
    )


def _build_color_filters(clip: _PreparedVideoClip) -> list[str]:
    color_filters: list[str] = []
    if clip.enhance_clarity > 1e-3:
        s = _clamp(clip.enhance_clarity, 0.0, 1.0)
        ls = 1.0 + 3.5 * s
        cs = 0.8 + 2.5 * s
        lt = 2.0 + 4.0 * s
        ct = 1.5 + 3.0 * s
        sl = 0.3 + 1.2 * s
        sc = 0.1 + 0.35 * s
        color_filters.append(f"hqdn3d={ls:.2f}:{cs:.2f}:{lt:.2f}:{ct:.2f}")
        color_filters.append(f"unsharp=5:5:{sl:.3f}:5:5:{sc:.3f}")
    preset_expr = FILTER_PRESETS.get(clip.filter_preset, "")
    if preset_expr:
        color_filters.append(preset_expr)
    if (
        abs(clip.brightness) > 1e-4
        or abs(clip.contrast - 1.0) > 1e-4
        or abs(clip.saturation - 1.0) > 1e-4
    ):
        color_filters.append(
            f"eq=brightness={clip.brightness:.4f}:contrast={clip.contrast:.4f}:saturation={clip.saturation:.4f}"
        )
    if clip.blur > 0.01:
        color_filters.append(f"gblur=sigma={clip.blur:.4f}")
    if clip.vignette:
        color_filters.append("vignette=PI/3.5")
    return color_filters


def _build_mask_filter(clip: _PreparedVideoClip) -> Optional[str]:
    if clip.mask_kind == "none":
        return None
    f = max(0.01, _clamp(clip.mask_feather, 0.0, 0.5))
    if clip.mask_kind == "rect":
        raw = (
            f"clip(min(min((X-0.10*W)/max(1,{f:.4f}*W),(0.90*W-X)/max(1,{f:.4f}*W)),"
            f"min((Y-0.10*H)/max(1,{f:.4f}*H),(0.90*H-Y)/max(1,{f:.4f}*H))),0,1)"
        )
    elif clip.mask_kind == "ellipse":
        raw = f"clip((1-hypot((X-0.5*W)/(0.44*W),(Y-0.5*H)/(0.44*H)))/{f:.4f},0,1)"
    elif clip.mask_kind == "linear_fade":
        span = max(0.05, f * 1.5)
        raw = f"clip(0.5+(0.5*H-Y)/max(1,{span:.4f}*H),0,1)"
    else:
        return None
    mask_expr = f"(1-({raw}))" if clip.mask_invert else raw
    return f"geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='alpha(X,Y)*{mask_expr}'"


def _build_clip_input_args(
    clip: _PreparedVideoClip,
    *,
    fps: int,
    target_duration: float,
) -> list[Any]:
    if clip.is_image:
        return [
            "-threads",
            "2",
            "-loop",
            "1",
            "-framerate",
            str(fps),
            "-t",
            f"{target_duration:.9f}",
            "-i",
            clip.path,
        ]
    if clip.freeze_frame:
        return [
            "-threads",
            "2",
            "-ss",
            f"{clip.source_start:.9f}",
            "-i",
            clip.path,
        ]
    src_dur = clip.source_duration if clip.source_duration > 0 else clip.duration
    return [
        "-threads",
        "2",
        "-ss",
        f"{clip.source_start:.9f}",
        "-t",
        f"{src_dur + 0.1:.9f}",
        "-i",
        clip.path,
    ]


def _append_clip_video_filters(
    filters: list[str],
    *,
    input_label: str,
    tag_prefix: str,
    clip: _PreparedVideoClip,
    canvas_w: int,
    canvas_h: int,
    fps: int,
    target_duration: float,
    target_frames: Optional[int],
    timeline_start: float,
    use_pip_alpha: bool,
) -> tuple[str, str, str]:
    """Append complete video filter chain for a clip and return (out_label, overlay_x, overlay_y)."""
    cur_label = input_label
    parts: list[str] = []

    kf_scale = _build_keyframe_expr(clip.keyframes, "scale", clip.scale, 0.0, time_var="t")
    kf_rot = _build_keyframe_expr(clip.keyframes, "rotation", clip.rotation, 0.0, time_var="t")
    kf_op = _build_keyframe_expr(clip.keyframes, "opacity", clip.opacity, 0.0, time_var="T")
    kf_pos_x = _build_keyframe_expr(clip.keyframes, "posX", clip.pos_x, timeline_start, time_var="t")
    kf_pos_y = _build_keyframe_expr(clip.keyframes, "posY", clip.pos_y, timeline_start, time_var="t")

    # 1. Source extraction / freeze frame / trim to exact source duration.
    src_dur = clip.source_duration if clip.source_duration > 0 else clip.duration
    if clip.freeze_frame and not clip.is_image:
        freeze_frames = (
            target_frames
            if target_frames is not None
            else max(1, int(math.ceil(target_duration * fps)) + 4)
        )
        parts.extend(
            [
                "trim=end_frame=1",
                f"loop=loop={freeze_frames + 4}:size=1:start=0",
                f"setpts=N/({fps}*TB)",
                f"fps={fps}",
            ]
        )
    elif clip.is_image:
        parts.append(f"fps={fps}")
    else:
        parts.extend(
            [
                "setpts=PTS-STARTPTS",
                f"trim=duration={src_dur:.9f}",
                "setpts=PTS-STARTPTS",
            ]
        )

    # 2. Source crop & horizontal/vertical flips (before scaling).
    if (
        clip.crop_left > 1e-4
        or clip.crop_right > 1e-4
        or clip.crop_top > 1e-4
        or clip.crop_bottom > 1e-4
    ):
        cw = max(0.1, 1.0 - clip.crop_left - clip.crop_right)
        ch = max(0.1, 1.0 - clip.crop_top - clip.crop_bottom)
        parts.append(
            f"crop=iw*{cw:.6f}:ih*{ch:.6f}:iw*{clip.crop_left:.6f}:ih*{clip.crop_top:.6f}"
        )
    if clip.flip_h:
        parts.append("hflip")
    if clip.flip_v:
        parts.append("vflip")

    # 3. Scale to target size (before reverse to minimize frame buffer memory).
    if use_pip_alpha:
        base_scale = 1.0 if kf_scale is not None else clip.scale
        base_rot = 0.0 if kf_rot is not None else clip.rotation
        scaled_w, scaled_h, _, _ = _compute_pip_geometry(
            clip.src_w,
            clip.src_h,
            clip.sar,
            canvas_w,
            canvas_h,
            base_scale,
            clip.pos_x,
            clip.pos_y,
            crop_left=clip.crop_left,
            crop_right=clip.crop_right,
            crop_top=clip.crop_top,
            crop_bottom=clip.crop_bottom,
            rotation=base_rot,
        )
        eff_w, eff_h = scaled_w, scaled_h
        parts.append(f"scale={scaled_w}:{scaled_h}:flags=lanczos")
        parts.append("setsar=1")
    else:
        eff_w, eff_h = canvas_w, canvas_h
        parts.append(
            f"scale={canvas_w}:{canvas_h}:force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos"
        )
        parts.append(f"pad={canvas_w}:{canvas_h}:(ow-iw)/2:(oh-ih)/2:black")
        parts.append("setsar=1")

    # 4. Reverse, speed retiming (constant or piecewise speedCurve), stabilization, and target fps.
    if (not clip.is_image) and (not clip.freeze_frame):
        if clip.reversed:
            parts.append("reverse")
            parts.append("setpts=PTS-STARTPTS")
        if clip.stabilize_enabled:
            r_px = max(16, min(64, int(round(1.0 + _clamp(clip.stabilize_strength, 0.0, 1.0) * 3.0)) * 16))
            parts.append(f"deshake=x=-1:y=-1:w=-1:h=-1:rx={r_px}:ry={r_px}:edge=mirror")
        if len(clip.speed_curve) >= 2:
            segs = _speed_curve_segments(src_dur, clip.speed_curve, fps)
            n_segs = len(segs)
            sr_in = f"[{tag_prefix}_srin]"
            filters.append(f"{cur_label}" + ",".join(parts) + sr_in)
            split_labels = "".join(f"[{tag_prefix}_sr{k}]" for k in range(n_segs))
            filters.append(f"{sr_in}split={n_segs}{split_labels}")
            concat_inputs: list[str] = []
            for k, (s0, s1, seg_speed) in enumerate(segs):
                out_k = f"[{tag_prefix}_sro{k}]"
                filters.append(
                    f"[{tag_prefix}_sr{k}]trim=start={s0:.9f}:end={s1:.9f},"
                    f"setpts=(PTS-STARTPTS)/{seg_speed:.6f}{out_k}"
                )
                concat_inputs.append(out_k)
            sr_out = f"[{tag_prefix}_srout]"
            filters.append("".join(concat_inputs) + f"concat=n={n_segs}:v=1:a=0,fps={fps}{sr_out}")
            cur_label = sr_out
            parts = []
        else:
            if abs(clip.speed - 1.0) > 1e-4:
                parts.append(f"setpts=PTS/{clip.speed:.6f}")
            parts.append(f"fps={fps}")

    # 5. Chroma key + 24 visual effects + color grading / clarity enhancement / blur / vignette.
    color_filters = _build_color_filters(clip)
    has_existing_alpha = clip.chroma_key_enabled or (use_pip_alpha and clip.has_alpha)
    if clip.chroma_key_enabled:
        parts.append("format=rgba")
        parts.append(
            f"chromakey=color={clip.chroma_key_color}:"
            f"similarity={clip.chroma_key_similarity:.4f}:blend={clip.chroma_key_blend:.4f}"
        )
        parts.append("format=rgba")

    fx_template = VISUAL_EFFECTS.get(clip.effect_id, "")
    fx_expr = (
        fx_template.replace("{W}", str(max(2, eff_w)))
        .replace("{H}", str(max(2, eff_h)))
        .replace("{p}", f"{tag_prefix}_fx")
        if fx_template
        else ""
    )

    # Geometric effects (mirror_split, kaleido) preserve RGBA alpha spatially aligned.
    if fx_expr and clip.effect_id in _GEOMETRIC_VISUAL_EFFECTS:
        if has_existing_alpha:
            parts.append("format=rgba")
        geo_in = f"[{tag_prefix}_gin]"
        geo_out = f"[{tag_prefix}_gout]"
        if parts:
            filters.append(f"{cur_label}" + ",".join(parts) + geo_in)
            cur_label = geo_in
            parts = []
        filters.append(f"{cur_label}{fx_expr}{geo_out}")
        cur_label = geo_out
        fx_expr = ""

    if fx_expr or color_filters:
        if has_existing_alpha:
            pre_chain = (",".join(parts) + ",") if parts else ""
            filters.append(
                f"{cur_label}{pre_chain}format=rgba,split[{tag_prefix}_c][{tag_prefix}_a]"
            )
            filters.append(f"[{tag_prefix}_a]alphaextract[{tag_prefix}_alpha]")
            rgb_suffix = ("," + ",".join(color_filters)) if color_filters else ""
            if fx_expr:
                filters.append(f"[{tag_prefix}_c]{fx_expr}{rgb_suffix},format=rgba[{tag_prefix}_rgb]")
            else:
                filters.append(
                    f"[{tag_prefix}_c]" + ",".join(color_filters) + f",format=rgba[{tag_prefix}_rgb]"
                )
            cur_label = f"[{tag_prefix}_rgb][{tag_prefix}_alpha]"
            parts = ["alphamerge", "format=rgba"]
        else:
            if fx_expr:
                if ";" in fx_expr:
                    fx_in = f"[{tag_prefix}_fxin]"
                    fx_out = f"[{tag_prefix}_fxout]"
                    if parts:
                        filters.append(f"{cur_label}" + ",".join(parts) + fx_in)
                        cur_label = fx_in
                        parts = []
                    filters.append(f"{cur_label}{fx_expr}{fx_out}")
                    cur_label = fx_out
                else:
                    parts.append(fx_expr)
            parts.extend(color_filters)

    # 6. RGBA conversion, spatial mask, static rotation, and static opacity.
    parts.append("format=rgba")
    mask_filter = _build_mask_filter(clip)
    if mask_filter:
        parts.append(mask_filter)
        parts.append("format=rgba")
    if kf_rot is None and abs(clip.rotation) > 0.01:
        rad = math.radians(clip.rotation)
        parts.append(
            f"rotate={rad:.8f}:c=none:ow=rotw({rad:.8f}):oh=roth({rad:.8f})"
        )
        parts.append("format=rgba")
    if kf_op is None and clip.opacity < 0.999:
        parts.append(f"colorchannelmixer=aa={clip.opacity:.6f}")

    # 7. Exact duration pad/trim, local PTS reset, keyframe transforms, fade/zoom animations, timeline offset.
    parts.append("tpad=stop_mode=clone:stop_duration=0.1")
    if target_frames is not None:
        parts.append(f"trim=end_frame={target_frames}")
    else:
        parts.append(f"trim=duration={target_duration + 0.05:.9f}")
    parts.append("setpts=PTS-STARTPTS")

    if kf_op is not None:
        parts.append(f"geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='alpha(X,Y)*clip({kf_op},0,1)'")
        parts.append("format=rgba")
    if kf_rot is not None:
        parts.append(f"rotate='({kf_rot})*PI/180':c=none:ow='hypot(iw,ih)':oh='hypot(iw,ih)'")
        parts.append("format=rgba")
    if kf_scale is not None:
        parts.append(
            f"scale=w='max(2,trunc(iw*clip({kf_scale},0.1,3.0)/2)*2)':"
            f"h='max(2,trunc(ih*clip({kf_scale},0.1,3.0)/2)*2)':eval=frame"
        )
        parts.append("format=rgba")

    anim_d = min(clip.animation_duration, target_duration * 0.45)
    if anim_d >= 0.02:
        if clip.animation_in in {"fade", "zoom"}:
            parts.append(f"fade=t=in:st=0:d={anim_d:.6f}:alpha=1")
        if clip.animation_out in {"fade", "zoom"}:
            out_st = max(0.0, target_duration - anim_d)
            parts.append(f"fade=t=out:st={out_st:.6f}:d={anim_d:.6f}:alpha=1")

    if timeline_start > 1e-6:
        parts.append(f"setpts=PTS-STARTPTS+{timeline_start:.6f}/TB")

    out_label = f"[{tag_prefix}]"
    filters.append(f"{cur_label}" + ",".join(parts) + out_label)

    # 8. Overlay positioning & keyframe / slide / zoom motion expressions.
    if not use_pip_alpha:
        return out_label, "0", "0"

    if kf_pos_x is not None:
        base_x = f"(W-w)/2+(W/2)*({kf_pos_x})"
    else:
        dx = int(round(clip.pos_x * (canvas_w / 2.0)))
        base_x = f"(W-w)/2+{dx}" if dx >= 0 else f"(W-w)/2{dx}"

    if kf_pos_y is not None:
        base_y = f"(H-h)/2+(H/2)*({kf_pos_y})"
    else:
        dy = int(round(clip.pos_y * (canvas_h / 2.0)))
        base_y = f"(H-h)/2+{dy}" if dy >= 0 else f"(H-h)/2{dy}"

    x_terms = [base_x]
    y_terms = [base_y]
    c_end = timeline_start + target_duration

    if anim_d >= 0.02:
        if clip.animation_in == "slide_left":
            x_terms.append(
                f"if(lt(t,{timeline_start + anim_d:.6f}),"
                f"(W-({base_x}))*pow(1-clip((t-{timeline_start:.6f})/{anim_d:.6f},0,1),2),0)"
            )
        if clip.animation_out == "slide_left":
            x_terms.append(
                f"if(gt(t,{c_end - anim_d:.6f}),"
                f"-(({base_x})+w)*pow(clip((t-{c_end - anim_d:.6f})/{anim_d:.6f},0,1),2),0)"
            )
        if clip.animation_in == "slide_up":
            y_terms.append(
                f"if(lt(t,{timeline_start + anim_d:.6f}),"
                f"(H-({base_y}))*pow(1-clip((t-{timeline_start:.6f})/{anim_d:.6f},0,1),2),0)"
            )
        if clip.animation_out == "slide_up":
            y_terms.append(
                f"if(gt(t,{c_end - anim_d:.6f}),"
                f"-(({base_y})+h)*pow(clip((t-{c_end - anim_d:.6f})/{anim_d:.6f},0,1),2),0)"
            )
        if clip.animation_in == "zoom":
            y_terms.append(
                f"if(lt(t,{timeline_start + anim_d:.6f}),"
                f"(H*0.04)*pow(1-clip((t-{timeline_start:.6f})/{anim_d:.6f},0,1),2),0)"
            )
        if clip.animation_out == "zoom":
            y_terms.append(
                f"if(gt(t,{c_end - anim_d:.6f}),"
                f"-(H*0.04)*pow(clip((t-{c_end - anim_d:.6f})/{anim_d:.6f},0,1),2),0)"
            )

    x_expr = "'" + "+".join(x_terms) + "'"
    y_expr = "'" + "+".join(y_terms) + "'"
    return out_label, x_expr, y_expr


def _build_video_clip_audio_chain(
    input_label: str,
    clip: _PreparedVideoClip,
    target_duration: float,
    *,
    delay_ms: int = 0,
    total_duration: Optional[float] = None,
) -> list[str]:
    src_dur = clip.source_duration if clip.source_duration > 0 else clip.duration
    achain = [
        f"{input_label}aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo",
        f"atrim=0:{src_dur:.9f}",
        "asetpts=PTS-STARTPTS",
    ]
    if clip.reversed:
        achain.append("areverse")
        achain.append("asetpts=PTS-STARTPTS")
    achain.extend(_build_atempo_filters(clip.speed))
    achain.extend(_build_audio_fx_filters(clip.voice_cleanup, clip.audio_effect))
    kf_vol = _build_keyframe_expr(clip.keyframes, "volume", clip.volume, 0.0, time_var="t")
    if kf_vol is not None:
        achain.append(f"volume='clip({kf_vol},0,2)':eval=frame")
    else:
        achain.append(f"volume={clip.volume:.6f}")
    achain.append(f"apad=whole_dur={target_duration:.9f}")
    achain.append(f"atrim=0:{target_duration:.9f}")
    achain.append("asetpts=PTS-STARTPTS")
    if delay_ms > 0:
        achain.append(f"adelay={delay_ms}|{delay_ms}")
    if total_duration is not None:
        achain.append(f"apad=whole_dur={total_duration:.9f}")
        achain.append(f"atrim=0:{total_duration:.9f}")
        achain.append("asetpts=PTS-STARTPTS")
    return achain


def _append_video_clip_audio_filters(
    filters: list[str],
    *,
    input_label: str,
    out_label: str,
    tag_prefix: str,
    clip: _PreparedVideoClip,
    target_duration: float,
    fps: int = 24,
    delay_ms: int = 0,
    total_duration: Optional[float] = None,
) -> None:
    """Append video clip audio chain supporting both constant speed and piecewise speedCurve."""
    if len(clip.speed_curve) < 2:
        achain = _build_video_clip_audio_chain(
            input_label,
            clip,
            target_duration,
            delay_ms=delay_ms,
            total_duration=total_duration,
        )
        filters.append(",".join(achain) + out_label)
        return

    src_dur = clip.source_duration if clip.source_duration > 0 else clip.duration
    segs = _speed_curve_segments(src_dur, clip.speed_curve, fps)
    n_segs = len(segs)

    pre = [
        f"{input_label}aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo",
        f"atrim=0:{src_dur:.9f}",
        "asetpts=PTS-STARTPTS",
    ]
    if clip.reversed:
        pre.append("areverse")
        pre.append("asetpts=PTS-STARTPTS")
    as_in = f"[{tag_prefix}_asin]"
    filters.append(",".join(pre) + as_in)

    split_labels = "".join(f"[{tag_prefix}_as{k}]" for k in range(n_segs))
    filters.append(f"{as_in}asplit={n_segs}{split_labels}")

    concat_inputs: list[str] = []
    for k, (s0, s1, seg_speed) in enumerate(segs):
        seg_out = f"[{tag_prefix}_aso{k}]"
        seg_parts = [
            f"[{tag_prefix}_as{k}]atrim=start={s0:.9f}:end={s1:.9f}",
            "asetpts=PTS-STARTPTS",
        ]
        seg_parts.extend(_build_atempo_filters(seg_speed))
        filters.append(",".join(seg_parts) + seg_out)
        concat_inputs.append(seg_out)

    post_parts: list[str] = [f"concat=n={n_segs}:v=0:a=1"]
    post_parts.extend(_build_audio_fx_filters(clip.voice_cleanup, clip.audio_effect))
    kf_vol = _build_keyframe_expr(clip.keyframes, "volume", clip.volume, 0.0, time_var="t")
    if kf_vol is not None:
        post_parts.append(f"volume='clip({kf_vol},0,2)':eval=frame")
    else:
        post_parts.append(f"volume={clip.volume:.6f}")
    post_parts.append(f"apad=whole_dur={target_duration:.9f}")
    post_parts.append(f"atrim=0:{target_duration:.9f}")
    post_parts.append("asetpts=PTS-STARTPTS")
    if delay_ms > 0:
        post_parts.append(f"adelay={delay_ms}|{delay_ms}")
    if total_duration is not None:
        post_parts.append(f"apad=whole_dur={total_duration:.9f}")
        post_parts.append(f"atrim=0:{total_duration:.9f}")
        post_parts.append("asetpts=PTS-STARTPTS")
    filters.append("".join(concat_inputs) + ",".join(post_parts) + out_label)


def _between_bounds(start: float, end: float) -> tuple[float, float]:
    eps = 1e-4
    lo = start - eps
    hi = max(lo + 1e-5, end - eps)
    return lo, hi


def _render_transition_chain(
    chain: _VideoChain,
    folder: Path,
    *,
    ffmpeg: str,
    width: int,
    height: int,
    fps: int,
    log_fn: Callable[[str], Any],
) -> None:
    """Normalize clips in a same-track transition chain and xfade/acrossfade with 0-frame drift."""
    frame_counts = [max(1, int(round(c.duration * fps))) for c in chain.clips]
    trans_frames = [tr.frames for tr in chain.transitions]
    overlaps = [0] + trans_frames + [0]
    for idx, frames in enumerate(frame_counts):
        incoming, outgoing = overlaps[idx], overlaps[idx + 1]
        if max(incoming, outgoing) >= frames or incoming + outgoing > frames:
            raise ValueError(
                f"視訊軌「{chain.track_name}」第 {idx + 1} 段片長不足，請縮短相鄰轉場長度。"
            )

    segments: list[Path] = []
    any_audible = False

    for seg_idx, (clip, frames) in enumerate(zip(chain.clips, frame_counts)):
        seg_duration = frames / fps
        seg_path = folder / f"chain-{chain.track_idx:02d}-{chain.chain_idx:02d}-seg-{seg_idx:02d}.mp4"
        audible = (
            (not chain.track_muted)
            and (not clip.muted)
            and (not clip.freeze_frame)
            and clip.has_audio
            and (clip.volume > 1e-5 or _has_keyframe_prop(clip.keyframes, "volume"))
        )
        if audible:
            any_audible = True

        args: list[Any] = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
        args += _build_clip_input_args(clip, fps=fps, target_duration=seg_duration)

        if not audible:
            args += ["-f", "lavfi", "-t", f"{seg_duration:.9f}", "-i", "anullsrc=r=48000:cl=stereo"]

        use_custom_framing = _needs_pip_or_alpha(clip)
        seg_filters: list[str] = []
        fg_label, x_expr, y_expr = _append_clip_video_filters(
            seg_filters,
            input_label="[0:v]",
            tag_prefix="fg",
            clip=clip,
            canvas_w=width,
            canvas_h=height,
            fps=fps,
            target_duration=seg_duration,
            target_frames=frames,
            timeline_start=0.0,
            use_pip_alpha=use_custom_framing,
        )

        if use_custom_framing:
            eval_opt = ":eval=frame" if _has_keyframe_prop(clip.keyframes, "scale") else ""
            seg_filters.append(
                f"color=c=black:s={width}x{height}:r={fps}:d={seg_duration:.9f},format=rgba[bg]"
            )
            seg_filters.append(
                f"[bg]{fg_label}overlay=x={x_expr}:y={y_expr}{eval_opt}:eof_action=pass:format=auto,"
                f"trim=end_frame={frames},format=yuv420p[vout]"
            )
        else:
            seg_filters.append(f"{fg_label}trim=end_frame={frames},format=yuv420p[vout]")

        if audible:
            _append_video_clip_audio_filters(
                seg_filters,
                input_label="[0:a]",
                out_label="[aout]",
                tag_prefix=f"ca_{seg_idx}",
                clip=clip,
                target_duration=seg_duration,
                fps=fps,
            )
        else:
            seg_filters.append(
                f"[1:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
                f"atrim=0:{seg_duration:.9f},asetpts=PTS-STARTPTS[aout]"
            )

        args += [
            "-filter_complex",
            ";".join(seg_filters),
            "-map",
            "[vout]",
            "-map",
            "[aout]",
            "-t",
            f"{seg_duration:.9f}",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-preset",
            "veryfast",
            "-crf",
            "18",
            "-threads",
            "3",
            "-c:a",
            "aac",
            "-ar",
            "48000",
            "-ac",
            "2",
            "-b:a",
            "192k",
            seg_path,
        ]
        log_fn(f"標準化轉場片段 · {chain.track_name} ({seg_idx + 1}/{len(chain.clips)}) · {clip.path.name}")
        _run_cmd(args)
        segments.append(seg_path)

    # Compose exact frame-aligned xfade + acrossfade chain (0-frame drift).
    out_path = folder / f"chain-{chain.track_idx:02d}-{chain.chain_idx:02d}.mp4"
    compose_args: list[Any] = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-filter_complex_threads",
        "2",
    ]
    filters: list[str] = []
    for idx, (seg_path, frames) in enumerate(zip(segments, frame_counts)):
        compose_args += ["-threads", "2", "-i", seg_path]
        samples = int(round(frames * 48000 / fps))
        filters.extend(
            [
                f"[{idx}:v]format=yuv444p,tpad=stop_mode=clone:stop_duration={frames / fps:.9f},"
                f"trim=end_frame={frames},settb=1/{fps},setpts=N[v{idx}]",
                f"[{idx}:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
                f"apad=whole_len={samples},atrim=end_sample={samples},asetpts=N/SR/TB[a{idx}]",
            ]
        )

    cur_v, cur_a = "[v0]", "[a0]"
    length_frames = frame_counts[0]
    for idx, tr in enumerate(chain.transitions, 1):
        tr_frames = tr.frames
        next_v, next_a = f"[blendv{idx}]", f"[blenda{idx}]"
        offset_sec = (length_frames - tr_frames) / fps
        dur_sec = tr_frames / fps
        nb_samples = int(round(tr_frames * 48000 / fps))
        filters.extend(
            [
                f"{cur_v}[v{idx}]xfade=transition={tr.ffmpeg_kind}:duration={dur_sec:.9f}:offset={offset_sec:.9f}{next_v}",
                f"{cur_a}[a{idx}]acrossfade=nb_samples={nb_samples}{next_a}",
            ]
        )
        cur_v, cur_a = next_v, next_a
        length_frames += frame_counts[idx] - tr_frames

    final_v = "[vchain]"
    filters.append(f"{cur_v}trim=end_frame={length_frames},format=yuv420p{final_v}")

    log_fn(
        f"合成同軌轉場鏈 · {chain.track_name} · {len(chain.clips)} 段 / {len(chain.transitions)} 轉場 ({length_frames / fps:.2f}s)"
    )
    _run_cmd(
        [
            *compose_args,
            "-filter_complex",
            ";".join(filters),
            "-map",
            final_v,
            "-map",
            cur_a,
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-preset",
            "veryfast",
            "-crf",
            "18",
            "-threads",
            "3",
            "-c:a",
            "aac",
            "-ar",
            "48000",
            "-ac",
            "2",
            "-b:a",
            "192k",
            out_path,
        ]
    )

    chain.rendered_path = out_path
    chain.duration = length_frames / fps
    chain.has_chain_audio = any_audible


def _prepare_video_clip(
    raw_clip: dict[str, Any],
    *,
    track_idx: int,
    order_idx: int,
    track_name: str,
    track_muted: bool,
    timeline_start: float,
    width: int,
    height: int,
    fps: int,
    ffprobe: str,
) -> _PreparedVideoClip:
    """Parse and probe a raw VideoClip dict into a normalized _PreparedVideoClip."""
    if not isinstance(raw_clip, dict):
        raise ValueError(f"視訊軌「{track_name}」包含無效的片段設定。")
    path_raw = raw_clip.get("path")
    if not isinstance(path_raw, str) or not path_raw.strip():
        raise ValueError(f"視訊軌「{track_name}」第 {order_idx + 1} 段缺少素材路徑。")
    path = Path(path_raw)
    info = _probe_media(ffprobe, path)
    streams = info.get("streams") or []
    v_stream = next((s for s in streams if s.get("codec_type") == "video"), None)
    if v_stream is None:
        raise ValueError(f"視訊軌「{track_name}」素材 {path.name} 沒有影像軌。")

    ext = path.suffix.lower()
    is_image = ext in IMAGE_EXT
    has_audio = (not is_image) and any(s.get("codec_type") == "audio" for s in streams)
    pix_fmt = str(v_stream.get("pix_fmt") or "").lower()
    has_alpha = (pix_fmt in _ALPHA_PIX_FMTS) or (
        "a" in pix_fmt and pix_fmt.startswith(("rgb", "bgr", "yuv", "gbr", "ya"))
    )
    src_w = int(v_stream.get("width") or width)
    src_h = int(v_stream.get("height") or height)
    sar = _parse_sar(v_stream.get("sample_aspect_ratio"))

    probed_dur = _parse_float(info.get("format", {}).get("duration"), 0.0)
    if probed_dur <= 0 and not is_image:
        probed_dur = _parse_float(v_stream.get("duration"), 0.0)

    start_opt = _parse_optional_float(raw_clip.get("start"))
    end_opt = _parse_optional_float(raw_clip.get("end"))
    speed = _clamp(_parse_float(raw_clip.get("speed"), 1.0), 0.25, 4.0)
    speed_curve = _parse_speed_curve(raw_clip.get("speedCurve"))
    keyframes = _parse_keyframes(raw_clip.get("keyframes"))
    reversed_flag = bool(raw_clip.get("reversed", False))
    freeze_frame = bool(raw_clip.get("freezeFrame", False))

    if is_image:
        source_start = 0.0
        source_len = end_opt if end_opt is not None else 3.0
        speed_curve = []
        clip_dur = source_len / speed
        if source_len < 1.0 / fps or clip_dur < 1.0 / fps:
            raise ValueError(
                f"視訊軌「{track_name}」圖片 {path.name} 停留時間無效（須至少 {1.0 / fps:.2f} 秒）。"
            )
    else:
        source_start = start_opt if start_opt is not None else 0.0
        source_end = end_opt if end_opt is not None else probed_dur
        source_len = source_end - source_start
        if freeze_frame:
            speed_curve = []
        if len(speed_curve) >= 2:
            clip_dur = _speed_curve_output_duration(source_len, speed_curve, fps)
        else:
            clip_dur = source_len / speed
        if (
            source_start < 0
            or source_len < 1.0 / fps
            or clip_dur < 1.0 / fps
            or (probed_dur > 0 and source_end > probed_dur + 0.15)
        ):
            raise ValueError(
                f"視訊軌「{track_name}」片段 {path.name} 入出點無效（來源長度 {probed_dur:.2f} 秒）。"
            )

    pos_x = _clamp(_parse_float(raw_clip.get("posX"), 0.0), -1.0, 1.0)
    pos_y = _clamp(_parse_float(raw_clip.get("posY"), 0.0), -1.0, 1.0)
    scale = _clamp(_parse_float(raw_clip.get("scale"), 1.0), 0.1, 3.0)
    opacity = _clamp(_parse_float(raw_clip.get("opacity"), 1.0), 0.0, 1.0)
    volume = _clamp(_parse_float(raw_clip.get("volume"), 1.0), 0.0, 2.0)
    muted = bool(raw_clip.get("muted", False))
    clip_id = str(raw_clip.get("id") or f"v{track_idx}_clip_{order_idx}")

    flip_h = bool(raw_clip.get("flipH", False))
    flip_v = bool(raw_clip.get("flipV", False))
    rotation = _parse_float(raw_clip.get("rotation"), 0.0)
    crop_left = _clamp(_parse_float(raw_clip.get("cropLeft"), 0.0), 0.0, 0.45)
    crop_right = _clamp(_parse_float(raw_clip.get("cropRight"), 0.0), 0.0, 0.45)
    crop_top = _clamp(_parse_float(raw_clip.get("cropTop"), 0.0), 0.0, 0.45)
    crop_bottom = _clamp(_parse_float(raw_clip.get("cropBottom"), 0.0), 0.0, 0.45)
    filter_preset = _parse_filter_preset(raw_clip.get("filterPreset"))
    effect_id = _parse_visual_effect(raw_clip.get("effectId"))
    brightness = _clamp(_parse_float(raw_clip.get("brightness"), 0.0), -0.5, 0.5)
    contrast = _clamp(_parse_float(raw_clip.get("contrast"), 1.0), 0.5, 2.0)
    saturation = _clamp(_parse_float(raw_clip.get("saturation"), 1.0), 0.0, 2.5)
    blur = _clamp(_parse_float(raw_clip.get("blur"), 0.0), 0.0, 20.0)
    vignette = bool(raw_clip.get("vignette", False))
    stabilize_enabled = bool(raw_clip.get("stabilizeEnabled", False))
    stabilize_strength = _clamp(_parse_float(raw_clip.get("stabilizeStrength"), 0.5), 0.0, 1.0)
    enhance_clarity = _clamp(_parse_float(raw_clip.get("enhanceClarity"), 0.0), 0.0, 1.0)
    mask_kind = _parse_mask_kind(raw_clip.get("maskKind"))
    mask_feather = _clamp(_parse_float(raw_clip.get("maskFeather"), 0.12), 0.0, 0.5)
    mask_invert = bool(raw_clip.get("maskInvert", False))
    blend_mode = _parse_blend_mode(raw_clip.get("blendMode"))
    chroma_key_enabled = bool(raw_clip.get("chromaKeyEnabled", False))
    chroma_key_color = _parse_hex_color(raw_clip.get("chromaKeyColor"), "0x00FF00")
    chroma_key_similarity = _clamp(_parse_float(raw_clip.get("chromaKeySimilarity"), 0.18), 0.01, 0.5)
    chroma_key_blend = _clamp(_parse_float(raw_clip.get("chromaKeyBlend"), 0.08), 0.0, 0.5)
    animation_in = _parse_clip_animation(raw_clip.get("animationIn"))
    animation_out = _parse_clip_animation(raw_clip.get("animationOut"))
    animation_duration = _clamp(_parse_float(raw_clip.get("animationDuration"), 0.4), 0.0, 5.0)
    voice_cleanup = bool(raw_clip.get("voiceCleanup", False))
    audio_effect = _parse_audio_effect(raw_clip.get("audioEffect"))

    return _PreparedVideoClip(
        clip_id=clip_id,
        track_idx=track_idx,
        track_name=track_name,
        track_muted=track_muted,
        path=path,
        is_image=is_image,
        has_audio=has_audio,
        has_alpha=has_alpha,
        src_w=src_w,
        src_h=src_h,
        sar=sar,
        timeline_start=timeline_start,
        source_start=source_start,
        duration=clip_dur,
        pos_x=pos_x,
        pos_y=pos_y,
        scale=scale,
        opacity=opacity,
        volume=volume,
        muted=muted,
        source_duration=source_len,
        flip_h=flip_h,
        flip_v=flip_v,
        rotation=rotation,
        crop_left=crop_left,
        crop_right=crop_right,
        crop_top=crop_top,
        crop_bottom=crop_bottom,
        filter_preset=filter_preset,
        effect_id=effect_id,
        brightness=brightness,
        contrast=contrast,
        saturation=saturation,
        blur=blur,
        vignette=vignette,
        stabilize_enabled=stabilize_enabled,
        stabilize_strength=stabilize_strength,
        enhance_clarity=enhance_clarity,
        mask_kind=mask_kind,
        mask_feather=mask_feather,
        mask_invert=mask_invert,
        blend_mode=blend_mode,
        chroma_key_enabled=chroma_key_enabled,
        chroma_key_color=chroma_key_color,
        chroma_key_similarity=chroma_key_similarity,
        chroma_key_blend=chroma_key_blend,
        speed=speed,
        speed_curve=speed_curve,
        keyframes=keyframes,
        reversed=reversed_flag,
        freeze_frame=freeze_frame,
        animation_in=animation_in,
        animation_out=animation_out,
        animation_duration=animation_duration,
        voice_cleanup=voice_cleanup,
        audio_effect=audio_effect,
    )


# ---------------------------------------------------------------------------
# Main multi-track export API
# ---------------------------------------------------------------------------

def export_multitrack(
    request: dict[str, Any],
    folder: str | Path,
    *,
    ffmpeg: str,
    ffprobe: str,
    textrender_bin: Optional[str] = None,
    size: Optional[tuple[int, int]] = None,
    log_fn: Callable[[str], Any] = print,
) -> list[str]:
    """Render a multi-track timeline (video + transitions + PiP/alpha + audio + subtitles) to MP4."""
    if not isinstance(request, dict):
        raise ValueError("匯出請求格式無效。")
    dest_raw = request.get("destination")
    if not isinstance(dest_raw, str) or not dest_raw.strip():
        raise ValueError("請指定匯出目標檔案路徑。")
    destination = Path(dest_raw)
    if destination.suffix.lower() != ".mp4":
        raise ValueError("匯出檔名需使用 .mp4。")

    timeline = request.get("timeline")
    if not isinstance(timeline, dict):
        raise ValueError("請求缺少 timeline 多軌資料。")

    width, height = _resolve_output_size(request, size)
    fps_val = request.get("fps")
    if fps_val is None:
        fps_val = timeline.get("fps", 24)
    if not _is_number(fps_val) or not (1 <= int(round(fps_val)) <= 120):
        raise ValueError("時間軸影格率 fps 須為 1–120 之間的數字。")
    fps = int(round(fps_val))

    primary_enc, fallback_enc, supports_10bit, bit_depth, graph_pix_fmt = _resolve_video_encoder(
        request, log_fn, ffmpeg=ffmpeg
    )

    work_dir = Path(folder)
    work_dir.mkdir(parents=True, exist_ok=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    resolved_dest = destination.resolve()

    raw_video_tracks = timeline.get("videoTracks") or []
    raw_audio_tracks = timeline.get("audioTracks") or []
    raw_text_tracks = timeline.get("textTracks") or []
    raw_shape_tracks = timeline.get("shapeTracks") or []

    # 1. Safety check: never overwrite any input media file referenced anywhere on the timeline.
    all_video_clip_track_map: dict[str, int] = {}
    for t_idx, track in enumerate(raw_video_tracks):
        if not isinstance(track, dict):
            continue
        for clip in track.get("clips") or []:
            if not isinstance(clip, dict):
                continue
            cid = str(clip.get("id") or "")
            if cid:
                all_video_clip_track_map[cid] = t_idx
            clip_path_raw = clip.get("path")
            if isinstance(clip_path_raw, str) and clip_path_raw:
                if Path(clip_path_raw).resolve() == resolved_dest:
                    raise ValueError("匯出檔案路徑不可覆蓋時間軸中的原始視訊或圖片素材。")

    for track in raw_audio_tracks:
        if not isinstance(track, dict):
            continue
        for clip in track.get("clips") or []:
            if not isinstance(clip, dict):
                continue
            clip_path_raw = clip.get("path")
            if isinstance(clip_path_raw, str) and clip_path_raw:
                if Path(clip_path_raw).resolve() == resolved_dest:
                    raise ValueError("匯出檔案路徑不可覆蓋時間軸中的原始音訊素材。")

    # 2. Parse visible video tracks, probe media, validate same-track transitions, and group chains.
    video_chains: list[_VideoChain] = []
    for track_idx, track in enumerate(raw_video_tracks):
        if not isinstance(track, dict):
            continue
        if bool(track.get("hidden", False)):
            continue
        track_name = str(track.get("name") or f"V{track_idx + 1}")
        track_muted = bool(track.get("muted", False))
        raw_clips = track.get("clips") or []
        if not raw_clips:
            continue

        indexed_clips: list[tuple[float, int, dict[str, Any]]] = []
        for orig_idx, raw_clip in enumerate(raw_clips):
            if not isinstance(raw_clip, dict):
                raise ValueError(f"視訊軌「{track_name}」包含無效的片段設定。")
            t_start = _parse_float(raw_clip.get("timelineStart"), 0.0)
            if t_start < 0:
                raise ValueError(f"視訊軌「{track_name}」片段時間起點不可小於 0。")
            indexed_clips.append((t_start, orig_idx, raw_clip))
        indexed_clips.sort(key=lambda item: (item[0], item[1]))

        prepared_clips: list[_PreparedVideoClip] = []
        for order_idx, (t_start, _, raw_clip) in enumerate(indexed_clips):
            prepared_clips.append(
                _prepare_video_clip(
                    raw_clip,
                    track_idx=track_idx,
                    order_idx=order_idx,
                    track_name=track_name,
                    track_muted=track_muted,
                    timeline_start=t_start,
                    width=width,
                    height=height,
                    fps=fps,
                    ffprobe=ffprobe,
                )
            )

        # Validate same-track transitions.
        clip_index_by_id = {c.clip_id: idx for idx, c in enumerate(prepared_clips)}
        boundary_transitions: dict[int, _TransitionSpec] = {}
        for tr in track.get("transitions") or []:
            if not isinstance(tr, dict):
                raise ValueError(f"視訊軌「{track_name}」包含無效的轉場設定。")
            after_id = str(tr.get("after") or "")
            before_id = str(tr.get("before") or "")
            kind = str(tr.get("kind") or "")
            seconds = _parse_optional_float(tr.get("seconds"))
            if kind not in TIMELINE_EFFECTS:
                raise ValueError(f"視訊軌「{track_name}」使用了不支援的轉場效果：{kind!r}。")
            if seconds is None or not (0.1 <= seconds <= 3.0):
                raise ValueError(f"視訊軌「{track_name}」轉場秒數須介於 0.1–3.0 秒。")

            in_track_a = after_id in clip_index_by_id
            in_track_b = before_id in clip_index_by_id
            if not (in_track_a and in_track_b):
                other_a = all_video_clip_track_map.get(after_id)
                other_b = all_video_clip_track_map.get(before_id)
                if (other_a is not None and other_a != track_idx) or (other_b is not None and other_b != track_idx):
                    raise ValueError(
                        f"轉場（{after_id} -> {before_id}）跨越多個視訊軌，僅能套用於同一軌的相鄰片段。"
                    )
                log_fn(f"略過無效轉場（{after_id} -> {before_id}）：找不到對應片段。")
                continue

            idx_a = clip_index_by_id[after_id]
            idx_b = clip_index_by_id[before_id]
            if idx_b != idx_a + 1:
                raise ValueError(
                    f"視訊軌「{track_name}」轉場（{after_id} -> {before_id}）僅能套用於同一軌相鄰片段。"
                )

            clip_a = prepared_clips[idx_a]
            clip_b = prepared_clips[idx_b]
            gap = clip_b.timeline_start - (clip_a.timeline_start + clip_a.duration)
            if gap > 0.15:
                log_fn(
                    f"略過視訊軌「{track_name}」轉場（{after_id} -> {before_id}）：兩片段間隔 {gap:.2f} 秒而非接續或重疊。"
                )
                continue
            if idx_a in boundary_transitions:
                raise ValueError(f"視訊軌「{track_name}」同一交界重複設定了多個轉場。")

            tr_frames = max(1, int(round(seconds * fps)))
            boundary_transitions[idx_a] = _TransitionSpec(
                after_id=after_id,
                before_id=before_id,
                kind_name=kind,
                ffmpeg_kind=TIMELINE_EFFECTS[kind],
                seconds=seconds,
                frames=tr_frames,
            )

        # Group clips on this track into contiguous transition chains.
        chain_idx = 0
        cur_clips = [prepared_clips[0]]
        cur_trs: list[_TransitionSpec] = []
        for idx in range(len(prepared_clips) - 1):
            tr = boundary_transitions.get(idx)
            if tr is not None:
                cur_clips.append(prepared_clips[idx + 1])
                cur_trs.append(tr)
            else:
                video_chains.append(
                    _VideoChain(
                        track_idx=track_idx,
                        chain_idx=chain_idx,
                        track_name=track_name,
                        track_muted=track_muted,
                        clips=cur_clips,
                        transitions=cur_trs,
                        timeline_start=cur_clips[0].timeline_start,
                        duration=(
                            (
                                sum(max(1, int(round(c.duration * fps))) for c in cur_clips)
                                - sum(t.frames for t in cur_trs)
                            )
                            / fps
                            if cur_trs
                            else cur_clips[0].duration
                        ),
                    )
                )
                chain_idx += 1
                cur_clips = [prepared_clips[idx + 1]]
                cur_trs = []

        video_chains.append(
            _VideoChain(
                track_idx=track_idx,
                chain_idx=chain_idx,
                track_name=track_name,
                track_muted=track_muted,
                clips=cur_clips,
                transitions=cur_trs,
                timeline_start=cur_clips[0].timeline_start,
                duration=(
                    (
                        sum(max(1, int(round(c.duration * fps))) for c in cur_clips)
                        - sum(t.frames for t in cur_trs)
                    )
                    / fps
                    if cur_trs
                    else cur_clips[0].duration
                ),
            )
        )

    # 3. Parse unmuted audio tracks.
    prepared_audio_clips: list[_PreparedAudioClip] = []
    for a_idx, track in enumerate(raw_audio_tracks):
        if not isinstance(track, dict):
            continue
        if bool(track.get("muted", False)):
            continue
        track_name = str(track.get("name") or f"A{a_idx + 1}")
        track_vol = _clamp(_parse_float(track.get("volume"), 1.0), 0.0, 2.0)
        for c_idx, raw_clip in enumerate(track.get("clips") or []):
            if not isinstance(raw_clip, dict):
                raise ValueError(f"音訊軌「{track_name}」包含無效的音訊片段設定。")
            if bool(raw_clip.get("muted", False)):
                continue
            path_raw = raw_clip.get("path")
            if not isinstance(path_raw, str) or not path_raw.strip():
                raise ValueError(f"音訊軌「{track_name}」第 {c_idx + 1} 段缺少音訊路徑。")
            path = Path(path_raw)
            if path.suffix.lower() not in AUDIO_EXT:
                raise ValueError(f"音訊軌「{track_name}」不支援的音訊格式：{path.name}")
            info = _probe_media(ffprobe, path)
            streams = info.get("streams") or []
            a_stream = next((s for s in streams if s.get("codec_type") == "audio"), None)
            if a_stream is None:
                raise ValueError(f"音訊軌「{track_name}」檔案 {path.name} 沒有音訊軌。")

            probed_dur = _parse_float(info.get("format", {}).get("duration"), 0.0)
            if probed_dur <= 0:
                probed_dur = _parse_float(a_stream.get("duration"), 0.0)
            if probed_dur <= 0:
                raise ValueError(f"無法取得音訊檔案長度：{path.name}")

            t_start = _parse_float(raw_clip.get("timelineStart"), 0.0)
            s_start = _parse_float(raw_clip.get("sourceStart"), 0.0)
            s_end_opt = _parse_optional_float(raw_clip.get("sourceEnd"))
            s_end = probed_dur if s_end_opt is None else s_end_opt
            clip_dur = s_end - s_start
            if t_start < 0 or s_start < 0 or clip_dur <= 0.01 or s_end > probed_dur + 0.15:
                raise ValueError(
                    f"音訊軌「{track_name}」片段 {path.name} 時間範圍無效（來源長度 {probed_dur:.2f} 秒）。"
                )

            clip_vol = _clamp(_parse_float(raw_clip.get("volume"), 1.0), 0.0, 2.0)
            eff_vol = max(0.0, track_vol * clip_vol)
            fade_in = min(max(0.0, _parse_float(raw_clip.get("fadeIn"), 0.0)), clip_dur)
            fade_out = min(max(0.0, _parse_float(raw_clip.get("fadeOut"), 0.0)), clip_dur)
            a_voice_cleanup = bool(raw_clip.get("voiceCleanup", False))
            a_audio_effect = _parse_audio_effect(raw_clip.get("audioEffect"))
            a_keyframes = _parse_keyframes(raw_clip.get("keyframes"))

            prepared_audio_clips.append(
                _PreparedAudioClip(
                    clip_id=str(raw_clip.get("id") or f"a{a_idx}_clip_{c_idx}"),
                    track_name=track_name,
                    path=path,
                    timeline_start=t_start,
                    source_start=s_start,
                    source_end=min(s_end, probed_dur),
                    duration=clip_dur,
                    effective_volume=eff_vol,
                    fade_in=fade_in,
                    fade_out=fade_out,
                    voice_cleanup=a_voice_cleanup,
                    audio_effect=a_audio_effect,
                    keyframes=a_keyframes,
                )
            )

    # 4. Parse visible text tracks.
    prepared_text_clips: list[_PreparedTextClip] = []
    for t_idx, track in enumerate(raw_text_tracks):
        if not isinstance(track, dict):
            continue
        if bool(track.get("hidden", False)):
            continue
        track_name = str(track.get("name") or f"T{t_idx + 1}")
        for c_idx, raw_clip in enumerate(track.get("clips") or []):
            if not isinstance(raw_clip, dict):
                raise ValueError(f"文字軌「{track_name}」包含無效的文字片段設定。")
            text = str(raw_clip.get("text") or "")
            if not text.strip():
                continue
            t_start = _parse_float(raw_clip.get("timelineStart"), 0.0)
            dur = _parse_float(raw_clip.get("duration"), 0.0)
            if t_start < 0 or dur < 0.1:
                raise ValueError(f"文字軌「{track_name}」第 {c_idx + 1} 段字幕時間無效（長度須至少 0.1 秒）。")
            spec = {
                "width": width,
                "height": height,
                "text": text,
                "fontFamily": str(raw_clip.get("fontFamily") or "PingFang TC"),
                "fontSize": _parse_float(raw_clip.get("fontSize"), 48.0),
                "textColorHex": str(raw_clip.get("textColorHex") or "#FFFFFF"),
                "strokeColorHex": str(raw_clip.get("strokeColorHex") or "#000000"),
                "strokeWidth": _parse_float(raw_clip.get("strokeWidth"), 3.0),
                "shadowEnabled": bool(raw_clip.get("shadowEnabled", True)),
                "backgroundEnabled": bool(raw_clip.get("backgroundEnabled", True)),
                "backgroundColorHex": str(raw_clip.get("backgroundColorHex") or "#000000"),
                "backgroundOpacity": _clamp(_parse_float(raw_clip.get("backgroundOpacity"), 0.55), 0.0, 1.0),
                "posX": _clamp(_parse_float(raw_clip.get("posX"), 0.5), 0.0, 1.0),
                "posY": _clamp(_parse_float(raw_clip.get("posY"), 0.86), 0.0, 1.0),
            }
            prepared_text_clips.append(
                _PreparedTextClip(
                    clip_id=str(raw_clip.get("id") or f"t{t_idx}_clip_{c_idx}"),
                    track_name=track_name,
                    text=text,
                    timeline_start=t_start,
                    duration=dur,
                    spec=spec,
                )
            )

    # 4b. Parse visible shape tracks.
    prepared_shape_clips: list[_PreparedShapeClip] = []
    for s_idx, track in enumerate(raw_shape_tracks):
        if not isinstance(track, dict):
            continue
        if bool(track.get("hidden", False)):
            continue
        track_name = str(track.get("name") or f"S{s_idx + 1}")
        for c_idx, raw_clip in enumerate(track.get("clips") or []):
            if not isinstance(raw_clip, dict):
                raise ValueError(f"形狀軌「{track_name}」包含無效的形狀片段設定。")
            t_start = _parse_float(raw_clip.get("timelineStart"), 0.0)
            dur = _parse_float(raw_clip.get("duration"), 0.0)
            if t_start < 0 or dur < 0.1:
                raise ValueError(f"形狀軌「{track_name}」第 {c_idx + 1} 段形狀時間無效（長度須至少 0.1 秒）。")
            kind = str(raw_clip.get("kind") or "rounded_rect").strip().lower()
            if kind not in SHAPE_KINDS:
                raise ValueError(f"形狀軌「{track_name}」使用了不支援的形狀類型：{kind!r}。")
            spec = {
                "width": width,
                "height": height,
                "kind": kind,
                "posX": _clamp(_parse_float(raw_clip.get("posX"), 0.5), 0.0, 1.0),
                "posY": _clamp(_parse_float(raw_clip.get("posY"), 0.5), 0.0, 1.0),
                "shapeWidth": _clamp(_parse_float(raw_clip.get("shapeWidth"), 0.32), 0.01, 1.0),
                "shapeHeight": _clamp(_parse_float(raw_clip.get("shapeHeight"), 0.18), 0.01, 1.0),
                "rotation": _parse_float(raw_clip.get("rotation"), 0.0),
                "opacity": _clamp(_parse_float(raw_clip.get("opacity"), 1.0), 0.0, 1.0),
                "fillColorHex": str(raw_clip.get("fillColorHex") or "#2563EB"),
                "fillGradientEnabled": bool(raw_clip.get("fillGradientEnabled", False)),
                "fillGradientEndHex": str(raw_clip.get("fillGradientEndHex") or "#7C3AED"),
                "fillGradientAngle": _parse_float(raw_clip.get("fillGradientAngle"), 45.0),
                "strokeColorHex": str(raw_clip.get("strokeColorHex") or "#FFFFFF"),
                "strokeWidth": _clamp(_parse_float(raw_clip.get("strokeWidth"), 3.0), 0.0, 80.0),
                "cornerRadius": _clamp(_parse_float(raw_clip.get("cornerRadius"), 0.2), 0.0, 1.0),
                "shadowEnabled": bool(raw_clip.get("shadowEnabled", True)),
                "label": str(raw_clip.get("label") or ""),
                "labelColorHex": str(raw_clip.get("labelColorHex") or "#FFFFFF"),
                "labelFontSize": _clamp(_parse_float(raw_clip.get("labelFontSize"), 36.0), 8.0, 300.0),
                "labelFontFamily": str(raw_clip.get("labelFontFamily") or "PingFang TC"),
            }
            prepared_shape_clips.append(
                _PreparedShapeClip(
                    clip_id=str(raw_clip.get("id") or f"s{s_idx}_clip_{c_idx}"),
                    track_name=track_name,
                    timeline_start=t_start,
                    duration=dur,
                    spec=spec,
                )
            )

    # 5. Compute true total timeline duration (max end time across all active clips).
    end_times: list[float] = []
    for chain in video_chains:
        end_times.append(chain.timeline_start + chain.duration)
    for aclip in prepared_audio_clips:
        end_times.append(aclip.timeline_start + aclip.duration)
    for sclip in prepared_shape_clips:
        end_times.append(sclip.timeline_start + sclip.duration)
    for tclip in prepared_text_clips:
        end_times.append(tclip.timeline_start + tclip.duration)

    if not end_times or max(end_times) <= 0.0:
        raise ValueError("時間軸沒有可匯出的有效片段（請確認軌道未全部隱藏或靜音）。")

    raw_total_duration = max(end_times)
    total_frames = max(1, int(math.ceil(raw_total_duration * fps - 1e-6)))
    total_duration = total_frames / fps
    log_fn(
        f"多軌時間軸 · {width}×{height} · {fps}fps · 總長 {total_duration:.2f}s · "
        f"視訊鏈 {len(video_chains)} / 音訊段 {len(prepared_audio_clips)} / 形狀段 {len(prepared_shape_clips)} / 字幕段 {len(prepared_text_clips)}"
    )

    # 6. Pre-render same-track transition chains (len >= 2).
    for chain in video_chains:
        if len(chain.clips) >= 2:
            _render_transition_chain(
                chain,
                work_dir,
                ffmpeg=ffmpeg,
                width=width,
                height=height,
                fps=fps,
                log_fn=log_fn,
            )

    # 7. Pre-render transparent RGBA shape & subtitle PNGs via textrender CLI.
    if prepared_text_clips or prepared_shape_clips:
        resolved_tr = _resolve_textrender_bin(textrender_bin)
        if not resolved_tr:
            raise ValueError("找不到字幕/形狀渲染工具 textrender，無法繪製文字或形狀軌。")
        for idx, sclip in enumerate(prepared_shape_clips):
            spec_path = work_dir / f"shape-{idx:03d}.json"
            png_path = work_dir / f"shape-{idx:03d}.png"
            spec_path.write_text(json.dumps(sclip.spec, ensure_ascii=False, indent=2), encoding="utf-8")
            log_fn(f"渲染形狀 {idx + 1}/{len(prepared_shape_clips)} · {sclip.track_name}")
            _run_cmd([resolved_tr, "--shape", spec_path, png_path])
            if not png_path.is_file() or png_path.stat().st_size == 0:
                raise ValueError(f"textrender --shape 未產生有效的形狀圖檔：{png_path.name}")
            sclip.png_path = png_path
        for idx, tclip in enumerate(prepared_text_clips):
            spec_path = work_dir / f"text-{idx:03d}.json"
            png_path = work_dir / f"text-{idx:03d}.png"
            spec_path.write_text(json.dumps(tclip.spec, ensure_ascii=False, indent=2), encoding="utf-8")
            log_fn(f"渲染字幕 {idx + 1}/{len(prepared_text_clips)} · {tclip.track_name}")
            _run_cmd([resolved_tr, spec_path, png_path])
            if not png_path.is_file() or png_path.stat().st_size == 0:
                raise ValueError(f"textrender 未產生有效的字幕圖檔：{png_path.name}")
            tclip.png_path = png_path

    # 8. Build master multi-track FFmpeg filter graph (video layers + text layers + audio mix).
    cmd: list[Any] = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-filter_complex_threads",
        "2",
    ]
    filters: list[str] = []
    input_idx = 0

    # Base black RGBA canvas at exact fps and total_duration.
    filters.append(
        f"color=c=black:s={width}x{height}:r={fps}:d={total_duration:.9f},"
        f"settb=1/{fps},format=rgba[base0]"
    )
    current_v = "[base0]"
    v_step = 0

    # Collect audio streams for final amix.
    audio_labels: list[str] = []
    audio_counter = 0

    # Add video chains in bottom-to-top track order (V1 -> V2 -> ...).
    for chain in video_chains:
        if len(chain.clips) >= 2:
            assert chain.rendered_path is not None
            cur_input = input_idx
            input_idx += 1
            cmd += ["-threads", "2", "-i", chain.rendered_path]

            c_start = chain.timeline_start
            c_dur = chain.duration
            c_end = c_start + c_dur
            lo, hi = _between_bounds(c_start, c_end)

            v_tag = f"[vc_{v_step}]"
            next_v = f"[comp_{v_step + 1}]"
            filters.append(
                f"[{cur_input}:v]fps={fps},format=rgba,"
                f"tpad=stop_mode=clone:stop_duration=0.1,trim=duration={c_dur + 0.05:.9f},"
                f"setpts=PTS-STARTPTS+{c_start:.6f}/TB{v_tag}"
            )
            filters.append(
                f"{current_v}{v_tag}overlay=x=0:y=0:enable='between(t,{lo:.6f},{hi:.6f})':"
                f"eof_action=pass:repeatlast=0:format=auto{next_v}"
            )
            current_v = next_v
            v_step += 1

            if chain.has_chain_audio and not chain.track_muted:
                a_tag = f"[aud_{audio_counter}]"
                audio_counter += 1
                delay_ms = int(round(c_start * 1000.0))
                achain = [
                    f"[{cur_input}:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo",
                    f"atrim=0:{c_dur:.9f}",
                    "asetpts=PTS-STARTPTS",
                ]
                if delay_ms > 0:
                    achain.append(f"adelay={delay_ms}|{delay_ms}")
                achain.append(f"apad=whole_dur={total_duration:.9f}")
                achain.append(f"atrim=0:{total_duration:.9f}")
                achain.append("asetpts=PTS-STARTPTS")
                filters.append(",".join(achain) + a_tag)
                audio_labels.append(a_tag)
        else:
            clip = chain.clips[0]
            need_visual = clip.opacity > 1e-4 or _has_keyframe_prop(clip.keyframes, "opacity")
            need_audio = (
                (not chain.track_muted)
                and (not clip.muted)
                and (not clip.freeze_frame)
                and clip.has_audio
                and (clip.volume > 1e-5 or _has_keyframe_prop(clip.keyframes, "volume"))
            )
            if not need_visual and not need_audio:
                continue

            cur_input = input_idx
            input_idx += 1
            cmd += _build_clip_input_args(clip, fps=fps, target_duration=clip.duration)

            c_start = clip.timeline_start
            c_dur = clip.duration
            c_end = c_start + c_dur
            lo, hi = _between_bounds(c_start, c_end)

            if need_visual:
                next_v = f"[comp_{v_step + 1}]"
                eval_opt = ":eval=frame" if _has_keyframe_prop(clip.keyframes, "scale") else ""
                v_tag, x_expr, y_expr = _append_clip_video_filters(
                    filters,
                    input_label=f"[{cur_input}:v]",
                    tag_prefix=f"vc_{v_step}",
                    clip=clip,
                    canvas_w=width,
                    canvas_h=height,
                    fps=fps,
                    target_duration=c_dur,
                    target_frames=None,
                    timeline_start=c_start,
                    use_pip_alpha=_needs_pip_or_alpha(clip),
                )
                if clip.blend_mode != "normal":
                    # True RGB-space blend mode preserving clip alpha/mask/PiP bounds and timeline window.
                    b_prefix = f"bm_{v_step}"
                    filters.append(
                        f"color=c=black@0.0:s={width}x{height}:r={fps}:d={total_duration:.9f},"
                        f"settb=1/{fps},format=rgba[{b_prefix}_fbg]"
                    )
                    filters.append(
                        f"[{b_prefix}_fbg]{v_tag}overlay=x={x_expr}:y={y_expr}{eval_opt}:"
                        f"enable='between(t,{lo:.6f},{hi:.6f})':eof_action=pass:repeatlast=0:format=auto,"
                        f"format=rgba,split[{b_prefix}_fgc][{b_prefix}_fga]"
                    )
                    filters.append(f"[{b_prefix}_fga]alphaextract[{b_prefix}_alpha]")
                    filters.append(f"{current_v}split[{b_prefix}_orig][{b_prefix}_base]")
                    filters.append(f"[{b_prefix}_base]format=rgb24[{b_prefix}_brgb]")
                    filters.append(f"[{b_prefix}_fgc]format=rgb24[{b_prefix}_frgb]")
                    filters.append(
                        f"[{b_prefix}_brgb][{b_prefix}_frgb]blend=all_mode={clip.blend_mode}:all_opacity=1.0,"
                        f"format=rgba[{b_prefix}_blended]"
                    )
                    filters.append(
                        f"[{b_prefix}_blended][{b_prefix}_alpha]alphamerge,format=rgba[{b_prefix}_rgba]"
                    )
                    filters.append(
                        f"[{b_prefix}_orig][{b_prefix}_rgba]overlay=x=0:y=0:"
                        f"enable='between(t,{lo:.6f},{hi:.6f})':eof_action=pass:repeatlast=0:format=auto{next_v}"
                    )
                else:
                    filters.append(
                        f"{current_v}{v_tag}overlay=x={x_expr}:y={y_expr}{eval_opt}:"
                        f"enable='between(t,{lo:.6f},{hi:.6f})':eof_action=pass:repeatlast=0:format=auto{next_v}"
                    )
                current_v = next_v
                v_step += 1

            if need_audio:
                a_tag = f"[aud_{audio_counter}]"
                audio_counter += 1
                delay_ms = int(round(c_start * 1000.0))
                _append_video_clip_audio_filters(
                    filters,
                    input_label=f"[{cur_input}:a]",
                    out_label=a_tag,
                    tag_prefix=f"va_{audio_counter}",
                    clip=clip,
                    target_duration=c_dur,
                    fps=fps,
                    delay_ms=delay_ms,
                    total_duration=total_duration,
                )
                audio_labels.append(a_tag)

    # Overlay rendered editable shape PNGs above video tracks and below text tracks.
    for idx, sclip in enumerate(prepared_shape_clips):
        assert sclip.png_path is not None
        cur_input = input_idx
        input_idx += 1
        cmd += [
            "-loop",
            "1",
            "-framerate",
            str(fps),
            "-t",
            f"{sclip.duration + 0.1:.9f}",
            "-i",
            sclip.png_path,
        ]
        s_start = sclip.timeline_start
        s_end = s_start + sclip.duration
        lo, hi = _between_bounds(s_start, s_end)

        shp_tag = f"[shp_{idx}]"
        next_v = f"[comp_{v_step + 1}]"
        filters.append(
            f"[{cur_input}:v]fps={fps},format=rgba,"
            f"tpad=stop_mode=clone:stop_duration=0.1,trim=duration={sclip.duration + 0.05:.9f},"
            f"setpts=PTS-STARTPTS+{s_start:.6f}/TB{shp_tag}"
        )
        filters.append(
            f"{current_v}{shp_tag}overlay=x=0:y=0:"
            f"enable='between(t,{lo:.6f},{hi:.6f})':eof_action=pass:repeatlast=0:format=auto{next_v}"
        )
        current_v = next_v
        v_step += 1

    # Overlay rendered text PNGs on top of all video and shape tracks.
    for idx, tclip in enumerate(prepared_text_clips):
        assert tclip.png_path is not None
        cur_input = input_idx
        input_idx += 1
        cmd += [
            "-loop",
            "1",
            "-framerate",
            str(fps),
            "-t",
            f"{tclip.duration + 0.1:.9f}",
            "-i",
            tclip.png_path,
        ]
        t_start = tclip.timeline_start
        t_end = t_start + tclip.duration
        lo, hi = _between_bounds(t_start, t_end)

        txt_tag = f"[txt_{idx}]"
        next_v = f"[comp_{v_step + 1}]"
        filters.append(
            f"[{cur_input}:v]fps={fps},format=rgba,"
            f"tpad=stop_mode=clone:stop_duration=0.1,trim=duration={tclip.duration + 0.05:.9f},"
            f"setpts=PTS-STARTPTS+{t_start:.6f}/TB{txt_tag}"
        )
        filters.append(
            f"{current_v}{txt_tag}overlay=x=0:y=0:"
            f"enable='between(t,{lo:.6f},{hi:.6f})':eof_action=pass:repeatlast=0:format=auto{next_v}"
        )
        current_v = next_v
        v_step += 1

    # Finalize video stream to exact total_frames & target output pixel format.
    filters.append(f"{current_v}trim=end_frame={total_frames},format={graph_pix_fmt}[vout]")

    # Add dedicated audio track clips.
    for aclip in prepared_audio_clips:
        has_vol_kf = _has_keyframe_prop(aclip.keyframes, "volume")
        if aclip.effective_volume <= 1e-5 and not has_vol_kf:
            continue
        cur_input = input_idx
        input_idx += 1
        cmd += ["-i", aclip.path]

        a_tag = f"[aud_{audio_counter}]"
        audio_counter += 1
        delay_ms = int(round(aclip.timeline_start * 1000.0))
        achain = [
            f"[{cur_input}:a]aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo",
            f"atrim=start={aclip.source_start:.9f}:end={aclip.source_end:.9f}",
            "asetpts=PTS-STARTPTS",
        ]
        achain.extend(_build_audio_fx_filters(aclip.voice_cleanup, aclip.audio_effect))
        kf_vol = _build_keyframe_expr(aclip.keyframes, "volume", aclip.effective_volume, 0.0, time_var="t")
        if kf_vol is not None:
            achain.append(f"volume='clip({kf_vol},0,2)':eval=frame")
        else:
            achain.append(f"volume={aclip.effective_volume:.6f}")
        if aclip.fade_in > 1e-4:
            achain.append(f"afade=t=in:st=0:d={aclip.fade_in:.6f}")
        if aclip.fade_out > 1e-4:
            out_start = max(0.0, aclip.duration - aclip.fade_out)
            achain.append(f"afade=t=out:st={out_start:.6f}:d={aclip.fade_out:.6f}")
        achain.append(f"apad=whole_dur={aclip.duration:.9f}")
        achain.append(f"atrim=0:{aclip.duration:.9f}")
        achain.append("asetpts=PTS-STARTPTS")
        if delay_ms > 0:
            achain.append(f"adelay={delay_ms}|{delay_ms}")
        achain.append(f"apad=whole_dur={total_duration:.9f}")
        achain.append(f"atrim=0:{total_duration:.9f}")
        achain.append("asetpts=PTS-STARTPTS")
        filters.append(",".join(achain) + a_tag)
        audio_labels.append(a_tag)

    # Base silent stereo bed + amix (normalize=0) + gentle alimiter.
    filters.append(
        f"anullsrc=r=48000:cl=stereo:d={total_duration:.9f},"
        f"aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,"
        f"atrim=0:{total_duration:.9f}[abase]"
    )
    if audio_labels:
        mix_inputs = "[abase]" + "".join(audio_labels)
        filters.append(
            f"{mix_inputs}amix=inputs={len(audio_labels) + 1}:duration=first:normalize=0,"
            f"alimiter=limit=0.98:level=false:attack=5:release=50,"
            f"atrim=0:{total_duration:.9f}[aout]"
        )
    else:
        filters.append("[abase]acopy[aout]")

    filter_graph = ";\n".join(filters)
    filter_file = work_dir / "filter_complex.txt"
    filter_file.write_text(filter_graph, encoding="utf-8")

    # Use -/filter_complex when graph is large (FFmpeg 7/8 standard); inline otherwise.
    if len(filter_graph) > 32768:
        cmd += ["-/filter_complex", filter_file]
    else:
        cmd += ["-filter_complex", ";".join(filters)]

    tmp = destination.with_name(f".{destination.stem}-{uuid4().hex}.mp4")
    try:
        log_fn(
            f"合成多軌畫面與混音輸出 · {destination.name} · {primary_enc} · {bit_depth}-bit · {fps}fps"
        )
        base_out_args: list[Any] = [
            *cmd,
            "-map",
            "[vout]",
            "-map",
            "[aout]",
            "-r",
            str(fps),
        ]
        audio_out_args: list[Any] = [
            "-c:a",
            "aac",
            "-ar",
            "48000",
            "-ac",
            "2",
            "-b:a",
            "192k",
            "-movflags",
            "+faststart",
            tmp,
        ]
        try:
            _run_cmd(
                [
                    *base_out_args,
                    *_encoder_output_args(primary_enc, supports_10bit, bit_depth),
                    *audio_out_args,
                ]
            )
        except ValueError as hw_exc:
            if fallback_enc is None:
                raise
            tmp.unlink(missing_ok=True)
            fb_supports_10 = fallback_enc in {"libx265", "libsvtav1"}
            fb_bit_depth = bit_depth if fb_supports_10 else 8
            log_fn(
                f"編碼器 {primary_enc} 失敗，自動切換 CPU 編碼器 {fallback_enc} 重試。（{hw_exc}）"
            )
            _run_cmd(
                [
                    *base_out_args,
                    *_encoder_output_args(fallback_enc, fb_supports_10, fb_bit_depth),
                    *audio_out_args,
                ]
            )
        if not tmp.is_file() or tmp.stat().st_size == 0:
            raise ValueError("FFmpeg 未產生有效的輸出檔案。")
        tmp.replace(destination)
    finally:
        tmp.unlink(missing_ok=True)

    return [str(destination)]


# ---------------------------------------------------------------------------
# Same-source transition preview cache renderer
# ---------------------------------------------------------------------------

def render_transition_cache(
    spec: dict[str, Any],
    output_path: Path | str,
    *,
    ffmpeg: str,
    ffprobe: str,
    log_fn: Callable[[str], Any] = print,
) -> str:
    """Render an exact video-only transition overlap clip sharing the exact export pipeline.

    Outputs exactly `overlap_frames = max(1, round(duration * fps))` frames spanning
    `[leading_frames - overlap_frames, leading_frames)` of leadingClip blended with
    `[0, overlap_frames)` of trailingClip via FFmpeg `xfade`, atomically written to `output_path`.
    """
    if not isinstance(spec, dict):
        raise ValueError("轉場快取規格 spec 須為 JSON 物件。")

    destination = Path(output_path)
    if destination.suffix.lower() != ".mp4":
        raise ValueError("轉場快取輸出檔名需使用 .mp4。")

    kind = str(spec.get("kind") or "").strip()
    if kind not in TIMELINE_EFFECTS:
        raise ValueError(f"不支援的轉場效果：{kind!r}。")
    ffmpeg_kind = TIMELINE_EFFECTS[kind]

    duration = _parse_optional_float(spec.get("duration"))
    if duration is None or not (0.05 <= duration <= 10.0):
        raise ValueError(f"轉場快取秒數無效：{spec.get('duration')!r}（須介於 0.05–10.0 秒）。")

    width = spec.get("width", 640)
    height = spec.get("height", 360)
    if (
        type(width) is not int
        or type(height) is not int
        or not (64 <= width <= 4096)
        or not (64 <= height <= 4096)
        or width % 2 != 0
        or height % 2 != 0
    ):
        raise ValueError("轉場快取寬高須為 64–4096 之間的偶數整數。")

    fps_val = spec.get("fps", 24)
    if not _is_number(fps_val) or not (1 <= int(round(fps_val)) <= 120):
        raise ValueError("轉場快取影格率 fps 須為 1–120 之間的數字。")
    fps = int(round(fps_val))

    leading_raw = spec.get("leadingClip")
    trailing_raw = spec.get("trailingClip")
    if not isinstance(leading_raw, dict) or not isinstance(trailing_raw, dict):
        raise ValueError("轉場快取規格缺少 leadingClip 或 trailingClip。")

    destination.parent.mkdir(parents=True, exist_ok=True)
    resolved_dest = destination.resolve()
    for side_label, raw_side in (("leadingClip", leading_raw), ("trailingClip", trailing_raw)):
        p_raw = raw_side.get("path")
        if isinstance(p_raw, str) and p_raw.strip():
            if Path(p_raw).resolve() == resolved_dest:
                raise ValueError(f"轉場快取輸出路徑不可覆蓋 {side_label} 原始素材。")

    clip_a = _prepare_video_clip(
        leading_raw,
        track_idx=0,
        order_idx=0,
        track_name="Cache",
        track_muted=True,
        timeline_start=0.0,
        width=width,
        height=height,
        fps=fps,
        ffprobe=ffprobe,
    )
    clip_b = _prepare_video_clip(
        trailing_raw,
        track_idx=0,
        order_idx=1,
        track_name="Cache",
        track_muted=True,
        timeline_start=0.0,
        width=width,
        height=height,
        fps=fps,
        ffprobe=ffprobe,
    )

    frames_a = max(1, int(round(clip_a.duration * fps)))
    frames_b = max(1, int(round(clip_b.duration * fps)))
    overlap_frames = max(1, int(round(duration * fps)))
    if overlap_frames > frames_a or overlap_frames > frames_b:
        raise ValueError(
            f"轉場快取長度（{overlap_frames} 幀）超過片段可用幀數（A={frames_a}, B={frames_b}）。"
        )

    dur_a = frames_a / fps
    dur_b = frames_b / fps
    overlap_dur = overlap_frames / fps
    start_frame_a = frames_a - overlap_frames

    cmd: list[Any] = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-filter_complex_threads",
        "2",
    ]
    cmd += _build_clip_input_args(clip_a, fps=fps, target_duration=dur_a)
    cmd += _build_clip_input_args(clip_b, fps=fps, target_duration=dur_b)

    filters: list[str] = []

    # Leading clip full same-source preprocessing, then slice exact trailing overlap window.
    use_pip_a = _needs_pip_or_alpha(clip_a)
    fg_a, xa, ya = _append_clip_video_filters(
        filters,
        input_label="[0:v]",
        tag_prefix="fg_a",
        clip=clip_a,
        canvas_w=width,
        canvas_h=height,
        fps=fps,
        target_duration=dur_a,
        target_frames=frames_a,
        timeline_start=0.0,
        use_pip_alpha=use_pip_a,
    )
    if use_pip_a:
        filters.append(f"color=c=black:s={width}x{height}:r={fps}:d={dur_a:.9f},format=rgba[bg_a]")
        filters.append(
            f"[bg_a]{fg_a}overlay=x={xa}:y={ya}:eof_action=pass:format=auto,"
            f"trim=end_frame={frames_a}[seg_a]"
        )
    else:
        filters.append(f"{fg_a}trim=end_frame={frames_a}[seg_a]")
    filters.append(
        f"[seg_a]format=yuv444p,tpad=stop_mode=clone:stop_duration={dur_a:.9f},"
        f"trim=start_frame={start_frame_a}:end_frame={frames_a},settb=1/{fps},setpts=N[va]"
    )

    # Trailing clip full same-source preprocessing, then slice exact leading overlap window.
    use_pip_b = _needs_pip_or_alpha(clip_b)
    fg_b, xb, yb = _append_clip_video_filters(
        filters,
        input_label="[1:v]",
        tag_prefix="fg_b",
        clip=clip_b,
        canvas_w=width,
        canvas_h=height,
        fps=fps,
        target_duration=dur_b,
        target_frames=frames_b,
        timeline_start=0.0,
        use_pip_alpha=use_pip_b,
    )
    if use_pip_b:
        filters.append(f"color=c=black:s={width}x{height}:r={fps}:d={dur_b:.9f},format=rgba[bg_b]")
        filters.append(
            f"[bg_b]{fg_b}overlay=x={xb}:y={yb}:eof_action=pass:format=auto,"
            f"trim=end_frame={frames_b}[seg_b]"
        )
    else:
        filters.append(f"{fg_b}trim=end_frame={frames_b}[seg_b]")
    filters.append(
        f"[seg_b]format=yuv444p,tpad=stop_mode=clone:stop_duration={dur_b:.9f},"
        f"trim=start_frame=0:end_frame={overlap_frames},settb=1/{fps},setpts=N[vb]"
    )

    # Exact xfade over the sliced overlap window [0, overlap_frames).
    filters.append(
        f"[va][vb]xfade=transition={ffmpeg_kind}:duration={overlap_dur:.9f}:offset=0,"
        f"trim=end_frame={overlap_frames},format=yuv420p[vout]"
    )

    tmp = destination.with_name(f".{destination.stem}-{uuid4().hex}.mp4")
    try:
        log_fn(
            f"渲染同源轉場快取 · {kind} · {overlap_frames} 幀 ({overlap_dur:.3f}s @ {fps}fps, {width}×{height})"
        )
        _run_cmd(
            [
                *cmd,
                "-filter_complex",
                ";".join(filters),
                "-map",
                "[vout]",
                "-an",
                "-r",
                str(fps),
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-preset",
                "veryfast",
                "-crf",
                "19",
                "-threads",
                "3",
                "-movflags",
                "+faststart",
                tmp,
            ]
        )
        if not tmp.is_file() or tmp.stat().st_size == 0:
            raise ValueError("FFmpeg 未產生有效的轉場快取檔案。")
        tmp.replace(destination)
    finally:
        tmp.unlink(missing_ok=True)

    return str(destination)


def render_clip_preview(
    spec: dict[str, Any],
    output_path: str | Path,
    *,
    ffmpeg: str,
    ffprobe: str,
    log: Optional[Callable[[str], None]] = None,
) -> str:
    """Render a same-source processed clip preview matching export_multitrack pixel semantics.

    Reuses the exact `_prepare_video_clip` + `_build_clip_input_args` +
    `_append_clip_video_filters` pipeline used by `export_multitrack` so that
    crop-then-rescale, filterPreset (warm/cool/vintage/bw_high/vivid/soft/vignette),
    eq/blur/vignette, flipH/V, rotation, speed, reversed, freezeFrame, and
    green-screen chromaKey match final exports.

    `alphaMode`:
      - "opaque_mp4": standard yuv420p H.264 MP4 for non-alpha clips.
      - "stacked_mp4": standard yuv420p H.264 MP4 with top half = processed RGB
        (WxH) and bottom half = exact FFmpeg `alphaextract` mask (WxH), enabling
        true hardware-independent alpha compositing in the macOS monitor.
      - "rgba_png": single-frame RGBA PNG for still images or freeze-frame clips
        with alpha transparency (chromaKey / rotation).
    """
    log_fn = log or (lambda _msg: None)
    if not isinstance(spec, dict):
        raise ValueError("片段效果預覽設定格式無效。")

    raw_clip = spec.get("clip")
    if not isinstance(raw_clip, dict):
        raise ValueError("片段效果預覽缺少 clip 參數。")

    alpha_mode = str(spec.get("alphaMode") or "opaque_mp4").strip().lower()
    if alpha_mode not in {"opaque_mp4", "stacked_mp4", "rgba_png"}:
        raise ValueError(f"不支援的預覽 Alpha 模式：{alpha_mode}")

    width = max(64, (int(round(_parse_float(spec.get("width"), 640.0))) // 2) * 2)
    height = max(64, (int(round(_parse_float(spec.get("height"), 360.0))) // 2) * 2)
    fps = max(12, min(60, int(round(_parse_float(spec.get("fps"), 24.0)))))

    # Neutralize canvas transform/opacity/animation in cached clip preview so live
    # monitor drag/resize/fade stays 60fps without re-rendering FFmpeg cache.
    normalized_raw = dict(raw_clip)
    normalized_raw["posX"] = 0.0
    normalized_raw["posY"] = 0.0
    normalized_raw["scale"] = 1.0
    normalized_raw["opacity"] = 1.0
    normalized_raw["animationIn"] = "none"
    normalized_raw["animationOut"] = "none"

    destination = Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)

    clip = _prepare_video_clip(
        normalized_raw,
        track_idx=1 if alpha_mode != "opaque_mp4" else 0,
        order_idx=0,
        track_name="ClipPreview",
        track_muted=True,
        timeline_start=0.0,
        width=width,
        height=height,
        fps=fps,
        ffprobe=ffprobe,
    )

    is_still_png = alpha_mode == "rgba_png"
    frames = 1 if is_still_png else max(1, int(round(clip.duration * fps)))
    dur = frames / fps
    use_alpha_canvas = (
        alpha_mode in {"stacked_mp4", "rgba_png"}
        or clip.chroma_key_enabled
        or clip.mask_kind != "none"
        or abs(clip.rotation) > 0.01
    )

    cmd: list[Any] = [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-filter_complex_threads",
        "2",
    ]
    cmd += _build_clip_input_args(clip, fps=fps, target_duration=max(dur, 1.0 / fps))

    filters: list[str] = []
    fg_label, _, _ = _append_clip_video_filters(
        filters,
        input_label="[0:v]",
        tag_prefix="fg_p",
        clip=clip,
        canvas_w=width,
        canvas_h=height,
        fps=fps,
        target_duration=dur,
        target_frames=frames,
        timeline_start=0.0,
        use_pip_alpha=use_alpha_canvas,
    )
    eval_opt = ":eval=frame" if _has_keyframe_prop(clip.keyframes, "scale") else ""

    if alpha_mode == "rgba_png":
        filters.append(f"color=c=black@0.0:s={width}x{height}:r={fps}:d={max(dur, 1.0 / fps):.9f},format=rgba[bg]")
        filters.append(
            f"[bg]{fg_label}overlay=(W-w)/2:(H-h)/2{eval_opt}:eof_action=pass:format=auto,"
            f"trim=end_frame=1,format=rgba[vout]"
        )
        tmp = destination.with_name(f".{destination.stem}-{uuid4().hex}.png")
        try:
            log_fn(f"渲染同源去背靜態預覽 · {width}×{height} · RGBA PNG")
            _run_cmd(
                [
                    *cmd,
                    "-filter_complex",
                    ";".join(filters),
                    "-map",
                    "[vout]",
                    "-frames:v",
                    "1",
                    "-c:v",
                    "png",
                    "-pix_fmt",
                    "rgba",
                    tmp,
                ]
            )
            if not tmp.is_file() or tmp.stat().st_size == 0:
                raise ValueError("FFmpeg 未產生有效的去背靜態預覽檔。")
            tmp.replace(destination)
        finally:
            tmp.unlink(missing_ok=True)
        return str(destination)

    if alpha_mode == "stacked_mp4":
        filters.append(f"color=c=black@0.0:s={width}x{height}:r={fps}:d={dur:.9f},format=rgba[bg]")
        filters.append(
            f"[bg]{fg_label}overlay=(W-w)/2:(H-h)/2{eval_opt}:eof_action=pass:format=auto,"
            f"trim=end_frame={frames},format=rgba,split[rgba_c][rgba_a]"
        )
        filters.append("[rgba_c]format=yuv420p,setsar=1[rgb]")
        filters.append("[rgba_a]alphaextract,format=yuv420p,setsar=1[msk]")
        filters.append("[rgb][msk]vstack=inputs=2[vout]")
    else:
        if use_alpha_canvas:
            filters.append(f"color=c=black:s={width}x{height}:r={fps}:d={dur:.9f},format=rgba[bg]")
            filters.append(
                f"[bg]{fg_label}overlay=(W-w)/2:(H-h)/2{eval_opt}:eof_action=pass:format=auto,"
                f"trim=end_frame={frames},format=yuv420p[vout]"
            )
        else:
            filters.append(f"{fg_label}trim=end_frame={frames},format=yuv420p[vout]")

    tmp = destination.with_name(f".{destination.stem}-{uuid4().hex}.mp4")
    try:
        log_fn(
            f"渲染同源片段效果預覽 · {alpha_mode} · {frames} 幀 ({dur:.3f}s @ {fps}fps, {width}×{height})"
        )
        _run_cmd(
            [
                *cmd,
                "-filter_complex",
                ";".join(filters),
                "-map",
                "[vout]",
                "-an",
                "-r",
                str(fps),
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-preset",
                "veryfast",
                "-crf",
                "19",
                "-threads",
                "3",
                "-movflags",
                "+faststart",
                tmp,
            ]
        )
        if not tmp.is_file() or tmp.stat().st_size == 0:
            raise ValueError("FFmpeg 未產生有效的片段效果預覽快取。")
        tmp.replace(destination)
    finally:
        tmp.unlink(missing_ok=True)

    return str(destination)


# ---------------------------------------------------------------------------
# Audio FX audition preview & Edit Proxy generator
# ---------------------------------------------------------------------------

def preview_audio_fx(
    src_path: str | Path,
    fx_id: str,
    out_wav: str | Path,
    *,
    ffmpeg: str,
    max_duration: float = 8.0,
    log_fn: Callable[[str], Any] = print,
) -> str:
    """Render up to `max_duration` seconds of audio/video source through one of the 25 audio FX to WAV."""
    source = Path(src_path)
    if not source.is_file():
        raise ValueError(f"找不到音效試聽來源檔案：{source}")
    effect_key = _parse_audio_effect(fx_id)
    destination = Path(out_wav)
    if destination.suffix.lower() != ".wav":
        raise ValueError("音效試聽輸出檔名需使用 .wav。")
    if source.resolve() == destination.resolve():
        raise ValueError("音效試聽輸出不可覆蓋原始來源檔案。")
    destination.parent.mkdir(parents=True, exist_ok=True)

    dur = _clamp(float(max_duration), 0.5, 30.0)
    achain = [
        "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo",
        f"atrim=0:{dur:.6f}",
        "asetpts=PTS-STARTPTS",
    ]
    achain.extend(_build_audio_fx_filters(False, effect_key))
    achain.append("alimiter=limit=0.96:level=false:attack=5:release=50")

    tmp = destination.with_name(f".{destination.stem}-{uuid4().hex}.wav")
    try:
        log_fn(f"渲染音效試聽 · {effect_key} · {source.name} (最長 {dur:.1f}s)")
        _run_cmd(
            [
                ffmpeg,
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-t",
                f"{dur + 0.5:.6f}",
                "-i",
                source,
                "-vn",
                "-af",
                ",".join(achain),
                "-c:a",
                "pcm_s16le",
                "-ar",
                "48000",
                "-ac",
                "2",
                tmp,
            ]
        )
        if not tmp.is_file() or tmp.stat().st_size == 0:
            raise ValueError("FFmpeg 未產生有效的音效試聽 WAV 檔案。")
        tmp.replace(destination)
    finally:
        tmp.unlink(missing_ok=True)
    return str(destination)


def build_edit_proxy(
    input_path: str | Path,
    output_path: str | Path,
    *,
    ffmpeg: str,
    ffprobe: str,
    max_height: int = 540,
    log_fn: Callable[[str], Any] = print,
) -> str:
    """Build a fast-scrubbing <=540p H.264 edit proxy MP4 without modifying the source file."""
    source = Path(input_path)
    destination = Path(output_path)
    if not source.is_file():
        raise ValueError(f"找不到代理檔來源影片：{source}")
    if destination.suffix.lower() != ".mp4":
        raise ValueError("代理檔輸出需使用 .mp4。")
    if source.resolve() == destination.resolve():
        raise ValueError("代理檔輸出路徑不可覆蓋原始素材。")

    info = _probe_media(ffprobe, source)
    streams = info.get("streams") or []
    v_stream = next((s for s in streams if s.get("codec_type") == "video"), None)
    if v_stream is None:
        raise ValueError(f"來源檔案 {source.name} 沒有視訊軌，無法產生剪輯代理檔。")
    has_audio = any(s.get("codec_type") == "audio" for s in streams)

    target_h = max(144, (int(max_height) // 2) * 2)
    destination.parent.mkdir(parents=True, exist_ok=True)
    tmp = destination.with_name(f".{destination.stem}-{uuid4().hex}.mp4")

    cmd: list[Any] = [
        ffmpeg,
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        source,
        "-vf",
        f"scale=-2:'min({target_h},ih)':flags=bicubic,scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-preset",
        "ultrafast",
        "-crf",
        "23",
        "-g",
        "15",
        "-threads",
        "3",
    ]
    if has_audio:
        cmd += ["-c:a", "aac", "-ar", "48000", "-ac", "2", "-b:a", "128k"]
    else:
        cmd += ["-an"]
    cmd += ["-movflags", "+faststart", tmp]

    try:
        log_fn(f"建立剪輯代理檔 · {source.name} -> {destination.name} (<= {target_h}p)")
        _run_cmd(cmd)
        if not tmp.is_file() or tmp.stat().st_size == 0:
            raise ValueError("FFmpeg 未產生有效的剪輯代理檔。")
        tmp.replace(destination)
    finally:
        tmp.unlink(missing_ok=True)
    return str(destination)


# ---------------------------------------------------------------------------
# CLI entry point for standalone verification
# ---------------------------------------------------------------------------

def _cli() -> int:
    parser = argparse.ArgumentParser(description="MotionDesk 0.2 multi-track timeline renderer CLI")
    parser.add_argument(
        "--render-transition-cache",
        nargs=2,
        metavar=("SPEC_JSON", "OUTPUT_MP4"),
        help="Render a same-source video-only transition preview cache clip from spec JSON to MP4",
    )
    parser.add_argument(
        "--render-clip-preview",
        nargs=2,
        metavar=("SPEC_JSON", "OUTPUT_PATH"),
        help="Render a same-source processed clip preview (opaque MP4, stacked RGB+Alpha MP4, or RGBA PNG)",
    )
    parser.add_argument(
        "--preview-audio-fx",
        nargs=3,
        metavar=("SRC_MEDIA", "FX_ID", "OUTPUT_WAV"),
        help="Render an up-to-8s audition WAV for one of the 25 FFmpeg audio DSP effects",
    )
    parser.add_argument(
        "--build-proxy",
        nargs=2,
        metavar=("INPUT_VIDEO", "OUTPUT_540P_MP4"),
        help="Build a fast-scrubbing <=540p H.264 edit proxy MP4",
    )
    parser.add_argument("request_json", nargs="?", help="Path to export request JSON file")
    parser.add_argument("--work-dir", help="Working directory for intermediate files")
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg")
    parser.add_argument("--ffprobe", default=shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe")
    parser.add_argument("--textrender", default=None, help="Path to compiled textrender binary")
    args = parser.parse_args()

    if args.render_transition_cache:
        spec_path = Path(args.render_transition_cache[0]).resolve()
        out_path = Path(args.render_transition_cache[1]).resolve()
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
        rendered = render_transition_cache(
            spec,
            out_path,
            ffmpeg=args.ffmpeg,
            ffprobe=args.ffprobe,
        )
        print(json.dumps({"path": rendered}, ensure_ascii=False))
        return 0

    if args.render_clip_preview:
        spec_path = Path(args.render_clip_preview[0]).resolve()
        out_path = Path(args.render_clip_preview[1]).resolve()
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
        rendered = render_clip_preview(
            spec,
            out_path,
            ffmpeg=args.ffmpeg,
            ffprobe=args.ffprobe,
        )
        print(json.dumps({"path": rendered}, ensure_ascii=False))
        return 0

    if args.preview_audio_fx:
        src_path = Path(args.preview_audio_fx[0]).resolve()
        fx_id = str(args.preview_audio_fx[1])
        out_wav = Path(args.preview_audio_fx[2]).resolve()
        rendered = preview_audio_fx(
            src_path,
            fx_id,
            out_wav,
            ffmpeg=args.ffmpeg,
        )
        print(json.dumps({"path": rendered, "fxId": fx_id}, ensure_ascii=False))
        return 0

    if args.build_proxy:
        in_path = Path(args.build_proxy[0]).resolve()
        out_mp4 = Path(args.build_proxy[1]).resolve()
        rendered = build_edit_proxy(
            in_path,
            out_mp4,
            ffmpeg=args.ffmpeg,
            ffprobe=args.ffprobe,
        )
        print(json.dumps({"path": rendered}, ensure_ascii=False))
        return 0

    if not args.request_json:
        parser.error(
            "request_json is required unless --render-transition-cache, --render-clip-preview, "
            "--preview-audio-fx, or --build-proxy is specified"
        )

    req_path = Path(args.request_json).resolve()
    request = json.loads(req_path.read_text(encoding="utf-8"))
    work_dir = Path(args.work_dir).resolve() if args.work_dir else req_path.parent / "render_work"
    paths = export_multitrack(
        request,
        work_dir,
        ffmpeg=args.ffmpeg,
        ffprobe=args.ffprobe,
        textrender_bin=args.textrender,
    )
    print(json.dumps({"paths": paths}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
