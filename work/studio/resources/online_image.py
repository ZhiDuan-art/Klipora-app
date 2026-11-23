#!/usr/bin/env python3
"""Standard-library HTTPS client for opt-in OpenAI and Gemini image generation APIs.

Security & billing invariants:
- Fixed official API hosts only (api.openai.com / generativelanguage.googleapis.com).
- Redirects are blocked (never forwards Authorization or x-goog-api-key headers).
- API keys are never written to request/project JSON, CLI arguments, or logs.
- No arbitrary remote URI downloader; only decodes inline base64 image payloads.
"""

from __future__ import annotations

import base64
import json
import mimetypes
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable
from uuid import uuid4

OPENAI_ENDPOINT = "https://api.openai.com/v1/images/generations"
OPENAI_EDITS_ENDPOINT = "https://api.openai.com/v1/images/edits"
OPENAI_HOST = "api.openai.com"
OPENAI_DEFAULT_MODEL = "gpt-image-2.5-flare"

GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/interactions"
GEMINI_HOST = "generativelanguage.googleapis.com"
GEMINI_DEFAULT_MODEL = "gemini-nano-banana-2.1"
GEMINI_API_REVISION = "2026-05-20"

_MIME_TO_EXT = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/webp": ".webp",
}

TransportFn = Callable[[str, dict[str, str], bytes, float], tuple[int, bytes]]


