"""Single-source-of-truth ComfyUI workflow resolver, validator, and LiteGraph Canvas converter.

Used by MotionDesk's worker.py and offline CLI verification tools to guarantee that:
1. Built-in model presets read exclusively from model_profiles.json and standalone template JSONs.
2. Removed models (e.g. realxl) and unsupported capabilities fail loudly with clear errors.
3. The exact resolved API prompt graph submitted to ComfyUI can be exported as both
   `<base>.api.json` and a ComfyUI-openable LiteGraph v0.4 `<base>.workflow.json`,
   verified via `verify_canvas_roundtrip()`.
"""
from __future__ import annotations

import argparse
from collections import defaultdict, deque
import copy
import json
import math
import os
from pathlib import Path
import re
from typing import Any, Callable


PRIMITIVE_WIDGET_TYPES = {"INT", "FLOAT", "STRING", "BOOLEAN", "COMBO"}
PLACEHOLDER_RE = re.compile(r"\{\{(PROMPT|IMAGE|SEED|SECONDS)\}\}")

# Static fallback schemas matching ComfyUI core `/object_info` (27 core nodes).
# Format:
#   "links": list of (name, type, optional)
#   "widgets": list of (name, type, default, extra_after)
#       where extra_after is None, "control_after_generate", or "image_upload"
#   "outputs": list of (name, type)
#   "size": [width, height]
NODE_SCHEMAS: dict[str, dict[str, Any]] = {
    "UNETLoader": {
        "links": [],
        "widgets": [
            ("unet_name", "COMBO", "", None),
            ("weight_dtype", "COMBO", "default", None),
        ],
        "outputs": [("MODEL", "MODEL")],
        "size": [340, 90],
    },
    "CLIPLoader": {
        "links": [],
        "widgets": [
            ("clip_name", "COMBO", "", None),
            ("type", "COMBO", "stable_diffusion", None),
            ("device", "COMBO", "default", None),
        ],
        "outputs": [("CLIP", "CLIP")],
        "size": [340, 110],
    },
    "DualCLIPLoader": {
        "links": [],
        "widgets": [
            ("clip_name1", "COMBO", "", None),
            ("clip_name2", "COMBO", "", None),
            ("type", "COMBO", "flux", None),
            ("device", "COMBO", "default", None),
        ],
        "outputs": [("CLIP", "CLIP")],
        "size": [340, 134],
    },
    "VAELoader": {
        "links": [],
        "widgets": [
            ("vae_name", "COMBO", "", None),
        ],
        "outputs": [("VAE", "VAE")],
        "size": [320, 68],
    },
    "CheckpointLoaderSimple": {
        "links": [],
        "widgets": [
            ("ckpt_name", "COMBO", "", None),
        ],
        "outputs": [("MODEL", "MODEL"), ("CLIP", "CLIP"), ("VAE", "VAE")],
        "size": [360, 98],
    },
    "LoraLoaderModelOnly": {
        "links": [("model", "MODEL", False)],
        "widgets": [
            ("lora_name", "COMBO", "", None),
            ("strength_model", "FLOAT", 1.0, None),
        ],
        "outputs": [("MODEL", "MODEL")],
        "size": [340, 102],
    },
    "LoraLoader": {
        "links": [("model", "MODEL", False), ("clip", "CLIP", False)],
        "widgets": [
            ("lora_name", "COMBO", "", None),
            ("strength_model", "FLOAT", 1.0, None),
            ("strength_clip", "FLOAT", 1.0, None),
        ],
        "outputs": [("MODEL", "MODEL"), ("CLIP", "CLIP")],
        "size": [340, 130],
    },
    "CLIPTextEncode": {
        "links": [("clip", "CLIP", False)],
        "widgets": [
            ("text", "STRING", "", None),
        ],
        "outputs": [("CONDITIONING", "CONDITIONING")],
        "size": [420, 160],
    },
    "ConditioningZeroOut": {
        "links": [("conditioning", "CONDITIONING", False)],
        "widgets": [],
        "outputs": [("CONDITIONING", "CONDITIONING")],
        "size": [240, 48],
    },
    "FluxGuidance": {
        "links": [("conditioning", "CONDITIONING", False)],
        "widgets": [
            ("guidance", "FLOAT", 3.5, None),
        ],
        "outputs": [("CONDITIONING", "CONDITIONING")],
        "size": [260, 72],
    },
    "ModelSamplingAuraFlow": {
        "links": [("model", "MODEL", False)],
        "widgets": [
            ("shift", "FLOAT", 3.0, None),
        ],
        "outputs": [("MODEL", "MODEL")],
        "size": [280, 72],
    },
    "ModelSamplingSD3": {
        "links": [("model", "MODEL", False)],
        "widgets": [
            ("shift", "FLOAT", 5.0, None),
        ],
        "outputs": [("MODEL", "MODEL")],
        "size": [280, 72],
    },
    "ModelSamplingFlux": {
        "links": [("model", "MODEL", False)],
        "widgets": [
            ("max_shift", "FLOAT", 1.15, None),
            ("base_shift", "FLOAT", 0.5, None),
            ("width", "INT", 1024, None),
            ("height", "INT", 1024, None),
        ],
        "outputs": [("MODEL", "MODEL")],
        "size": [300, 134],
    },
    "SkipLayerGuidanceDiTSimple": {
        "links": [("model", "MODEL", False)],
        "widgets": [
            ("double_layers", "STRING", "", None),
            ("single_layers", "STRING", "22", None),
            ("start_percent", "FLOAT", 0.0, None),
            ("end_percent", "FLOAT", 0.5, None),
        ],
        "outputs": [("MODEL", "MODEL")],
        "size": [320, 134],
    },
    "EmptyLatentImage": {
        "links": [],
        "widgets": [
            ("width", "INT", 1024, None),
            ("height", "INT", 1024, None),
            ("batch_size", "INT", 1, None),
        ],
        "outputs": [("LATENT", "LATENT")],
        "size": [280, 110],
    },
    "EmptySD3LatentImage": {
        "links": [],
        "widgets": [
            ("width", "INT", 1024, None),
            ("height", "INT", 1024, None),
            ("batch_size", "INT", 1, None),
        ],
        "outputs": [("LATENT", "LATENT")],
        "size": [280, 110],
    },
    "EmptyFlux2LatentImage": {
        "links": [],
        "widgets": [
            ("width", "INT", 1024, None),
            ("height", "INT", 1024, None),
            ("batch_size", "INT", 1, None),
        ],
        "outputs": [("LATENT", "LATENT")],
        "size": [280, 110],
    },
    "Wan22ImageToVideoLatent": {
        "links": [
            ("vae", "VAE", False),
            ("start_image", "IMAGE", True),
        ],
        "widgets": [
            ("width", "INT", 832, None),
            ("height", "INT", 480, None),
            ("length", "INT", 73, None),
            ("batch_size", "INT", 1, None),
        ],
        "outputs": [("LATENT", "LATENT")],
        "size": [320, 160],
    },
    "KSampler": {
        "links": [
            ("model", "MODEL", False),
            ("positive", "CONDITIONING", False),
            ("negative", "CONDITIONING", False),
            ("latent_image", "LATENT", False),
        ],
        "widgets": [
            ("seed", "INT", 0, "control_after_generate"),
            ("steps", "INT", 20, None),
            ("cfg", "FLOAT", 1.0, None),
            ("sampler_name", "COMBO", "euler", None),
            ("scheduler", "COMBO", "simple", None),
            ("denoise", "FLOAT", 1.0, None),
        ],
        "outputs": [("LATENT", "LATENT")],
        "size": [320, 266],
    },
    "LoadImage": {
        "links": [],
        "widgets": [
            ("image", "COMBO", "", "image_upload"),
        ],
        "outputs": [("IMAGE", "IMAGE"), ("MASK", "MASK")],
        "size": [320, 120],
    },
    "ImageScale": {
        "links": [("image", "IMAGE", False)],
        "widgets": [
            ("upscale_method", "COMBO", "lanczos", None),
            ("width", "INT", 1024, None),
            ("height", "INT", 1024, None),
            ("crop", "COMBO", "center", None),
        ],
        "outputs": [("IMAGE", "IMAGE")],
        "size": [300, 134],
    },
    "VAEEncode": {
        "links": [("pixels", "IMAGE", False), ("vae", "VAE", False)],
        "widgets": [],
        "outputs": [("LATENT", "LATENT")],
        "size": [220, 56],
    },
    "VAEDecode": {
        "links": [("samples", "LATENT", False), ("vae", "VAE", False)],
        "widgets": [],
        "outputs": [("IMAGE", "IMAGE")],
        "size": [220, 56],
    },
    "VAEDecodeTiled": {
        "links": [("samples", "LATENT", False), ("vae", "VAE", False)],
        "widgets": [
            ("tile_size", "INT", 512, None),
            ("overlap", "INT", 64, None),
            ("temporal_size", "INT", 64, None),
            ("temporal_overlap", "INT", 8, None),
        ],
        "outputs": [("IMAGE", "IMAGE")],
        "size": [280, 150],
    },
    "SaveImage": {
        "links": [("images", "IMAGE", False)],
        "widgets": [
            ("filename_prefix", "STRING", "MotionDesk/Output", None),
        ],
        "outputs": [],
        "size": [320, 100],
    },
    "CreateVideo": {
        "links": [
            ("images", "IMAGE", False),
            ("audio", "AUDIO", True),
        ],
        "widgets": [
            ("fps", "FLOAT", 24, None),
        ],
        "outputs": [("VIDEO", "VIDEO")],
        "size": [260, 96],
    },
    "SaveVideo": {
        "links": [("video", "VIDEO", False)],
        "widgets": [
            ("filename_prefix", "STRING", "MotionDesk/Wan22", None),
            ("format", "COMBO", "auto", None),
            ("codec", "COMBO", "auto", None),
        ],
        "outputs": [],
        "size": [320, 128],
    },
}


def _is_safe_safetensors_filename(value: Any) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and "/" not in value
        and "\\" not in value
        and value not in {".", ".."}
        and not value.startswith(".")
        and value.lower().endswith(".safetensors")
    )


def _expected_primary_category_for_base(base_model: dict[str, Any]) -> str:
    req = base_model.get("requiredModels") or {}
    has_ckpt = bool(req.get("checkpoints"))
    has_diff = bool(req.get("diffusion_models"))
    if has_ckpt and not has_diff:
        return "checkpoints"
    if has_diff and not has_ckpt:
        return "diffusion_models"
    raise ValueError(f"基底模型 {base_model.get('id')} 缺少明確的主權重載入類別（checkpoints/diffusion_models）。")


def _apply_user_models(data: dict[str, Any]) -> None:
    """Merge persistent user image model entries from user_models.json into loaded profiles."""
    registry = Path(os.environ.get("MOTIONDESK_USER_MODELS_REGISTRY", str(
        Path.home() / "Library/Application Support/MotionDesk/user_models.json")))
    if not registry.is_file():
        return
    try:
        raw = json.loads(registry.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise ValueError("user_models.json 根物件必須為字典")
        entries = raw.get("entries", [])
        if not isinstance(entries, list):
            raise ValueError("entries 必須為陣列")
        models = data["models"]
        order = data.setdefault("modelOrder", list(models.keys()))
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError("模型項目格式無效")
            entry_id = entry.get("id")
            display_name = entry.get("displayName")
            base_profile = entry.get("baseProfile")
            primary_cat = entry.get("primaryCategory")
            primary_weight = entry.get("primaryWeight")
            secondary = entry.get("secondaryWeights") or {}
            if (
                not isinstance(entry_id, str) or not entry_id.strip()
                or not isinstance(display_name, str) or not display_name.strip()
                or not isinstance(base_profile, str) or base_profile not in models
                or models[base_profile].get("kind") != "image"
                or primary_cat not in {"checkpoints", "diffusion_models"}
                or not _is_safe_safetensors_filename(primary_weight)
                or not isinstance(secondary, dict)
            ):
                raise ValueError("自訂模型項目缺少有效 ID、基底架構或 .safetensors 權重檔名")
            expected_cat = _expected_primary_category_for_base(models[base_profile])
            if primary_cat != expected_cat:
                raise ValueError(
                    f"自訂模型 {entry_id} 的主權重類別 {primary_cat} 與基底 {base_profile} 的載入器類別 {expected_cat} 不符"
                )
            clean_secondary: dict[str, str] = {}
            for slot, fname in secondary.items():
                if not isinstance(slot, str) or not _is_safe_safetensors_filename(fname):
                    raise ValueError(f"次要權重檔名無效：{slot}")
                clean_secondary[slot] = fname

            cloned = copy.deepcopy(models[base_profile])
            cloned["id"] = entry_id
            cloned["displayName"] = display_name.strip()
            cloned["shortName"] = display_name.strip()
            cloned["baseProfile"] = base_profile
            cloned["weightOverrides"] = {
                "primaryCategory": expected_cat,
                "primaryWeight": primary_weight,
                "secondaryWeights": clean_secondary,
            }
            req_models = copy.deepcopy(cloned.get("requiredModels") or {})
            req_models.pop("checkpoints", None)
            req_models.pop("diffusion_models", None)
            req_models[expected_cat] = [primary_weight]
            if "vae" in clean_secondary:
                req_models["vae"] = [clean_secondary["vae"]]
            if "text_encoder" in clean_secondary or "text_encoder_2" in clean_secondary:
                te_list = list(req_models.get("text_encoders") or [])
                if "text_encoder" in clean_secondary:
                    if te_list:
                        te_list[0] = clean_secondary["text_encoder"]
                    else:
                        te_list.append(clean_secondary["text_encoder"])
                if "text_encoder_2" in clean_secondary:
                    if len(te_list) >= 2:
                        te_list[1] = clean_secondary["text_encoder_2"]
                    else:
                        te_list.append(clean_secondary["text_encoder_2"])
                req_models["text_encoders"] = te_list
            cloned["requiredModels"] = req_models
            models[entry_id] = cloned
            if entry_id not in order:
                order.append(entry_id)
    except (ValueError, OSError, TypeError) as exc:
        raise ValueError(f"無法讀取自訂模型清單：{exc}") from exc


def load_profiles(resource_dir: Path | str) -> dict[str, Any]:
    """Load model_profiles.json from resource_dir, merged with user_models.json and user_loras.json."""
    path = Path(resource_dir) / "model_profiles.json"
    if not path.is_file():
        raise FileNotFoundError(f"找不到模型設定檔：{path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("models"), dict):
        raise ValueError("model_profiles.json 格式無效，缺少 models 欄位。")
    _apply_user_models(data)
    registry = Path(os.environ.get("MOTIONDESK_LORA_REGISTRY", str(
        Path.home() / "Library/Application Support/MotionDesk/user_loras.json")))
    if registry.is_file():
        try:
            entries = json.loads(registry.read_text(encoding="utf-8"))
            if not isinstance(entries, list):
                raise ValueError("清單必須為陣列")
            seen = set()
            for entry in entries:
                if not isinstance(entry, dict):
                    raise ValueError("登錄格式無效")
                key, filename = entry.get("id"), entry.get("filename")
                models, strength = entry.get("compatibleModels"), entry.get("defaultStrength")
                if (not isinstance(key, str) or not key.startswith("user_") or key in seen
                    or not isinstance(filename, str) or not filename.startswith("MotionDesk/")
                    or "\\" in filename or ".." in Path(filename).parts
                    or not filename.endswith(".safetensors")
                    or not isinstance(models, list) or not models
                    or any(m not in data["models"] or data["models"][m]["kind"] != "image"
                           or not data["models"][m]["capabilities"].get("supportsLoRA") for m in models)
                    or type(strength) not in (float, int) or not math.isfinite(strength) or not 0 <= strength <= 2):
                    raise ValueError("LoRA 路徑、基底模型或強度設定無效")
                seen.add(key)
                data.setdefault("loras", {})[key] = entry
        except (ValueError, OSError, TypeError) as exc:
            raise ValueError(f"無法讀取自訂 LoRA 清單：{exc}") from exc
    return data


def list_presets(resource_dir: Path | str) -> list[str]:
    """Return ordered list of active built-in model preset IDs."""
    profiles = load_profiles(resource_dir)
    order = profiles.get("modelOrder")
    models = profiles["models"]
    if isinstance(order, list):
        return [key for key in order if key in models]
    return list(models.keys())


def get_profile(preset: str, resource_dir: Path | str) -> dict[str, Any]:
    """Return profile for preset; raise explicit ValueError for removed or unknown presets."""
    profiles = load_profiles(resource_dir)
    removed = profiles.get("removedModels") or {}
    if preset in removed:
        entry = removed[preset]
        message = entry.get("message") if isinstance(entry, dict) else None
        raise ValueError(message or f"模型 {preset} 已移除，請改選其他本機模型。")
    models = profiles["models"]
    if preset not in models:
        raise ValueError(f"不支援的本機模型設定：{preset}。")
    return models[preset]


def required_models_for_preset(
    preset: str,
    lora: str,
    resource_dir: Path | str,
) -> dict[str, list[str]]:
    """Return required ComfyUI model filenames grouped by category for preflight check."""
    profiles = load_profiles(resource_dir)
    profile = get_profile(preset, resource_dir)
    required: dict[str, list[str]] = {
        cat: list(names) for cat, names in (profile.get("requiredModels") or {}).items()
    }
    lora_key = (lora or "").strip()
    if lora_key:
        if not profile["capabilities"].get("supportsLoRA"):
            raise ValueError(f"{profile['displayName']} 不支援本機 LoRA（{lora_key}）。")
        lora_entry = (profiles.get("loras") or {}).get(lora_key)
        base_profile = profile.get("baseProfile", preset)
        compatible = lora_entry.get("compatibleModels", []) if lora_entry else []
        if not lora_entry or (preset not in compatible and base_profile not in compatible):
            raise ValueError(f"{profile['displayName']} 不支援所選的 LoRA：{lora_key}。")
        required.setdefault("loras", []).append(lora_entry["filename"])
    return required


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _check_range(label: str, value: Any, bounds: list[Any] | None, *, integer: bool = False) -> None:
    if bounds is None or len(bounds) != 2:
        raise ValueError(f"此模型不支援調整 {label}。")
    if integer:
        if type(value) is not int:
            raise ValueError(f"{label} 必須為整數（允許範圍 {bounds[0]}–{bounds[1]}）。")
    else:
        if not _is_number(value):
            raise ValueError(f"{label} 必須為數字（允許範圍 {bounds[0]}–{bounds[1]}）。")
    low, high = bounds
    if not (low <= value <= high):
        raise ValueError(f"{label} 超出允許範圍 {low}–{high}（目前為 {value}）。")


def _extract_references(request: dict[str, Any]) -> tuple[str, list[str], str]:
    ref = (request.get("reference") or "").strip() if isinstance(request.get("reference"), str) else ""
    raw_images = request.get("referenceImages") or []
    ref_images = [
        item.strip()
        for item in raw_images
        if isinstance(item, str) and item.strip()
    ]
    ref_video = (
        (request.get("referenceVideo") or "").strip()
        if isinstance(request.get("referenceVideo"), str)
        else ""
    )
    return ref, ref_images, ref_video


def validate_preset_request(
    preset: str,
    request: dict[str, Any],
    resource_dir: Path | str,
) -> dict[str, Any]:
    """Strictly validate a generation request against the model profile capabilities and ranges."""
    profiles = load_profiles(resource_dir)
    profile = get_profile(preset, resource_dir)
    caps = profile["capabilities"]
    ranges = profile["ranges"]
    display = profile["displayName"]

    req_kind = request.get("kind")
    if req_kind is not None and req_kind != profile["kind"]:
        kind_label = "圖片" if profile["kind"] == "image" else "影片"
        raise ValueError(f"{display} 為{kind_label}模型，僅支援{kind_label}輸出。")

    if request.get("videoMethod") in {"frames", "multi"}:
        raise ValueError(f"{display} 本機工作流不支援首尾雙幀或多影格模式。")

    ref, ref_images, ref_video = _extract_references(request)
    if profile["kind"] == "image":
        if ref_video:
            raise ValueError(f"{display} 為圖片模型，不支援參考影片。")
        if len(ref_images) > 1 or (ref and ref_images and ref_images != [ref]):
            raise ValueError(f"{display} 本機工作流最多僅接受 1 張參考圖片。")
        effective_ref = ref or (ref_images[0] if ref_images else "")
        if effective_ref and not caps.get("supportsImg2Img"):
            raise ValueError(f"{display} 目前僅支援文字生圖，不支援參考圖片。")
    else:
        if len(ref_images) > 1 or (ref and ref_video) or (ref_images and ref_video):
            raise ValueError(f"{display} 只接受一個首幀來源，請選擇圖片或影片。")
        if (ref or ref_images or ref_video) and not caps.get("supportsVideoFirstFrame"):
            raise ValueError(f"{display} 目前不支援首幀參考素材。")
        sec_bounds = ranges.get("seconds")
        seconds = request.get("seconds", profile["defaults"].get("seconds", 3))
        if isinstance(seconds, float) and seconds.is_integer():
            seconds = int(seconds)
        _check_range("影片秒數", seconds, sec_bounds, integer=True)

    lora = (request.get("lora") or "").strip() if isinstance(request.get("lora"), str) else ""
    if lora:
        if not caps.get("supportsLoRA"):
            raise ValueError(f"{display} 不支援本機 LoRA（{lora}）。")
        lora_entry = (profiles.get("loras") or {}).get(lora)
        base_profile = profile.get("baseProfile", preset)
        compatible = lora_entry.get("compatibleModels", []) if lora_entry else []
        if not lora_entry or (preset not in compatible and base_profile not in compatible):
            raise ValueError(f"{display} 不支援所選的 LoRA：{lora}。")

    aspect = request.get("aspect")
    if aspect is not None and aspect not in profile["nativeSizes"]:
        allowed = "、".join(profile["nativeSizes"].keys())
        raise ValueError(f"不支援的畫面比例 {aspect}，可用比例為：{allowed}。")

    model_params = request.get("modelParams")
    if model_params is not None:
        if not isinstance(model_params, dict):
            raise ValueError("modelParams 必須為 JSON 物件。")
        if model_params.get("steps") is not None:
            _check_range("步數 (steps)", model_params["steps"], ranges.get("steps"), integer=True)
        if model_params.get("cfg") is not None:
            _check_range("CFG", model_params["cfg"], ranges.get("cfg"))
        if model_params.get("sampler") is not None:
            sampler = model_params["sampler"]
            if sampler not in (ranges.get("samplers") or []):
                raise ValueError(f"{display} 不支援採樣器 {sampler}（允許：{', '.join(ranges.get('samplers') or [])}）。")
        if model_params.get("scheduler") is not None:
            scheduler = model_params["scheduler"]
            if scheduler not in (ranges.get("schedulers") or []):
                raise ValueError(f"{display} 不支援排程器 {scheduler}（允許：{', '.join(ranges.get('schedulers') or [])}）。")
        if model_params.get("shift") is not None:
            if not caps.get("supportsShift"):
                raise ValueError(f"{display} 不支援調整 shift 參數。")
            _check_range("Shift", model_params["shift"], ranges.get("shift"))
        if model_params.get("guidance") is not None:
            if not caps.get("supportsGuidance"):
                raise ValueError(f"{display} 不支援調整 FluxGuidance 參數。")
            _check_range("Guidance", model_params["guidance"], ranges.get("guidance"))
        if model_params.get("denoise") is not None:
            if not caps.get("supportsImg2Img"):
                raise ValueError(f"{display} 不支援圖生圖 denoise 調整。")
            _check_range("Denoise", model_params["denoise"], ranges.get("denoise"))
        if model_params.get("negativePrompt") is not None:
            neg = model_params["negativePrompt"]
            if not isinstance(neg, str):
                raise ValueError("負向提示詞必須為文字。")
            if neg.strip() and not caps.get("supportsNegativePrompt"):
                raise ValueError(f"{display} 使用 ConditioningZeroOut，不支援自訂負向提示詞。")
        if model_params.get("loraStrength") is not None:
            if not lora:
                raise ValueError("未選擇 LoRA，無法套用 loraStrength。")
            _check_range("LoRA 強度", model_params["loraStrength"], [0.0, 2.0])

    return profile


def _default_native_size(
    request: dict[str, Any],
    profile: dict[str, Any],
    default: tuple[int, int],
) -> tuple[int, int]:
    value = request.get("pixelSize")
    if not isinstance(value, dict):
        return default
    width, height = value.get("width"), value.get("height")
    if type(width) is not int or type(height) is not int:
        return default
    if not (64 <= width <= 4096 and 64 <= height <= 4096):
        return default
    alignment = int(profile.get("alignment", 16))
    max_pixels = int(profile.get("maxPixels", 2 * 1024 * 1024))
    if width % alignment == 0 and height % alignment == 0 and width * height <= max_pixels:
        return (width, height)
    return default


def _substitute_placeholders(value: Any, replacements: dict[str, Any]) -> Any:
    if isinstance(value, dict):
        return {k: _substitute_placeholders(v, replacements) for k, v in value.items()}
    if isinstance(value, list):
        return [_substitute_placeholders(v, replacements) for v in value]
    if isinstance(value, str):
        if value in replacements:
            return replacements[value]
        return PLACEHOLDER_RE.sub(
            lambda m: str(replacements[m.group(0)]) if m.group(0) in replacements else m.group(0),
            value,
        )
    return value


def resolve_builtin_graph(
    preset: str,
    request: dict[str, Any],
    resource_dir: Path | str,
    *,
    uploaded_image: str | None = None,
    native_size_fn: Callable[[dict[str, Any], tuple[int, int]], tuple[int, int]] | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Resolve a built-in preset + request into the exact ComfyUI API graph and metadata."""
    res_dir = Path(resource_dir)
    profiles = load_profiles(res_dir)
    profile = validate_preset_request(preset, request, res_dir)
    caps = profile["capabilities"]
    defaults = profile["defaults"]
    nodes = profile["nodes"]

    template_path = res_dir / profile["template"]
    if not template_path.is_file():
        raise FileNotFoundError(f"找不到模型工作流模板：{template_path}")
    workflow: dict[str, Any] = json.loads(template_path.read_text(encoding="utf-8"))

    weight_overrides = profile.get("weightOverrides") or {}
    if isinstance(weight_overrides, dict) and weight_overrides:
        primary_cat = weight_overrides.get("primaryCategory")
        primary_weight = weight_overrides.get("primaryWeight")
        secondary = weight_overrides.get("secondaryWeights") or {}
        for node in workflow.values():
            if not isinstance(node, dict):
                continue
            ctype = node.get("class_type")
            inputs = node.get("inputs")
            if not isinstance(inputs, dict):
                continue
            if primary_cat == "checkpoints" and ctype == "CheckpointLoaderSimple" and primary_weight:
                inputs["ckpt_name"] = primary_weight
            elif primary_cat == "diffusion_models" and ctype == "UNETLoader" and primary_weight:
                inputs["unet_name"] = primary_weight
            if ctype == "VAELoader" and secondary.get("vae"):
                inputs["vae_name"] = secondary["vae"]
            elif ctype == "CLIPLoader" and secondary.get("text_encoder"):
                inputs["clip_name"] = secondary["text_encoder"]
            elif ctype == "DualCLIPLoader":
                if secondary.get("text_encoder"):
                    inputs["clip_name1"] = secondary["text_encoder"]
                if secondary.get("text_encoder_2"):
                    inputs["clip_name2"] = secondary["text_encoder_2"]

    default_aspect = "16:9" if profile["kind"] == "video" else "1:1"
    aspect = request.get("aspect") or default_aspect
    base_w, base_h = profile["nativeSizes"][aspect]
    if native_size_fn is not None:
        width, height = native_size_fn(request, (base_w, base_h))
    else:
        width, height = _default_native_size(request, profile, (base_w, base_h))

    latent_id = nodes["latent"]
    sampler_id = nodes["sampler"]
    workflow[latent_id]["inputs"]["width"] = int(width)
    workflow[latent_id]["inputs"]["height"] = int(height)

    msf_id = nodes.get("modelSamplingFlux")
    if msf_id and msf_id in workflow:
        workflow[msf_id]["inputs"]["width"] = int(width)
        workflow[msf_id]["inputs"]["height"] = int(height)

    model_params = request.get("modelParams") or {}
    steps = int(model_params["steps"]) if model_params.get("steps") is not None else int(defaults["steps"])
    cfg = float(model_params["cfg"]) if model_params.get("cfg") is not None else float(defaults["cfg"])
    sampler = str(model_params["sampler"]) if model_params.get("sampler") is not None else str(defaults["sampler"])
    scheduler = str(model_params["scheduler"]) if model_params.get("scheduler") is not None else str(defaults["scheduler"])

    shift: float | None = None
    if caps.get("supportsShift"):
        shift = (
            float(model_params["shift"])
            if model_params.get("shift") is not None
            else float(defaults["shift"])
        )
        shift_id = nodes.get("shift")
        if shift_id and shift_id in workflow:
            workflow[shift_id]["inputs"]["shift"] = shift

    guidance: float | None = None
    if caps.get("supportsGuidance"):
        guidance = (
            float(model_params["guidance"])
            if model_params.get("guidance") is not None
            else float(defaults["guidance"])
        )
        guidance_id = nodes.get("guidance")
        if guidance_id and guidance_id in workflow:
            workflow[guidance_id]["inputs"]["guidance"] = guidance

    negative_prompt = ""
    if caps.get("supportsNegativePrompt"):
        negative_prompt = (
            str(model_params["negativePrompt"])
            if model_params.get("negativePrompt") is not None
            else str(defaults.get("negativePrompt") or "")
        )
        neg_id = nodes.get("negative")
        if neg_id and neg_id in workflow:
            workflow[neg_id]["inputs"]["text"] = negative_prompt

    workflow[sampler_id]["inputs"].update(
        steps=steps,
        cfg=cfg,
        sampler_name=sampler,
        scheduler=scheduler,
    )

    lora = (request.get("lora") or "").strip() if isinstance(request.get("lora"), str) else ""
    lora_strength: float | None = None
    if lora:
        lora_entry = profiles["loras"][lora]
        lora_strength = (
            float(model_params["loraStrength"])
            if model_params.get("loraStrength") is not None
            else float(lora_entry["defaultStrength"])
        )
        upstream_id = nodes["loraUpstream"]
        downstream_id = nodes["loraDownstream"]
        workflow["11"] = {
            "class_type": "LoraLoaderModelOnly",
            "inputs": {
                "model": [upstream_id, 0],
                "lora_name": lora_entry["filename"],
                "strength_model": lora_strength,
            },
        }
        workflow[downstream_id]["inputs"]["model"] = ["11", 0]

    ref, ref_images, ref_video = _extract_references(request)
    effective_ref = ref or (ref_images[0] if ref_images else "")
    image_value: str | None = None
    if uploaded_image is not None:
        image_value = uploaded_image
    elif effective_ref:
        image_value = Path(effective_ref).name
    elif ref_video:
        image_value = Path(ref_video).name

    seconds: int | None = None
    fps: int | None = None
    length: int | None = None
    denoise = float(defaults.get("denoise", 1.0))

    if profile["kind"] == "video":
        seconds = int(request.get("seconds", defaults.get("seconds", 3)))
        fps = int(defaults.get("fps", 24))
        length = fps * seconds + 1
        workflow[latent_id]["inputs"]["length"] = length
        if image_value is not None:
            workflow["12"] = {
                "class_type": "LoadImage",
                "inputs": {"image": image_value},
            }
            workflow[latent_id]["inputs"]["start_image"] = ["12", 0]
        workflow[sampler_id]["inputs"]["denoise"] = denoise
    else:
        if image_value is not None:
            denoise = (
                float(model_params["denoise"])
                if model_params.get("denoise") is not None
                else float(defaults.get("img2imgDenoise", 0.55))
            )
            vae_source = list(workflow[nodes["vaeDecode"]]["inputs"]["vae"])
            workflow["20"] = {
                "class_type": "LoadImage",
                "inputs": {"image": image_value},
            }
            workflow["21"] = {
                "class_type": "ImageScale",
                "inputs": {
                    "image": ["20", 0],
                    "upscale_method": "lanczos",
                    "width": int(width),
                    "height": int(height),
                    "crop": "center",
                },
            }
            workflow["22"] = {
                "class_type": "VAEEncode",
                "inputs": {
                    "pixels": ["21", 0],
                    "vae": vae_source,
                },
            }
            workflow[sampler_id]["inputs"].update(
                latent_image=["22", 0],
                denoise=denoise,
            )
            del workflow[latent_id]
        else:
            workflow[sampler_id]["inputs"]["denoise"] = denoise

    raw_prompt = (
        str(request["rawPrompt"])
        if request.get("rawPrompt") is not None
        else str(request.get("prompt", ""))
    )
    prompt = str(request.get("prompt", raw_prompt))
    seed = int(request.get("seed", 0))

    replacements: dict[str, Any] = {
        "{{PROMPT}}": prompt,
        "{{SEED}}": seed,
        "{{SECONDS}}": seconds if seconds is not None else int(request.get("seconds", 3)),
    }
    if image_value is not None:
        replacements["{{IMAGE}}"] = image_value

    resolved_graph = _substitute_placeholders(workflow, replacements)

    metadata: dict[str, Any] = {
        "preset": preset,
        "displayName": profile["displayName"],
        "kind": profile["kind"],
        "template": profile["template"],
        "engineLabel": profiles.get("engineLabel", "本機 ComfyUI"),
        "aspect": aspect,
        "width": int(width),
        "height": int(height),
        "seed": seed,
        "steps": steps,
        "cfg": cfg,
        "sampler": sampler,
        "scheduler": scheduler,
        "shift": shift,
        "guidance": guidance,
        "negativePrompt": negative_prompt,
        "denoise": denoise,
        "lora": lora,
        "loraStrength": lora_strength,
        "prompt": prompt,
        "rawPrompt": raw_prompt,
        "referenceImage": image_value,
    }
    if profile["kind"] == "video":
        metadata["seconds"] = seconds
        metadata["fps"] = fps
        metadata["length"] = length

    return resolved_graph, metadata


def _is_link_ref(value: Any) -> bool:
    return (
        isinstance(value, list)
        and len(value) == 2
        and isinstance(value[0], str)
        and type(value[1]) is int
    )


def _schema_from_object_info(class_type: str, info: dict[str, Any]) -> dict[str, Any]:
    input_spec = info.get("input") or {}
    input_order = info.get("input_order") or {}
    links: list[tuple[str, str, bool]] = []
    widgets: list[tuple[str, str, Any, str | None]] = []

    for section, is_optional in (("required", False), ("optional", True)):
        section_dict = input_spec.get(section) or {}
        ordered_names = input_order.get(section) or list(section_dict.keys())
        for name in ordered_names:
            if name not in section_dict:
                continue
            spec = section_dict[name]
            if not isinstance(spec, (list, tuple)) or not spec:
                continue
            type_decl = spec[0]
            opts = spec[1] if len(spec) > 1 and isinstance(spec[1], dict) else {}
            is_combo = isinstance(type_decl, list)
            is_widget = is_combo or (isinstance(type_decl, str) and type_decl in PRIMITIVE_WIDGET_TYPES)
            if is_widget:
                w_type = "COMBO" if is_combo else str(type_decl)
                default = opts.get("default", type_decl[0] if (is_combo and type_decl) else "")
                extra_after: str | None = None
                if opts.get("control_after_generate") or (
                    w_type == "INT" and name in {"seed", "noise_seed"}
                ):
                    extra_after = "control_after_generate"
                elif opts.get("image_upload") or (class_type == "LoadImage" and name == "image"):
                    extra_after = "image_upload"
                widgets.append((name, w_type, default, extra_after))
            else:
                links.append((name, str(type_decl), is_optional))

    raw_outputs = info.get("output") or []
    raw_names = info.get("output_name") or raw_outputs
    outputs = [
        (str(raw_names[i] if i < len(raw_names) else out_type), str(out_type))
        for i, out_type in enumerate(raw_outputs)
    ]
    fallback_size = NODE_SCHEMAS.get(class_type, {}).get("size", [320, max(80, 56 + 26 * len(widgets))])
    return {
        "links": links,
        "widgets": widgets,
        "outputs": outputs,
        "size": list(fallback_size),
    }


def _resolve_node_schema(
    class_type: str,
    api_inputs: dict[str, Any],
    object_info: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if object_info and isinstance(object_info.get(class_type), dict):
        return _schema_from_object_info(class_type, object_info[class_type])
    if class_type in NODE_SCHEMAS:
        return copy.deepcopy(NODE_SCHEMAS[class_type])
    # Fallback dynamic inference for unknown custom nodes
    links = []
    widgets = []
    for name, val in api_inputs.items():
        if _is_link_ref(val):
            links.append((name, "*", False))
        else:
            w_type = "INT" if type(val) is int else ("FLOAT" if isinstance(val, float) else "STRING")
            extra = "control_after_generate" if (w_type == "INT" and name in {"seed", "noise_seed"}) else None
            widgets.append((name, w_type, val, extra))
    return {
        "links": links,
        "widgets": widgets,
        "outputs": [("*", "*")],
        "size": [320, max(80, 56 + 26 * len(widgets))],
    }


def _assign_node_ids(api_graph: dict[str, Any]) -> dict[str, int]:
    mapping: dict[str, int] = {}
    used: set[int] = set()
    non_numeric: list[str] = []
    for key in sorted(api_graph.keys(), key=lambda k: (0, int(k)) if k.isdigit() else (1, k)):
        if key.isdigit() and int(key) > 0 and int(key) not in used:
            nid = int(key)
            mapping[key] = nid
            used.add(nid)
        else:
            non_numeric.append(key)
    next_id = max(used, default=0) + 1
    for key in non_numeric:
        while next_id in used:
            next_id += 1
        mapping[key] = next_id
        used.add(next_id)
        next_id += 1
    return mapping


def _topological_layers(api_graph: dict[str, Any]) -> tuple[list[str], dict[str, int]]:
    deps: dict[str, set[str]] = {k: set() for k in api_graph}
    children: dict[str, list[str]] = defaultdict(list)
    for dst_key, node in api_graph.items():
        for val in (node.get("inputs") or {}).values():
            if _is_link_ref(val) and val[0] in api_graph:
                src_key = val[0]
                if src_key not in deps[dst_key]:
                    deps[dst_key].add(src_key)
                    children[src_key].append(dst_key)

    def sort_key(k: str) -> tuple[int, Any]:
        return (0, int(k)) if k.isdigit() else (1, k)

    in_deg = {k: len(v) for k, v in deps.items()}
    queue = deque(sorted([k for k, d in in_deg.items() if d == 0], key=sort_key))
    topo: list[str] = []
    depth: dict[str, int] = {k: 0 for k in api_graph}

    while queue:
        curr = queue.popleft()
        topo.append(curr)
        for nxt in sorted(children.get(curr, []), key=sort_key):
            depth[nxt] = max(depth[nxt], depth[curr] + 1)
            in_deg[nxt] -= 1
            if in_deg[nxt] == 0:
                queue.append(nxt)

    # Append any remaining nodes (defensive in case of unexpected cycles)
    for key in sorted(api_graph.keys(), key=sort_key):
        if key not in topo:
            topo.append(key)

    return topo, depth


def api_graph_to_canvas_workflow(
    api_graph: dict[str, Any],
    *,
    object_info: dict[str, Any] | None = None,
    extra_meta: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Convert a ComfyUI API prompt graph into a valid LiteGraph v0.4 Canvas Workflow JSON."""
    if not isinstance(api_graph, dict) or not api_graph:
        raise ValueError("API 工作流圖形不可為空。")

    key_to_id = _assign_node_ids(api_graph)
    topo_order, depth_map = _topological_layers(api_graph)
    order_index = {key: idx for idx, key in enumerate(topo_order)}

    # Resolve schemas for every node first
    schemas: dict[str, dict[str, Any]] = {}
    for key, node in api_graph.items():
        schemas[key] = _resolve_node_schema(node["class_type"], node.get("inputs") or {}, object_info)

    # Ensure output slot counts cover all referenced output indices (for unknown custom nodes)
    for node in api_graph.values():
        for val in (node.get("inputs") or {}).values():
            if _is_link_ref(val) and val[0] in schemas:
                src_key, src_slot = val[0], val[1]
                outs = schemas[src_key]["outputs"]
                while len(outs) <= src_slot:
                    outs.append((f"OUT_{len(outs)}", "*"))

    # Compute tidy non-overlapping layout positions grouped by topological depth column
    columns: dict[int, list[str]] = defaultdict(list)
    for key in topo_order:
        columns[depth_map[key]].append(key)

    positions: dict[str, list[int]] = {}
    col_x = 80
    for col_idx in sorted(columns.keys()):
        col_keys = columns[col_idx]
        cur_y = 80
        max_w = 320
        for key in col_keys:
            w, h = schemas[key]["size"]
            positions[key] = [col_x, cur_y]
            cur_y += int(h) + 70
            max_w = max(max_w, int(w))
        col_x += max_w + 110

    # Build canvas nodes and links with strict bidirectional synchronization
    canvas_nodes_by_key: dict[str, dict[str, Any]] = {}
    for key in topo_order:
        node = api_graph[key]
        class_type = node["class_type"]
        schema = schemas[key]
        api_inputs = node.get("inputs") or {}

        inputs_list: list[dict[str, Any]] = []
        input_slot_by_name: dict[str, int] = {}
        for inp_name, inp_type, is_optional in schema["links"]:
            slot_obj: dict[str, Any] = {
                "name": inp_name,
                "type": inp_type,
                "link": None,
            }
            if is_optional:
                slot_obj["shape"] = 7
            input_slot_by_name[inp_name] = len(inputs_list)
            inputs_list.append(slot_obj)

        widgets_values: list[Any] = []
        for w_name, w_type, w_default, extra_after in schema["widgets"]:
            raw_val = api_inputs.get(w_name, w_default)
            if _is_link_ref(raw_val):
                # Widget input connected by a wire in a custom workflow
                slot_obj = {
                    "name": w_name,
                    "type": w_type,
                    "widget": {"name": w_name},
                    "link": None,
                }
                input_slot_by_name[w_name] = len(inputs_list)
                inputs_list.append(slot_obj)
                widgets_values.append(w_default)
            else:
                widgets_values.append(raw_val)
            if extra_after == "control_after_generate":
                widgets_values.append("fixed")
            elif extra_after == "image_upload":
                widgets_values.append("image")

        # Include any extra wired inputs present in api_inputs not already declared in schema
        for inp_name, raw_val in api_inputs.items():
            if _is_link_ref(raw_val) and inp_name not in input_slot_by_name:
                slot_obj = {
                    "name": inp_name,
                    "type": "*",
                    "link": None,
                }
                input_slot_by_name[inp_name] = len(inputs_list)
                inputs_list.append(slot_obj)

        outputs_list: list[dict[str, Any]] = []
        for slot_idx, (out_name, out_type) in enumerate(schema["outputs"]):
            outputs_list.append({
                "name": out_name,
                "type": out_type,
                "slot_index": slot_idx,
                "links": [],
            })

        canvas_nodes_by_key[key] = {
            "id": key_to_id[key],
            "type": class_type,
            "pos": positions[key],
            "size": list(schema["size"]),
            "flags": {},
            "order": order_index[key],
            "mode": 0,
            "inputs": inputs_list,
            "outputs": outputs_list,
            "properties": {
                "Node name for S&R": class_type,
            },
            "widgets_values": widgets_values,
            "_input_slot_by_name": input_slot_by_name,
        }

    links: list[list[Any]] = []
    next_link_id = 1
    for dst_key in topo_order:
        dst_api_inputs = api_graph[dst_key].get("inputs") or {}
        dst_node = canvas_nodes_by_key[dst_key]
        slot_map = dst_node["_input_slot_by_name"]

        # Iterate in slot order for deterministic link IDs
        ordered_link_names = sorted(
            (name for name, val in dst_api_inputs.items() if _is_link_ref(val)),
            key=lambda n: slot_map[n],
        )
        for inp_name in ordered_link_names:
            src_key, src_slot = dst_api_inputs[inp_name]
            if src_key not in canvas_nodes_by_key:
                raise ValueError(f"節點 {dst_key}.{inp_name} 指向不存在的來源節點 {src_key}。")
            src_node = canvas_nodes_by_key[src_key]
            if not (0 <= src_slot < len(src_node["outputs"])):
                raise ValueError(
                    f"節點 {dst_key}.{inp_name} 指向無效輸出插槽 {src_key}[{src_slot}]。"
                )
            dst_slot = slot_map[inp_name]
            out_type = src_node["outputs"][src_slot]["type"]
            in_type = dst_node["inputs"][dst_slot]["type"]
            link_type = out_type if out_type != "*" else in_type
            if out_type != "*" and in_type == "*":
                dst_node["inputs"][dst_slot]["type"] = out_type

            link_id = next_link_id
            next_link_id += 1
            links.append([
                link_id,
                src_node["id"],
                src_slot,
                dst_node["id"],
                dst_slot,
                link_type,
            ])
            dst_node["inputs"][dst_slot]["link"] = link_id
            src_node["outputs"][src_slot]["links"].append(link_id)

    final_nodes: list[dict[str, Any]] = []
    for key in topo_order:
        node_obj = canvas_nodes_by_key[key]
        node_obj.pop("_input_slot_by_name", None)
        final_nodes.append(node_obj)

    extra: dict[str, Any] = {
        "ds": {"scale": 1.0, "offset": [0, 0]},
    }
    if extra_meta is not None:
        extra["motiondesk"] = copy.deepcopy(extra_meta)

    return {
        "last_node_id": max((n["id"] for n in final_nodes), default=0),
        "last_link_id": max((lnk[0] for lnk in links), default=0),
        "nodes": final_nodes,
        "links": links,
        "groups": [],
        "config": {},
        "extra": extra,
        "version": 0.4,
    }


def _values_equal(expected: Any, actual: Any) -> bool:
    if _is_number(expected) and _is_number(actual):
        return math.isclose(float(expected), float(actual), rel_tol=1e-9, abs_tol=1e-9)
    return expected == actual


def verify_canvas_roundtrip(
    api_graph: dict[str, Any],
    canvas_workflow: dict[str, Any],
    *,
    object_info: dict[str, Any] | None = None,
) -> list[str]:
    """Decode canvas_workflow back into an API graph and verify 100% fidelity against api_graph.

    Returns a list of discrepancies; an empty list indicates an exact match.
    """
    diffs: list[str] = []

    if canvas_workflow.get("version") != 0.4:
        diffs.append(f"Canvas version 應為 0.4，實際為 {canvas_workflow.get('version')!r}。")

    nodes = canvas_workflow.get("nodes")
    links = canvas_workflow.get("links")
    if not isinstance(nodes, list) or not isinstance(links, list):
        diffs.append("Canvas workflow 缺少 nodes 或 links 清單。")
        return diffs

    nodes_by_id: dict[int, dict[str, Any]] = {}
    for node in nodes:
        nid = node.get("id")
        if type(nid) is not int:
            diffs.append(f"Canvas 節點缺少整數 id：{node!r}")
            continue
        if nid in nodes_by_id:
            diffs.append(f"Canvas 出現重複節點 id：{nid}")
        nodes_by_id[nid] = node

    expected_last_node = max(nodes_by_id.keys(), default=0)
    if canvas_workflow.get("last_node_id") != expected_last_node:
        diffs.append(
            f"last_node_id 不一致：預期 {expected_last_node}，實際 {canvas_workflow.get('last_node_id')}。"
        )

    links_by_id: dict[int, list[Any]] = {}
    for lnk in links:
        if not isinstance(lnk, list) or len(lnk) != 6:
            diffs.append(f"link 必須為 6-tuple：{lnk!r}")
            continue
        lid, src_id, src_slot, dst_id, dst_slot, ltype = lnk
        if lid in links_by_id:
            diffs.append(f"重複 link_id：{lid}")
        links_by_id[lid] = lnk
        if src_id not in nodes_by_id:
            diffs.append(f"link {lid} 來源節點 {src_id} 不存在。")
            continue
        if dst_id not in nodes_by_id:
            diffs.append(f"link {lid} 目標節點 {dst_id} 不存在。")
            continue
        src_outs = nodes_by_id[src_id].get("outputs") or []
        dst_ins = nodes_by_id[dst_id].get("inputs") or []
        if not (0 <= src_slot < len(src_outs)):
            diffs.append(f"link {lid} 來源插槽越界：{src_id}[{src_slot}]。")
        elif lid not in (src_outs[src_slot].get("links") or []):
            diffs.append(f"link {lid} 未同步寫入來源節點 {src_id}.outputs[{src_slot}].links。")
        if not (0 <= dst_slot < len(dst_ins)):
            diffs.append(f"link {lid} 目標插槽越界：{dst_id}[{dst_slot}]。")
        elif dst_ins[dst_slot].get("link") != lid:
            diffs.append(f"link {lid} 未同步寫入目標節點 {dst_id}.inputs[{dst_slot}].link。")
        if (
            0 <= src_slot < len(src_outs)
            and 0 <= dst_slot < len(dst_ins)
            and ltype != "*"
            and src_outs[src_slot].get("type") not in ("*", ltype)
        ):
            diffs.append(
                f"link {lid} 型別不符：link={ltype} vs output={src_outs[src_slot].get('type')}。"
            )

    expected_last_link = max(links_by_id.keys(), default=0)
    if canvas_workflow.get("last_link_id") != expected_last_link:
        diffs.append(
            f"last_link_id 不一致：預期 {expected_last_link}，實際 {canvas_workflow.get('last_link_id')}。"
        )

    # Check no orphan link references inside nodes
    for nid, node in nodes_by_id.items():
        for slot_idx, inp in enumerate(node.get("inputs") or []):
            lid = inp.get("link")
            if lid is not None:
                if lid not in links_by_id:
                    diffs.append(f"節點 {nid}.inputs[{slot_idx}] 指向不存在的 link {lid}。")
                else:
                    _, _, _, dst_id, dst_slot, _ = links_by_id[lid]
                    if dst_id != nid or dst_slot != slot_idx:
                        diffs.append(f"節點 {nid}.inputs[{slot_idx}] 與 link {lid} 目標不符。")
        for slot_idx, out in enumerate(node.get("outputs") or []):
            for lid in out.get("links") or []:
                if lid not in links_by_id:
                    diffs.append(f"節點 {nid}.outputs[{slot_idx}] 指向不存在的 link {lid}。")
                else:
                    _, src_id, src_slot, _, _, _ = links_by_id[lid]
                    if src_id != nid or src_slot != slot_idx:
                        diffs.append(f"節點 {nid}.outputs[{slot_idx}] 與 link {lid} 來源不符。")

    # Reconstruct API graph from canvas nodes + links
    key_to_id = _assign_node_ids(api_graph)
    id_to_key = {v: k for k, v in key_to_id.items()}

    expected_ids = set(key_to_id.values())
    actual_ids = set(nodes_by_id.keys())
    if expected_ids != actual_ids:
        diffs.append(f"節點集合不一致：預期 {sorted(expected_ids)}，實際 {sorted(actual_ids)}。")
        return diffs

    for api_key, api_node in api_graph.items():
        nid = key_to_id[api_key]
        cnode = nodes_by_id[nid]
        class_type = api_node["class_type"]
        if cnode.get("type") != class_type:
            diffs.append(f"節點 {api_key} 型別不一致：預期 {class_type}，實際 {cnode.get('type')}。")
            continue

        api_inputs = api_node.get("inputs") or {}
        schema = _resolve_node_schema(class_type, api_inputs, object_info)

        # Decode wired inputs
        decoded_inputs: dict[str, Any] = {}
        for inp in cnode.get("inputs") or []:
            lid = inp.get("link")
            if lid is not None and lid in links_by_id:
                _, src_id, src_slot, _, _, _ = links_by_id[lid]
                src_key = id_to_key.get(src_id, str(src_id))
                decoded_inputs[inp["name"]] = [src_key, src_slot]

        # Decode widgets_values strictly
        wvals = cnode.get("widgets_values") or []
        cursor = 0
        for w_name, _w_type, _w_default, extra_after in schema["widgets"]:
            if cursor >= len(wvals):
                diffs.append(f"節點 {api_key} ({class_type}) widgets_values 過短，缺少 {w_name}。")
                break
            val = wvals[cursor]
            cursor += 1
            if w_name not in decoded_inputs:
                decoded_inputs[w_name] = val
            if extra_after == "control_after_generate":
                if cursor >= len(wvals):
                    diffs.append(f"節點 {api_key} ({class_type}) 缺少 seed 後方的 control_after_generate。")
                    break
                ctrl = wvals[cursor]
                cursor += 1
                if ctrl not in {"fixed", "increment", "decrement", "randomize"}:
                    diffs.append(f"節點 {api_key} ({class_type}) control_after_generate 值異常：{ctrl!r}。")
            elif extra_after == "image_upload":
                if cursor >= len(wvals):
                    diffs.append(f"節點 {api_key} ({class_type}) 缺少檔名後方的 upload widget ('image')。")
                    break
                upload_tag = wvals[cursor]
                cursor += 1
                if upload_tag != "image":
                    diffs.append(f"節點 {api_key} ({class_type}) upload widget 應為 'image'，實際 {upload_tag!r}。")

        if cursor != len(wvals):
            diffs.append(
                f"節點 {api_key} ({class_type}) widgets_values 長度不符：預期 {cursor}，實際 {len(wvals)}。"
            )

        # Compare every input present in original api_graph
        for inp_name, expected_val in api_inputs.items():
            if inp_name not in decoded_inputs:
                diffs.append(f"節點 {api_key} ({class_type}) 遺失輸入 {inp_name}。")
                continue
            actual_val = decoded_inputs[inp_name]
            if not _values_equal(expected_val, actual_val):
                diffs.append(
                    f"節點 {api_key}.{inp_name} 數值不符：API={expected_val!r} vs Canvas={actual_val!r}。"
                )

    return diffs


def write_workflow_bundle(
    api_graph: dict[str, Any],
    output_dir: Path | str,
    base_name: str,
    *,
    object_info: dict[str, Any] | None = None,
    extra_meta: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Convert api_graph to Canvas workflow, verify roundtrip, and write both JSON files."""
    canvas_workflow = api_graph_to_canvas_workflow(
        api_graph,
        object_info=object_info,
        extra_meta=extra_meta,
    )
    diffs = verify_canvas_roundtrip(api_graph, canvas_workflow, object_info=object_info)
    if diffs:
        raise ValueError("ComfyUI 畫布工作流反解驗證失敗：\n" + "\n".join(diffs))

    out_path = Path(output_dir)
    out_path.mkdir(parents=True, exist_ok=True)
    api_path = out_path / f"{base_name}.api.json"
    workflow_path = out_path / f"{base_name}.workflow.json"
    api_path.write_text(json.dumps(api_graph, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    workflow_path.write_text(
        json.dumps(canvas_workflow, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return {
        "apiPath": str(api_path),
        "workflowPath": str(workflow_path),
        "apiGraph": api_graph,
        "canvasWorkflow": canvas_workflow,
        "roundtripDiffs": diffs,
    }


def export_workflow_bundle(
    preset: str,
    request: dict[str, Any],
    resource_dir: Path | str,
    output_dir: Path | str,
    *,
    base_name: str,
    object_info: dict[str, Any] | None = None,
    uploaded_image: str | None = None,
    native_size_fn: Callable[[dict[str, Any], tuple[int, int]], tuple[int, int]] | None = None,
) -> dict[str, Any]:
    """Resolve a built-in preset request, verify Canvas roundtrip, and write .api.json + .workflow.json."""
    api_graph, metadata = resolve_builtin_graph(
        preset,
        request,
        resource_dir,
        uploaded_image=uploaded_image,
        native_size_fn=native_size_fn,
    )
    bundle = write_workflow_bundle(
        api_graph,
        output_dir,
        base_name,
        object_info=object_info,
        extra_meta=metadata,
    )
    bundle["metadata"] = metadata
    return bundle


def _run_self_test(resource_dir: Path, out_dir: Path | None) -> int:
    profiles = load_profiles(resource_dir)
    presets = list_presets(resource_dir)
    print(f"Loaded {len(presets)} presets from {resource_dir}: {', '.join(presets)}")

    # 1. Removed model (realxl) must raise explicit error
    try:
        get_profile("realxl", resource_dir)
        raise AssertionError("realxl should have raised ValueError")
    except ValueError as exc:
        assert "已移除" in str(exc), f"Unexpected realxl message: {exc}"
        print(f"  [PASS] realxl blocked: {exc}")

    # 2. Capability enforcement checks
    bad_cases = [
        ("krea2", {"prompt": "test", "seed": 1, "aspect": "1:1", "reference": "/tmp/a.png"}, "參考圖"),
        ("moss", {"prompt": "test", "seed": 1, "aspect": "1:1", "reference": "/tmp/a.png"}, "參考圖"),
        ("iniverse_flux", {"prompt": "test", "seed": 1, "aspect": "1:1", "lora": "redz15"}, "LoRA"),
        ("krea2", {"prompt": "test", "seed": 1, "aspect": "1:1", "lora": "pixel_art"}, "LoRA"),
        ("moss", {"prompt": "test", "seed": 1, "aspect": "1:1", "lora": "redz15"}, "LoRA"),
        ("sdxl1", {"prompt": "test", "seed": 1, "aspect": "1:1", "lora": "redz15"}, "LoRA"),
        ("zimage", {"prompt": "test", "seed": 1, "aspect": "1:1", "modelParams": {"negativePrompt": "bad"}}, "負向"),
        ("wan22", {"prompt": "test", "seed": 1, "aspect": "16:9", "seconds": 3, "videoMethod": "multi"}, "多影格"),
    ]
    for preset, req, expected_substr in bad_cases:
        try:
            validate_preset_request(preset, req, resource_dir)
            raise AssertionError(f"Expected validation failure for {preset}: {req}")
        except ValueError as exc:
            assert expected_substr in str(exc), f"Expected '{expected_substr}' in '{exc}'"
            print(f"  [PASS] rejected ({preset}): {exc}")

    # 3. Resolve + roundtrip test across all 6 presets and key variants
    cases: list[tuple[str, str, dict[str, Any]]] = [
        ("zimage_t2i", "zimage", {"prompt": "sunlit coffee shop portrait", "seed": 101, "aspect": "16:9"}),
        ("zimage_lora_i2i", "zimage", {
            "prompt": "pixel art café", "seed": 102, "aspect": "1:1",
            "lora": "pixel_art", "reference": "/tmp/ref.png",
            "modelParams": {"steps": 12, "shift": 4.0, "denoise": 0.6},
        }),
        ("redcraft_t2i", "redcraft", {"prompt": "warm loft studio", "seed": 103, "aspect": "9:16"}),
        ("redcraft_lora_i2i", "redcraft", {
            "prompt": "editorial portrait", "seed": 104, "aspect": "16:9",
            "lora": "redz15", "reference": "/tmp/portrait.jpg",
            "modelParams": {"steps": 10, "shift": 3.5, "denoise": 0.5, "sampler": "euler"},
        }),
        ("flux_t2i_16x9", "iniverse_flux", {
            "prompt": "architectural twilight", "seed": 105, "aspect": "16:9",
            "modelParams": {"guidance": 2.8, "steps": 24, "scheduler": "beta"},
        }),
        ("flux_i2i", "iniverse_flux", {
            "prompt": "film still", "seed": 106, "aspect": "1:1", "reference": "/tmp/frame.png",
        }),
        ("moss_t2i", "moss", {
            "prompt": "full body documentary street portrait", "seed": 107, "aspect": "1:1",
            "modelParams": {"steps": 25, "cfg": 2.5, "negativePrompt": "low quality, blurry, jpeg artifacts, watermark"},
        }),
        ("krea2_t2i", "krea2", {"prompt": "vintage workshop", "seed": 108, "aspect": "16:9"}),
        ("sdxl1_t2i_16x9", "sdxl1", {
            "prompt": "alpine lake at dawn, crisp natural light", "seed": 111, "aspect": "16:9",
            "modelParams": {"negativePrompt": "blurry, watermark"},
        }),
        ("sdxl1_i2i", "sdxl1", {
            "prompt": "watercolor alpine lake", "seed": 112, "aspect": "1:1",
            "reference": "/tmp/lake.png", "modelParams": {"denoise": 0.6},
        }),
        ("wan22_t2v", "wan22", {"prompt": "gentle breeze through curtains", "seed": 109, "aspect": "16:9", "seconds": 3}),
        ("wan22_i2v", "wan22", {
            "prompt": "person waves gently", "seed": 110, "aspect": "16:9", "seconds": 2,
            "reference": "/tmp/start_frame.png",
        }),
    ]

    for name, preset, req in cases:
        api_graph, meta = resolve_builtin_graph(preset, req, resource_dir)
        canvas = api_graph_to_canvas_workflow(api_graph, extra_meta=meta)
        diffs = verify_canvas_roundtrip(api_graph, canvas)
        assert not diffs, f"Roundtrip failed for {name}: {diffs}"

        # Extra invariants
        if preset == "iniverse_flux":
            assert api_graph["12"]["class_type"] == "ModelSamplingFlux"
            assert api_graph["12"]["inputs"]["width"] == meta["width"]
            assert api_graph["12"]["inputs"]["height"] == meta["height"]
        if preset == "wan22":
            assert api_graph["8"]["inputs"]["sampler_name"] == "euler"
            assert api_graph["9"]["class_type"] == "VAEDecode"
            assert api_graph["2"]["inputs"]["device"] == "default"
            assert api_graph["6"]["inputs"]["length"] == 24 * req["seconds"] + 1
        if preset == "moss":
            assert all(n["class_type"] != "ModelSamplingSD3" for n in api_graph.values()), "REGRESSION: MOSS must NOT inject ModelSamplingSD3"
            assert api_graph["7"]["class_type"] == "SkipLayerGuidanceDiTSimple"
            assert api_graph["7"]["inputs"]["model"] == ["1", 0]
            assert api_graph["8"]["inputs"]["sampler_name"] == "euler"
            assert api_graph["8"]["inputs"]["scheduler"] == "simple"
            assert api_graph["8"]["inputs"]["steps"] == 25
            assert abs(float(api_graph["8"]["inputs"]["cfg"]) - 2.5) < 1e-6
            assert meta["width"] == 1024 and meta["height"] == 1024
        if preset == "sdxl1":
            assert api_graph["1"]["class_type"] == "CheckpointLoaderSimple"
            assert api_graph["1"]["inputs"]["ckpt_name"] == "sd_xl_base_1.0.safetensors"
            assert api_graph["2"]["class_type"] == "CLIPTextEncode"
            assert api_graph["3"]["class_type"] == "CLIPTextEncode"
            assert api_graph["5"]["inputs"]["steps"] == 30
            assert abs(float(api_graph["5"]["inputs"]["cfg"]) - 7.0) < 1e-6
            assert api_graph["5"]["inputs"]["sampler_name"] == "dpmpp_2m"
            assert api_graph["5"]["inputs"]["scheduler"] == "karras"
            assert api_graph["6"]["class_type"] == "VAEDecode"
            assert api_graph["6"]["inputs"]["vae"] == ["1", 2]
            assert api_graph["7"]["class_type"] == "SaveImage"
            if name == "sdxl1_t2i_16x9":
                assert api_graph["4"]["class_type"] == "EmptyLatentImage"
                assert meta["width"] == 1344 and meta["height"] == 768
                assert api_graph["3"]["inputs"]["text"] == "blurry, watermark"
            elif name == "sdxl1_i2i":
                assert "4" not in api_graph
                assert api_graph["22"]["class_type"] == "VAEEncode"
                assert api_graph["22"]["inputs"]["vae"] == ["1", 2]
                assert abs(float(api_graph["5"]["inputs"]["denoise"]) - 0.6) < 1e-6

        # Verify KSampler has 7 widget values with "fixed" at index 1
        for cnode in canvas["nodes"]:
            if cnode["type"] == "KSampler":
                assert len(cnode["widgets_values"]) == 7, f"{name}: KSampler widgets != 7"
                assert cnode["widgets_values"][1] == "fixed", f"{name}: KSampler control != fixed"
            if cnode["type"] == "LoadImage":
                assert len(cnode["widgets_values"]) == 2, f"{name}: LoadImage widgets != 2"
                assert cnode["widgets_values"][1] == "image", f"{name}: LoadImage upload != image"

        if out_dir is not None:
            export_workflow_bundle(preset, req, resource_dir, out_dir, base_name=name)
        print(f"  [PASS] {name}: {len(api_graph)} nodes, {len(canvas['links'])} links, 0 roundtrip diffs")

    assert "realxl" not in profiles["models"]
    print("ALL SELF-TESTS PASSED.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="MotionDesk ComfyUI workflow utility")
    parser.add_argument(
        "--resource-dir",
        type=Path,
        default=Path(__file__).resolve().parent,
        help="Directory containing model_profiles.json and template JSONs",
    )
    parser.add_argument("--self-test", action="store_true", help="Run full validation & roundtrip self-tests")
    parser.add_argument("--export-dir", type=Path, default=None, help="Optional directory to write self-test bundles")
    args = parser.parse_args()
    if args.self_test:
        return _run_self_test(args.resource_dir, args.export_dir)
    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