class _BlockRedirectsHandler(urllib.request.HTTPRedirectHandler):
    """Reject HTTP redirects so API credentials are never forwarded to another location."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(
            req.full_url,
            code,
            "安全限制：官方 API 端點禁止自動重新導向，以避免洩漏認證標頭。",
            headers,
            fp,
        )


def _verify_fixed_https_host(url: str, expected_host: str) -> None:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or (parsed.hostname or "").lower() != expected_host:
        raise ValueError(f"安全限制：僅允許連線至官方 HTTPS 主機 {expected_host}。")


def _redact_secret(text: str, secret: str) -> str:
    """Redact any occurrence of the API key (raw or URL-encoded) from error strings before logging/returning."""
    if not text or not secret:
        return text
    cleaned = text.replace(secret, "[REDACTED]")
    encoded = urllib.parse.quote(secret, safe="")
    if encoded and encoded != secret:
        cleaned = cleaned.replace(encoded, "[REDACTED]")
    return cleaned


def _extract_error_detail(raw: bytes, secret: str) -> str:
    detail = ""
    try:
        parsed = json.loads(raw.decode("utf-8", "replace"))
        if isinstance(parsed, dict):
            err = parsed.get("error")
            if isinstance(err, dict):
                detail = str(err.get("message") or "")
            elif isinstance(err, str):
                detail = err
    except Exception:
        detail = raw.decode("utf-8", "replace")[:240]
    return _redact_secret(detail, secret)


def _default_https_transport(
    url: str, headers: dict[str, str], body: bytes, timeout: float = 120.0
) -> tuple[int, bytes]:
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    opener = urllib.request.build_opener(_BlockRedirectsHandler())
    secret = ""
    auth = headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        secret = auth[len("Bearer "):].strip()
    elif headers.get("x-goog-api-key"):
        secret = headers["x-goog-api-key"].strip()
    try:
        with opener.open(req, timeout=timeout) as resp:
            return int(resp.status), resp.read()
    except urllib.error.HTTPError as exc:
        err_body = b""
        try:
            err_body = exc.read()
        except Exception:
            pass
        detail = _extract_error_detail(err_body, secret)
        reason = _redact_secret(str(exc.reason or ""), secret)
        raise RuntimeError(f"API 回傳 HTTP {exc.code}：{detail or reason}") from None


def _openai_size_for_aspect(aspect: str) -> str:
    mapping = {
        "16:9": "1536x1024",
        "9:16": "1024x1536",
        "1:1": "1024x1024",
    }
    return mapping.get((aspect or "").strip(), "1024x1024")


def _gemini_aspect(aspect: str) -> str:
    allowed = {"16:9", "9:16", "1:1", "4:3", "3:4"}
    cleaned = (aspect or "").strip()
    return cleaned if cleaned in allowed else "16:9"


def _mime_for_image_path(path: Path) -> str:
    ext = path.suffix.lower()
    if ext == ".png":
        return "image/png"
    if ext in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if ext == ".webp":
        return "image/webp"
    guessed, _ = mimetypes.guess_type(str(path))
    return guessed or "image/png"


def _resolve_reference_images(reference_images: list[str] | None) -> list[Path]:
    if not reference_images:
        return []
    resolved: list[Path] = []
    seen: set[str] = set()
    for raw in reference_images:
        text = str(raw or "").strip()
        if not text:
            continue
        p = Path(text).expanduser()
        if not p.is_file():
            raise ValueError(f"找不到參考圖片：{p.name or text}")
        key = str(p.resolve())
        if key not in seen:
            seen.add(key)
            resolved.append(p)
        if len(resolved) >= 8:
            break
    return resolved


def _enrich_prompt_with_references(prompt: str, paths: list[Path], roles: list[str] | None) -> str:
    if not paths:
        return prompt
    entries: list[str] = []
    for idx, path in enumerate(paths):
        role = ""
        if roles and idx < len(roles):
            role = str(roles[idx] or "").strip()
        role_suffix = f"（{role}）" if role else ""
        entries.append(f"@圖片{idx + 1}{role_suffix}: {path.name}")
    legend = "【參考素材對照】" + "；".join(entries)
    return f"{legend}\n\n{prompt}"


def _build_multipart_form(
    fields: list[tuple[str, str]],
    files: list[tuple[str, str, str, bytes]],
) -> tuple[str, bytes]:
    boundary = f"----KliporaBoundary{uuid4().hex}"
    chunks: list[bytes] = []
    for name, value in fields:
        chunks.append(f"--{boundary}\r\n".encode("ascii"))
        chunks.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
        chunks.append(value.encode("utf-8"))
        chunks.append(b"\r\n")
    for field_name, filename, content_type, data in files:
        safe_name = filename.replace('"', "_")
        chunks.append(f"--{boundary}\r\n".encode("ascii"))
        chunks.append(
            f'Content-Disposition: form-data; name="{field_name}"; filename="{safe_name}"\r\n'.encode("utf-8")
        )
        chunks.append(f"Content-Type: {content_type}\r\n\r\n".encode("ascii"))
        chunks.append(data)
        chunks.append(b"\r\n")
    chunks.append(f"--{boundary}--\r\n".encode("ascii"))
    return f"multipart/form-data; boundary={boundary}", b"".join(chunks)


def generate_openai_image(
    *,
    prompt: str,
    api_key: str,
    output_dir: Path,
    model: str = OPENAI_DEFAULT_MODEL,
    aspect: str = "1:1",
    quality: str = "low",
    reference_images: list[str] | None = None,
    reference_roles: list[str] | None = None,
    transport: TransportFn | None = None,
) -> dict[str, Any]:
    """Call OpenAI Images API (/v1/images/generations or /v1/images/edits for multi-reference) and write decoded image bytes."""
    key = (api_key or "").strip()
    if not key:
        raise ValueError("缺少 OpenAI API 金鑰（請先於「元件與連線設定」的 Keychain 設定）。")
    cleaned_prompt = (prompt or "").strip()
    if not cleaned_prompt:
        raise ValueError("請先輸入圖片提示詞。")
    model_id = (model or "").strip() or OPENAI_DEFAULT_MODEL
    if quality not in {"low", "medium", "high"}:
        quality = "low"

    ref_paths = _resolve_reference_images(reference_images)
    size_str = _openai_size_for_aspect(aspect)
    send = transport or _default_https_transport

    if ref_paths:
        endpoint = OPENAI_EDITS_ENDPOINT
        _verify_fixed_https_host(endpoint, OPENAI_HOST)
        enriched = _enrich_prompt_with_references(cleaned_prompt, ref_paths, reference_roles)
        fields = [
            ("model", model_id),
            ("prompt", enriched),
            ("n", "1"),
            ("size", size_str),
            ("quality", quality),
        ]
        file_parts = [
            ("image[]", p.name, _mime_for_image_path(p), p.read_bytes())
            for p in ref_paths
        ]
        content_type, body_bytes = _build_multipart_form(fields, file_parts)
        headers = {
            "Authorization": f"Bearer {key}",
            "Content-Type": content_type,
        }
    else:
        endpoint = OPENAI_ENDPOINT
        _verify_fixed_https_host(endpoint, OPENAI_HOST)
        payload = {
            "model": model_id,
            "prompt": cleaned_prompt,
            "n": 1,
            "size": size_str,
            "quality": quality,
        }
        headers = {
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        }
        body_bytes = json.dumps(payload).encode("utf-8")

    try:
        status, raw = send(endpoint, headers, body_bytes, 120.0)
    except Exception as exc:
        raise RuntimeError(_redact_secret(str(exc), key)) from None
    if not (200 <= status < 300):
        detail = _extract_error_detail(raw, key)
        raise RuntimeError(f"OpenAI 圖片 API 失敗（HTTP {status}）{('：' + detail) if detail else ''}。")
    try:
        data = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        raise RuntimeError(f"無法解析 OpenAI API 回應 JSON：{exc}") from None

    items = data.get("data") if isinstance(data, dict) else None
    if not isinstance(items, list) or not items:
        raise RuntimeError("OpenAI API 未回傳任何圖片資料。")
    first = items[0]
    if not isinstance(first, dict) or not isinstance(first.get("b64_json"), str) or not first["b64_json"].strip():
        raise RuntimeError("OpenAI API 回應缺少 b64_json 圖片內容（不支援任意遠端 URL 自動下載）。")

    try:
        image_bytes = base64.b64decode(first["b64_json"], validate=True)
    except Exception as exc:
        raise RuntimeError(f"OpenAI 回傳的圖片 base64 內容無效：{exc}") from None
    if not image_bytes:
        raise RuntimeError("OpenAI 回傳的圖片資料為空。")

    output_dir.mkdir(parents=True, exist_ok=True)
    out_file = output_dir / "openai_image_01.png"
    out_file.write_bytes(image_bytes)
    return {
        "paths": [str(out_file)],
        "provider": "openai",
        "model": model_id,
        "size": size_str,
        "quality": quality,
        "reference_count": len(ref_paths),
    }


def generate_gemini_image(
    *,
    prompt: str,
    api_key: str,
    output_dir: Path,
    model: str = GEMINI_DEFAULT_MODEL,
    aspect: str = "16:9",
    image_size: str = "1K",
    reference_images: list[str] | None = None,
    reference_roles: list[str] | None = None,
    transport: TransportFn | None = None,
) -> dict[str, Any]:
    """Call Gemini Interactions API (POST /v1beta/interactions) with optional multi-image references."""
    key = (api_key or "").strip()
    if not key:
        raise ValueError("缺少 Gemini API 金鑰（請先於「元件與連線設定」的 Keychain 設定）。")
    cleaned_prompt = (prompt or "").strip()
    if not cleaned_prompt:
        raise ValueError("請先輸入圖片提示詞。")
    model_id = (model or "").strip() or GEMINI_DEFAULT_MODEL
    if image_size not in {"1K", "2K"}:
        image_size = "1K"

    ref_paths = _resolve_reference_images(reference_images)
    _verify_fixed_https_host(GEMINI_ENDPOINT, GEMINI_HOST)
    if ref_paths:
        enriched = _enrich_prompt_with_references(cleaned_prompt, ref_paths, reference_roles)
        input_field: Any = [{"type": "text", "text": enriched}]
        for p in ref_paths:
            input_field.append({
                "type": "image",
                "data": base64.b64encode(p.read_bytes()).decode("ascii"),
                "mime_type": _mime_for_image_path(p),
            })
    else:
        input_field = cleaned_prompt

    payload = {
        "model": model_id,
        "input": input_field,
        "response_format": {
            "type": "image",
            "aspect_ratio": _gemini_aspect(aspect),
            "image_size": image_size,
        },
    }
    headers = {
        "x-goog-api-key": key,
        "Content-Type": "application/json",
        "Api-Revision": GEMINI_API_REVISION,
    }
    send = transport or _default_https_transport
    try:
        status, raw = send(GEMINI_ENDPOINT, headers, json.dumps(payload).encode("utf-8"), 120.0)
    except Exception as exc:
        raise RuntimeError(_redact_secret(str(exc), key)) from None
    if not (200 <= status < 300):
        detail = _extract_error_detail(raw, key)
        raise RuntimeError(f"Gemini 圖片 API 失敗（HTTP {status}）{('：' + detail) if detail else ''}。")
    try:
        data = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        raise RuntimeError(f"無法解析 Gemini API 回應 JSON：{exc}") from None

    if not isinstance(data, dict):
        raise RuntimeError("Gemini API 回應格式無效。")
    if data.get("status") in {"blocked", "failed", "cancelled"}:
        raise RuntimeError(f"Gemini API 未輸出圖片（狀態：{data.get('status')}）。")

    steps = data.get("steps")
    if not isinstance(steps, list):
        raise RuntimeError("Gemini API 回應缺少 steps 欄位。")

    found_b64: str | None = None
    found_mime = "image/png"
    for step in steps:
        if not isinstance(step, dict) or step.get("type") != "model_output":
            continue
        contents = step.get("content")
        if not isinstance(contents, list):
            continue
        for item in contents:
            if not isinstance(item, dict) or item.get("type") != "image":
                continue
            b64_data = item.get("data")
            if isinstance(b64_data, str) and b64_data.strip():
                found_b64 = b64_data.strip()
                mime = item.get("mime_type")
                if isinstance(mime, str) and mime.lower() in _MIME_TO_EXT:
                    found_mime = mime.lower()
                break
        if found_b64:
            break

    if not found_b64:
        raise RuntimeError("Gemini API 的 model_output 未包含可用的 inline 圖片資料（可能已被阻擋或省略）。")

    try:
        image_bytes = base64.b64decode(found_b64, validate=True)
    except Exception as exc:
        raise RuntimeError(f"Gemini 回傳的圖片 base64 內容無效：{exc}") from None
    if not image_bytes:
        raise RuntimeError("Gemini 回傳的圖片資料為空。")

    ext = _MIME_TO_EXT.get(found_mime, ".png")
    output_dir.mkdir(parents=True, exist_ok=True)
    out_file = output_dir / f"gemini_image_01{ext}"
    out_file.write_bytes(image_bytes)
    return {
        "paths": [str(out_file)],
        "provider": "gemini",
        "model": model_id,
        "aspect_ratio": payload["response_format"]["aspect_ratio"],
        "image_size": image_size,
        "mime_type": found_mime,
    }
