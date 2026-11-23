"""Local worker for MotionDesk 0.2. Takes one request and writes one result."""
import base64
import hashlib
import html
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
from uuid import uuid4

RESOURCE = Path(__file__).resolve().parent
if str(RESOURCE) not in sys.path:
    sys.path.insert(0, str(RESOURCE))

import comfy_workflows
import online_image
import timeline_render

H3 = RESOURCE / "h3" / "scripts"
os.environ["PATH"] = os.pathsep.join([
    str(RESOURCE / "runtime/bin"), str(Path.home() / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin",
    os.environ.get("PATH", ""),
])
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".tif", ".tiff", ".heic", ".bmp"}
VIDEO_EXT = {".mp4", ".mov", ".m4v", ".webm", ".mkv"}
AUDIO_EXT = {".wav", ".mp3", ".flac", ".m4a", ".aac"}
MEDIA_EXT = IMAGE_EXT | VIDEO_EXT | AUDIO_EXT
ASPECT_RATIOS = {"16:9": 16 / 9, "9:16": 9 / 16, "1:1": 1}
MAX_CLOUD_REFERENCE_IMAGES = 8
MAX_CLOUD_KEYFRAMES = 32
TIMELINE_EFFECTS = timeline_render.TIMELINE_EFFECTS
# Match the references recognized by H3 Toybox's resolve_mentions().
MENTION_RE = re.compile(r"@(圖片|图片|Image|影片|视频|Video|音訊|音频|Audio)\s?(\d+)", re.IGNORECASE)


def log(message):
    print(message, flush=True)


def emit_progress(pct=None, step=None, max_step=None, stage=""):
    payload = {}
    if pct is not None:
        payload["pct"] = round(max(0.0, min(1.0, float(pct))), 4)
    if step is not None:
        payload["step"] = int(step)
    if max_step is not None:
        payload["max"] = int(max_step)
    if stage:
        payload["stage"] = str(stage)
    if payload:
        print("KLIPORA_PROGRESS:" + json.dumps(payload, ensure_ascii=False), flush=True)


_COMFY_STAGE_MAP = {
    "UNETLoader": ("載入模型", 0.05),
    "CLIPLoader": ("載入模型", 0.05),
    "DualCLIPLoader": ("載入模型", 0.05),
    "VAELoader": ("載入模型", 0.06),
    "CheckpointLoaderSimple": ("載入模型", 0.05),
    "LoraLoader": ("載入模型", 0.06),
    "LoraLoaderModelOnly": ("載入模型", 0.06),
    "CLIPTextEncode": ("編碼條件", 0.09),
    "WanImageToVideo": ("準備影格", 0.10),
    "EmptySD3LatentImage": ("初始化潛空間", 0.10),
    "EmptyLatentImage": ("初始化潛空間", 0.10),
    "LoadImage": ("載入參考圖", 0.08),
    "KSampler": ("採樣生成中", 0.12),
    "KSamplerAdvanced": ("採樣生成中", 0.12),
    "SamplerCustom": ("採樣生成中", 0.12),
    "SamplerCustomAdvanced": ("採樣生成中", 0.12),
    "VAEDecode": ("VAE 解碼中", 0.92),
    "VAEDecodeTiled": ("VAE 解碼中", 0.92),
    "CreateVideo": ("封裝影片中", 0.96),
    "SaveVideo": ("儲存影片中", 0.97),
    "SaveImage": ("儲存圖片中", 0.97),
    "VHS_VideoCombine": ("封裝影片中", 0.96),
}


class _ComfyProgressMonitor:
    """Zero-dependency RFC 6455 WebSocket listener for live ComfyUI step & stage progress."""

    def __init__(self, base_url, client_id, graph):
        self.base_url = base_url
        self.client_id = client_id
        self.graph = graph if isinstance(graph, dict) else {}
        self.prompt_id = None
        self.last_activity = time.monotonic()
        self._stop = threading.Event()
        self._sock = None
        self._last_pct = 0.0
        self._current_stage = ""
        self._thread = threading.Thread(target=self._run, name="comfy-ws-progress", daemon=True)

    def start(self):
        self._thread.start()

    def set_prompt_id(self, prompt_id):
        self.prompt_id = prompt_id

    def seconds_since_activity(self):
        return max(0.0, time.monotonic() - self.last_activity)

    def close(self):
        self._stop.set()
        sock = self._sock
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            try:
                sock.close()
            except Exception:
                pass
        self._thread.join(timeout=1.5)

    def _recv_exact(self, sock, n):
        chunks = bytearray()
        while len(chunks) < n and not self._stop.is_set():
            try:
                part = sock.recv(n - len(chunks))
            except socket.timeout:
                continue
            if not part:
                return None
            chunks.extend(part)
        return bytes(chunks) if len(chunks) == n else None

    def _send_pong(self, sock, payload):
        try:
            mask = os.urandom(4)
            length = len(payload)
            header = bytearray([0x8A])
            if length < 126:
                header.append(0x80 | length)
            elif length < 65536:
                header.append(0x80 | 126)
                header.extend(struct.pack("!H", length))
            else:
                header.append(0x80 | 127)
                header.extend(struct.pack("!Q", length))
            header.extend(mask)
            masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            sock.sendall(bytes(header) + masked)
        except Exception:
            pass

    def _handle_message(self, raw_text):
        try:
            msg = json.loads(raw_text)
        except Exception:
            return
        if not isinstance(msg, dict):
            return
        mtype = msg.get("type")
        data = msg.get("data") if isinstance(msg.get("data"), dict) else {}
        msg_pid = data.get("prompt_id")
        if self.prompt_id and msg_pid and msg_pid != self.prompt_id:
            return

        self.last_activity = time.monotonic()

        if mtype == "execution_start":
            self._current_stage = "準備執行"
            self._last_pct = max(self._last_pct, 0.02)
            emit_progress(pct=self._last_pct, stage=self._current_stage)
        elif mtype == "executing":
            node_id = data.get("node")
            if node_id is None:
                self._current_stage = "整理成品"
                self._last_pct = max(self._last_pct, 0.98)
                emit_progress(pct=self._last_pct, stage=self._current_stage)
                return
            node_info = self.graph.get(str(node_id))
            class_type = node_info.get("class_type", "") if isinstance(node_info, dict) else ""
            stage_label, stage_pct = _COMFY_STAGE_MAP.get(class_type, (class_type or "執行節點中", self._last_pct))
            self._current_stage = stage_label
            if stage_pct > self._last_pct:
                self._last_pct = stage_pct
            emit_progress(pct=self._last_pct, stage=self._current_stage)
        elif mtype == "progress":
            val = data.get("value")
            mx = data.get("max")
            if isinstance(val, (int, float)) and isinstance(mx, (int, float)) and mx > 0:
                ratio = max(0.0, min(1.0, float(val) / float(mx)))
                # Map sampler steps smoothly across 12%..90% so VAE decode & video save still show headroom.
                pct = max(self._last_pct, 0.12 + 0.78 * ratio)
                self._last_pct = pct
                stage = self._current_stage or "採樣生成中"
                emit_progress(pct=pct, step=int(val), max_step=int(mx), stage=stage)

    def _run(self):
        try:
            parsed = urlsplit(self.base_url)
            host = parsed.hostname or "127.0.0.1"
            use_tls = parsed.scheme == "https"
            port = parsed.port or (443 if use_tls else 80)
            base_path = parsed.path.rstrip("/")
            ws_path = f"{base_path}/ws?clientId={quote(self.client_id, safe='')}"
            raw_sock = socket.create_connection((host, port), timeout=5.0)
            if use_tls:
                ctx = ssl.create_default_context()
                sock = ctx.wrap_socket(raw_sock, server_hostname=host)
            else:
                sock = raw_sock
            sock.settimeout(2.0)
            self._sock = sock

            ws_key = base64.b64encode(os.urandom(16)).decode("ascii")
            host_header = f"{host}:{port}" if parsed.port else host
            headers = [
                f"GET {ws_path} HTTP/1.1",
                f"Host: {host_header}",
                "Upgrade: websocket",
                "Connection: Upgrade",
                f"Sec-WebSocket-Key: {ws_key}",
                "Sec-WebSocket-Version: 13",
            ]
            token = os.environ.get("MOTIONDESK_COMFY_BEARER_TOKEN", "").strip()
            if token:
                headers.append(f"Authorization: Bearer {token}")
            req = ("\r\n".join(headers) + "\r\n\r\n").encode("ascii")
            sock.sendall(req)

            resp = bytearray()
            while b"\r\n\r\n" not in resp and len(resp) < 16384 and not self._stop.is_set():
                try:
                    chunk = sock.recv(1024)
                except socket.timeout:
                    continue
                if not chunk:
                    return
                resp.extend(chunk)
            header_end = resp.find(b"\r\n\r\n")
            if header_end < 0 or b" 101 " not in resp[:header_end].split(b"\r\n", 1)[0]:
                return

            leftover = bytes(resp[header_end + 4:])
            buf = bytearray(leftover)

            def read_bytes(n):
                while len(buf) < n and not self._stop.is_set():
                    try:
                        chunk = sock.recv(max(4096, n - len(buf)))
                    except socket.timeout:
                        continue
                    if not chunk:
                        return None
                    buf.extend(chunk)
                if len(buf) < n:
                    return None
                out = bytes(buf[:n])
                del buf[:n]
                return out

            text_fragments = []
            while not self._stop.is_set():
                hdr = read_bytes(2)
                if hdr is None:
                    break
                b0, b1 = hdr[0], hdr[1]
                fin = (b0 & 0x80) != 0
                opcode = b0 & 0x0F
                masked = (b1 & 0x80) != 0
                length = b1 & 0x7F
                if length == 126:
                    ext = read_bytes(2)
                    if ext is None:
                        break
                    length = struct.unpack("!H", ext)[0]
                elif length == 127:
                    ext = read_bytes(8)
                    if ext is None:
                        break
                    length = struct.unpack("!Q", ext)[0]
                mask_key = read_bytes(4) if masked else None
                if masked and mask_key is None:
                    break
                payload = read_bytes(length) if length > 0 else b""
                if payload is None:
                    break
                if masked and mask_key:
                    payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))

                if opcode == 0x8:  # close
                    break
                elif opcode == 0x9:  # ping
                    self._send_pong(sock, payload)
                elif opcode == 0x1:  # text
                    text_fragments = [payload]
                    if fin:
                        self._handle_message(payload.decode("utf-8", errors="replace"))
                        text_fragments = []
                elif opcode == 0x0 and text_fragments:  # continuation
                    text_fragments.append(payload)
                    if fin:
                        self._handle_message(b"".join(text_fragments).decode("utf-8", errors="replace"))
                        text_fragments = []
        except Exception:
            pass


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def tool(name):
    path = shutil.which(name)
    if not path:
        raise ValueError(f"找不到 {name}，請確認已安裝且可從終端執行。")
    return path


def textrender_binary():
    candidate = RESOURCE / "textrender"
    if candidate.is_file() and os.access(candidate, os.X_OK):
        return str(candidate)
    return None


def preset_ids():
    return set(comfy_workflows.list_presets(RESOURCE))


def removed_model_ids():
    profiles = comfy_workflows.load_profiles(RESOURCE)
    return set((profiles.get("removedModels") or {}).keys())


def pixel_size(request):
    value = request.get("pixelSize")
    if value is None:
        return None
    if not isinstance(value, dict):
        raise ValueError("請填寫輸出寬度與高度。")
    size = (value.get("width"), value.get("height"))
    if any(type(n) is not int or not 64 <= n <= 4096 for n in size):
        raise ValueError("寬高請填 64–4096 之間的整數。")
    if (request["action"] == "export" or request.get("kind") == "video") and any(n % 2 for n in size):
        raise ValueError("影片寬高須為偶數。")
    return size


def native_size(request, default):
    size = pixel_size(request)
    if not size:
        return default
    width, height = size
    preset = request.get("preset") if request.get("action") == "export_workflow" else request.get("action")
    if preset in preset_ids():
        profile = comfy_workflows.get_profile(preset, RESOURCE)
        alignment = int(profile.get("alignment", 16))
        max_pixels = int(profile.get("maxPixels", 2 * 1024 * 1024))
    else:
        alignment, max_pixels = (32, 1280 * 704) if preset in {"wan22", "wan22_14b", "ltxv13b"} else (16, 2 * 1024 * 1024)
    if width % alignment == 0 and height % alignment == 0 and width * height <= max_pixels:
        return size
    return default


def local_base(value):
    parsed = urlsplit(value)
    if (parsed.scheme != "http" or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}
            or parsed.username or parsed.password or parsed.path not in ("", "/")
            or parsed.query or parsed.fragment):
        raise ValueError("本機 ComfyUI 請填入本機位址，例如 http://127.0.0.1:8188。")
    return value.rstrip("/")


class LocalRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


LOCAL_HTTP = build_opener(ProxyHandler({}), LocalRedirectHandler())


def api(base, route, payload=None, content_type="application/json", raw=False, timeout=25):
    headers = {"Content-Type": content_type} if payload is not None else {}
    token = os.environ.get("MOTIONDESK_COMFY_BEARER_TOKEN", "").strip()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if payload is not None and not isinstance(payload, bytes):
        payload = json.dumps(payload, ensure_ascii=False).encode()
    try:
        with LOCAL_HTTP.open(Request(base + route, data=payload, headers=headers), timeout=timeout) as response:
            return response.read() if raw else json.load(response)
    except HTTPError as exc:
        raise ValueError(f"本機 ComfyUI {route} 回傳 {exc.code}：{exc.read(3000).decode(errors='replace')}") from exc
    except URLError as exc:
        raise ValueError(f"無法連線到本機 ComfyUI（{base}），請開啟 ComfyUI 並確認連接埠。{exc.reason}") from exc


def fetch_object_info(base, graph):
    info = {}
    for class_type in sorted({node.get("class_type", "") for node in graph.values() if isinstance(node, dict)}):
        if not class_type:
            continue
        try:
            resp = api(base, "/object_info/" + quote(class_type, safe=""), timeout=8)
            if isinstance(resp, dict) and class_type in resp:
                info[class_type] = resp[class_type]
        except Exception:
            continue
    return info or None


def upload(base, path):
    if path.suffix.lower() not in IMAGE_EXT:
        raise ValueError("本機 ComfyUI 的 IMAGE 欄位需要參考圖片。")
    boundary = uuid4().hex
    name = f"studio_{uuid4().hex}{path.suffix.lower()}"
    data = (f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="{name}"'
            '\r\nContent-Type: application/octet-stream\r\n\r\n').encode()
    data += path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    obj = api(base, "/upload/image", data, "multipart/form-data; boundary=" + boundary)
    return "/".join(part for part in (obj.get("subfolder"), obj["name"]) if part)


def map_graph(value, replacements):
    if isinstance(value, dict):
        return {k: map_graph(v, replacements) for k, v in value.items()}
    if isinstance(value, list):
        return [map_graph(v, replacements) for v in value]
    if isinstance(value, str):
        return re.sub(r"\{\{(PROMPT|IMAGE|SEED|SECONDS)\}\}", lambda m: str(replacements[m[0]]), value) if value not in replacements else replacements[value]
    return value


def check_preset(base, preset, lora=""):
    profile = comfy_workflows.get_profile(preset, RESOURCE)
    checks = profile.get("requiredComfyChecks") or {}
    for node_name in checks.get("requiredNodes", []):
        nodes = api(base, "/object_info/" + quote(node_name, safe=""))
        if node_name not in nodes:
            raise ValueError(f"此本機 ComfyUI 缺少 {profile['displayName']} 所需節點 {node_name}。請更新本機 ComfyUI。")
    required_clip_type = checks.get("clipLoaderType")
    if required_clip_type:
        clip_loader = api(base, "/object_info/CLIPLoader").get("CLIPLoader", {})
        encoder_types = clip_loader.get("input", {}).get("required", {}).get("type", [[]])[0]
        if required_clip_type not in encoder_types:
            raise ValueError(f"此本機 ComfyUI 版本不支援 {profile['displayName']}（缺少 CLIPLoader type={required_clip_type}）。")
    models = comfy_workflows.required_models_for_preset(preset, lora, RESOURCE)
    missing = []
    for category, filenames in models.items():
        available = api(base, "/models/" + category)
        missing.extend(f"{category}/{name}" for name in filenames if name not in available)
    if missing:
        raise ValueError("此本機 ComfyUI 工作流缺少模型：\n" + "\n".join(missing))


def workflow_graph(workflow):
    graph = workflow.get("prompt", workflow) if isinstance(workflow, dict) else None
    if not graph or not isinstance(graph, dict) or not all(
        isinstance(node, dict) and "class_type" in node for node in graph.values()
    ):
        raise ValueError("請從本機 ComfyUI 匯出 API 格式 JSON。畫布的普通 JSON 不能直接提交。")
    if "{{PROMPT}}" not in json.dumps(graph, ensure_ascii=False):
        raise ValueError("請把工作流正向提示詞節點的文字設成 {{PROMPT}}，讓表單能套用提示詞與風格。")
    return graph


def custom_graph(request, base):
    path = request.get("workflow")
    if not path or not Path(path).is_file():
        raise ValueError("請選擇本機 ComfyUI API 工作流 JSON。")
    graph = workflow_graph(json.loads(Path(path).read_text(encoding="utf-8")))
    if not request.get("localOnly") and request["action"] != "check_local":
        return graph
    for kind in sorted({node["class_type"] for node in graph.values()}):
        info = api(base, "/object_info/" + quote(kind, safe="")).get(kind)
        if info is None:
            raise ValueError(f"本機 ComfyUI 無法辨識節點 {kind}，請檢查本機節點是否已安裝。")
        if request.get("localOnly") and info.get("api_node"):
            raise ValueError(f"僅本機模式無法使用線上 API 節點 {kind}。")
    return graph


def comfy(request, folder):
    preset = request["action"]
    if preset in removed_model_ids():
        comfy_workflows.get_profile(preset, RESOURCE)  # Raises explicit removed-model error.
    base = local_base(request["endpoint"])
    api(base, "/system_stats")
    if request.get("videoMethod") in {"frames", "multi"}:
        raise ValueError("本機 ComfyUI 工作流目前不支援首尾影格或多影格模式，請改選首幀／文字或切換線上 Colab。")

    ref = (request.get("reference") or "").strip() if isinstance(request.get("reference"), str) else ""
    ref_video = (request.get("referenceVideo") or "").strip() if isinstance(request.get("referenceVideo"), str) else ""
    builtin = preset in preset_ids()

    if builtin:
        comfy_workflows.validate_preset_request(preset, request, RESOURCE)
        lora = (request.get("lora") or "").strip() if isinstance(request.get("lora"), str) else ""
        check_preset(base, preset, lora)
        if preset in {"wan22", "wan22_14b", "ltxv13b"} and ref_video:
            source = Path(ref_video)
            if source.suffix.lower() not in VIDEO_EXT or not source.is_file():
                raise ValueError("找不到可讀取的參考影片。")
            frame = folder / "reference-first-frame.png"
            run([tool("ffmpeg"), "-nostdin", "-v", "error", "-i", source,
                 "-map", "0:v:0", "-frames:v", "1", "-update", "1", frame])
            if not frame.is_file():
                raise ValueError("無法從參考影片取出首幀。")
            ref = str(frame)
            log("本機 ComfyUI · Wan 2.2 使用參考影片的首幀")
        uploaded = upload(base, Path(ref)) if ref else None
        effective_request = dict(request)
        if ref:
            effective_request["reference"] = ref
            effective_request["referenceVideo"] = ""
        graph, meta = comfy_workflows.resolve_builtin_graph(
            preset,
            effective_request,
            RESOURCE,
            uploaded_image=uploaded,
            native_size_fn=native_size,
        )
    else:
        raw_graph = custom_graph(request, base)
        serialized = json.dumps(raw_graph, ensure_ascii=False)
        replacements = {
            "{{PROMPT}}": request["prompt"],
            "{{SEED}}": request["seed"],
            "{{SECONDS}}": request.get("seconds", 5),
        }
        if "{{IMAGE}}" in serialized:
            if not ref:
                raise ValueError("此工作流需要一張參考圖。")
            replacements["{{IMAGE}}"] = upload(base, Path(ref))
        elif ref:
            raise ValueError("工作流要接收參考圖時，請把 LoadImage 節點的檔名設成 {{IMAGE}}。")
        graph = map_graph(raw_graph, replacements)
        meta = {
            "preset": "comfy",
            "displayName": "自訂 ComfyUI 工作流",
            "seed": request["seed"],
            "rawPrompt": request.get("rawPrompt") or request["prompt"],
            "submittedPrompt": request["prompt"],
        }

    obj_info = fetch_object_info(base, graph)
    bundle = comfy_workflows.write_workflow_bundle(
        graph,
        folder,
        "resolved",
        object_info=obj_info,
        extra_meta=meta,
    )
    if request.get("localOnly"):
        log(f"僅本機 ComfyUI · {base} · {preset}")
    else:
        log(f"本機 ComfyUI · {base} · {preset}")

    client_id = str(uuid4())
    monitor = _ComfyProgressMonitor(base, client_id, graph)
    monitor.start()
    try:
        payload = {
            "prompt": graph,
            "client_id": client_id,
            "extra_data": {
                "extra_pnginfo": {
                    "workflow": bundle["canvasWorkflow"],
                }
            },
        }
        pid = api(base, "/prompt", payload)["prompt_id"]
        monitor.set_prompt_id(pid)
        log(f"本機 ComfyUI 已排入工作 {pid}")
        emit_progress(pct=0.01, stage="已排入佇列")

        default_kind = ("video" if preset in {"wan22", "wan22_14b", "ltxv13b"} else "image") if builtin else None
        kind = request.get("kind", default_kind)
        is_video = (kind == "video") or (preset in {"wan22", "wan22_14b", "ltxv13b"})
        base_timeout = 7200 if is_video else 1800
        hard_cap = 14400 if is_video else 3600
        req_timeout = request.get("timeoutSeconds")
        if isinstance(req_timeout, (int, float)) and req_timeout >= 60:
            base_timeout = int(req_timeout)
            hard_cap = max(hard_cap, base_timeout)

        started_at = time.monotonic()
        deadline = started_at + base_timeout
        while True:
            now = time.monotonic()
            if now >= deadline:
                if monitor.seconds_since_activity() < 300 and (now - started_at) < hard_cap:
                    deadline = min(started_at + hard_cap, now + 600)
                else:
                    break
            job = api(base, "/history/" + pid).get(pid)
            if job is not None:
                status = job.get("status", {})
                if status.get("status_str") == "error":
                    messages = [payload.get("exception_message", "") for kind, payload in status.get("messages", [])
                                if kind == "execution_error" and isinstance(payload, dict)]
                    raise ValueError("本機 ComfyUI 執行失敗。" + " ".join(messages))
                if status.get("completed") is False:
                    time.sleep(2)
                    continue
                emit_progress(pct=0.99, stage="下載成品中")
                paths = []
                seen = set()
                for output in job.get("outputs", {}).values():
                    for group in output.values():
                        for item in group if isinstance(group, list) else ():
                            if not isinstance(item, dict) or "filename" not in item:
                                continue
                            name = Path(item["filename"]).name
                            if Path(name).suffix.lower() not in MEDIA_EXT or item.get("type", "output") != "output":
                                continue
                            query = urlencode({"filename": name, "subfolder": item.get("subfolder", ""), "type": "output"})
                            if query in seen:
                                continue
                            seen.add(query)
                            path = folder / f"{len(paths)+1:02d}-{name}"
                            path.write_bytes(api(base, "/view?" + query, raw=True))
                            paths.append(str(path))
                expected = {"image": IMAGE_EXT, "video": VIDEO_EXT}.get(kind)
                if expected:
                    paths = [path for path in paths if Path(path).suffix.lower() in expected]
                if paths:
                    emit_progress(pct=1.0, stage="已完成")
                    return paths, {
                        "apiWorkflowPath": bundle["apiPath"],
                        "canvasWorkflowPath": bundle["workflowPath"],
                        "workflowMeta": meta,
                        "promptId": pid,
                    }
                raise ValueError("工作流跑完但沒有可匯入的成品。請接 SaveImage、SaveVideo 或對應的輸出節點。")
            time.sleep(2)
        try:
            api(base, "/interrupt", {}, timeout=5)
        except Exception:
            pass
        elapsed_min = max(1, int(round((time.monotonic() - started_at) / 60)))
        raise TimeoutError(f"等待本機 ComfyUI 成品超過 {elapsed_min} 分鐘，已嘗試送出中斷並請於 ComfyUI 查看工作佇列。")
    finally:
        monitor.close()


def export_workflow_action(request, folder):
    preset = request.get("preset") or ""
    if preset in removed_model_ids():
        comfy_workflows.get_profile(preset, RESOURCE)
    dest_dir = Path(request.get("destinationDir") or str(folder))
    base_name = (request.get("baseName") or f"MotionDesk-{preset or 'comfy'}").strip()
    base_name = re.sub(r"[^A-Za-z0-9._-]+", "_", base_name) or "MotionDesk-workflow"

    obj_info = None
    endpoint = request.get("endpoint")
    if preset in preset_ids():
        api_graph, meta = comfy_workflows.resolve_builtin_graph(
            preset,
            request,
            RESOURCE,
            uploaded_image=None,
            native_size_fn=native_size,
        )
        if endpoint:
            try:
                base = local_base(endpoint)
                obj_info = fetch_object_info(base, api_graph)
            except Exception:
                obj_info = None
        bundle = comfy_workflows.write_workflow_bundle(
            api_graph,
            dest_dir,
            base_name,
            object_info=obj_info,
            extra_meta=meta,
        )
        log(f"已匯出本機 ComfyUI 同源工作流：{bundle['workflowPath']} 與 {bundle['apiPath']}")
        return [bundle["workflowPath"], bundle["apiPath"]], {
            "apiWorkflowPath": bundle["apiPath"],
            "canvasWorkflowPath": bundle["workflowPath"],
            "workflowMeta": meta,
        }
    elif preset == "comfy":
        path = request.get("workflow")
        if not path or not Path(path).is_file():
            raise ValueError("請先選擇本機 ComfyUI API 工作流 JSON。")
        raw_graph = workflow_graph(json.loads(Path(path).read_text(encoding="utf-8")))
        ref = (request.get("reference") or "").strip()
        replacements = {
            "{{PROMPT}}": request.get("prompt", ""),
            "{{SEED}}": request.get("seed", 1),
            "{{SECONDS}}": request.get("seconds", 5),
        }
        if "{{IMAGE}}" in json.dumps(raw_graph, ensure_ascii=False):
            replacements["{{IMAGE}}"] = Path(ref).name if ref else "reference.png"
        resolved = map_graph(raw_graph, replacements)
        if endpoint:
            try:
                obj_info = fetch_object_info(local_base(endpoint), resolved)
            except Exception:
                obj_info = None
        meta = {"preset": "comfy", "seed": request.get("seed", 1)}
        bundle = comfy_workflows.write_workflow_bundle(
            resolved, dest_dir, base_name, object_info=obj_info, extra_meta=meta
        )
        log(f"已匯出工作流：{bundle['workflowPath']} 與 {bundle['apiPath']}")
        return [bundle["workflowPath"], bundle["apiPath"]], {
            "apiWorkflowPath": bundle["apiPath"],
            "canvasWorkflowPath": bundle["workflowPath"],
            "workflowMeta": meta,
        }
    raise ValueError(f"不支援匯出未知模型的工作流：{preset}")


def cloud(request, folder):
    if request.get("localOnly"):
        raise ValueError("僅本機已啟用，工作未送往 Colab。")
    gpu = request.get("gpu", "L4")
    if gpu not in {"L4", "G4"}:
        raise ValueError("GPU 選項須為 L4 或 G4。")
    tool("colab")
    kind = request["kind"]
    method = request.get("videoMethod")
    if kind == "video" and method in {"frames", "multi"}:
        return cloud_keyframes(request, folder, gpu, method)
    images = request.get("referenceImages")
    if images is None:
        legacy_image = request.get("reference")
        images = [legacy_image] if legacy_image else []
    if not isinstance(images, list) or any(not isinstance(path, str) or not path for path in images):
        raise ValueError("參考圖片須為有效的檔案路徑清單。")
    if len(images) > MAX_CLOUD_REFERENCE_IMAGES:
        raise ValueError(f"Colab 最多接受 {MAX_CLOUD_REFERENCE_IMAGES} 張參考圖。")
    ref_video = request.get("referenceVideo")
    if ref_video is not None and not isinstance(ref_video, str):
        raise ValueError("Colab 一次只接受一支參考影片。")
    if ref_video and kind != "video":
        raise ValueError("Colab 生圖可使用參考圖片。參考影片請選擇影片輸出。")
    prompt = request["prompt"]
    files = [(value, IMAGE_EXT, f"reference-image-{index:02d}") for index, value in enumerate(images, 1)]
    if ref_video:
        files.append((ref_video, VIDEO_EXT, "reference-video-01"))
    if kind == "video" and files and not MENTION_RE.search(prompt):
        tags = [f"@圖片{index}" for index in range(1, len(images) + 1)]
        if ref_video:
            tags.append("@影片1")
        prompt += "\n\n參考素材：" + "、".join(tags) + "。"
    job = {"id": "generated", "type": kind, "prompt": prompt,
           "seed": request["seed"], "aspect": request["aspect"]}
    inputs = []
    for value, extensions, stem in files:
        source = Path(value)
        if source.suffix.lower() not in extensions or not source.is_file():
            raise ValueError(f"找不到可使用的參考素材：{source.name}")
        path = stem + source.suffix.lower()
        shutil.copy2(source, folder / path)
        inputs.append(path)
    if inputs:
        job["inputs"] = inputs
    if kind == "video":
        job.update(seconds=request["seconds"], resolution=request["resolution"],
                   video_model=request["model"], mode="ref" if inputs else "text", intensity="off")
    else:
        job["size"] = "1.6K"
    run_cloud_jobs([job], request, folder, gpu)
    paths = [str(x) for x in sorted((folder / "out").glob("generated.*")) if x.suffix.lower() in MEDIA_EXT]
    if not paths:
        raise ValueError("Colab 沒有回傳成品，請查看工作紀錄。")
    return paths


def run_cloud_jobs(jobs, request, folder, gpu):
    manifest = folder / "manifest.json"
    manifest.write_text(json.dumps({"jobs": jobs}, ensure_ascii=False), encoding="utf-8")
    cmd = [sys.executable, "-u", H3 / "h3run.py", "run", manifest,
           "--gpu", gpu, "--stop-after", "--max-minutes", "55" if request.get("resolution") == "1080P" else "35"]
    if request["kind"] == "image":
        cmd.append("--with-pictures")
    if len(jobs) > 1:
        seconds = sum(job["seconds"] for job in jobs)
        pace = 32 if request.get("resolution") == "480P" else 72
        minutes = max(75, math.ceil(seconds * pace / 60) + 25)
        cmd.extend(["--confirmed", "--max-minutes", str(minutes)])
    run(cmd)


def cloud_keyframes(request, folder, gpu, method):
    frames = request.get("keyframes", [])
    if method == "frames" and len(frames) != 2:
        raise ValueError("請加入首幀和尾幀圖片。")
    if method == "multi" and not 3 <= len(frames) <= MAX_CLOUD_KEYFRAMES:
        raise ValueError(f"多影格需要 3–{MAX_CLOUD_KEYFRAMES} 張圖片。")
    seconds = int(request["seconds"])
    count = len(frames) - 1
    segments = request.get("segments") if method == "multi" else None
    if segments is None:
        if not 2 * count <= seconds <= 15 * count:
            raise ValueError(f"請設定 {2 * count}–{15 * count} 秒，讓每段為 2–15 秒。")
        duration, extra = divmod(seconds, count)
        segments = [{"seconds": duration + (index < extra), "prompt": ""} for index in range(count)]
    elif not isinstance(segments, list) or len(segments) != count:
        raise ValueError("請為每兩張相鄰影格設定一段。")
    for index, segment in enumerate(segments, 1):
        if (not isinstance(segment, dict) or type(segment.get("seconds")) is not int
                or not 2 <= segment["seconds"] <= 15 or not isinstance(segment.get("prompt"), str)):
            raise ValueError(f"第 {index} 段需要 2–15 秒的整數與文字提示詞（可留空）。")

    inputs = []
    for index, value in enumerate(frames, 1):
        source = Path(value)
        if source.suffix.lower() not in IMAGE_EXT or not source.is_file():
            raise ValueError(f"第 {index} 張影格找不到或格式不支援。")
        name = f"keyframe-{index:02d}{source.suffix.lower()}"
        shutil.copy2(source, folder / name)
        inputs.append(name)

    jobs = []
    for index, (first, last) in enumerate(zip(inputs, inputs[1:])):
        segment = segments[index]
        duration = segment["seconds"]
        prompt = request["prompt"]
        if method == "multi" and request.get("segments") is not None:
            prompt += f"\n\nThis transition lasts {duration} seconds."
            if detail := segment["prompt"].strip():
                prompt += "\nTransition-specific direction: " + detail
        job = {"id": "generated" if count == 1 else f"shot-{index + 1:02d}", "type": "video",
               "mode": "frames", "first": first, "last": last, "prompt": prompt,
               "seconds": duration, "aspect": request["aspect"],
               "resolution": request["resolution"], "video_model": request["model"],
               "seed": (request["seed"] + index) % (2**32), "intensity": "off"}
        jobs.append(job)

    run_cloud_jobs(jobs, request, folder, gpu)
    clips = []
    size = None
    for job in jobs:
        path = folder / "out" / (job["id"] + ".mp4")
        if not path.is_file():
            raise ValueError(f"Colab 未回傳影格片段 {job['id']}。")
        if count == 1:
            return [str(path)]
        info = probe(path)
        stream = next((item for item in info["streams"] if item["codec_type"] == "video"), None)
        if stream is None:
            raise ValueError(f"片段 {job['id']} 缺少影像軌。")
        if size is None:
            size = (stream["width"], stream["height"])
        available = float(info["format"]["duration"])
        clips.append({"path": str(path), "end": min(available, job["seconds"])})
    log("多影格 · 依順序接合影片片段")
    target = pixel_size(request)
    return export({"destination": str(folder / "out" / "generated.mp4"),
                   "clips": clips, "aspect": request["aspect"]}, folder,
                  size=target or size, crop_to_fill=target is not None)


def probe(path):
    result = run([tool("ffprobe"), "-v", "error", "-show_streams", "-show_format",
                  "-of", "json", path], capture_output=True)
    return json.loads(result.stdout)


def resize_outputs(paths, size, folder, kind):
    width, height = size
    resized = []
    for index, path in enumerate(paths, 1):
        streams = probe(path)["streams"]
        video = next(stream for stream in streams if stream["codec_type"] == "video")
        square_pixels = video.get("sample_aspect_ratio") in (None, "N/A", "0:1", "1:1")
        if square_pixels and (video["width"], video["height"]) == size:
            resized.append(path)
            continue
        output = folder / f"{index:02d}-{width}x{height}{'.mp4' if kind == 'video' else '.png'}"
        areas = f"scale={width}:{height}:force_original_aspect_ratio=increase:flags=lanczos"
        filters = f"{areas},format={'yuv444p' if kind == 'video' else 'rgba'},crop={width}:{height}:exact=1,setsar=1"
        args = [tool("ffmpeg"), "-nostdin", "-v", "error", "-y", "-filter_threads", "2", "-i", path,
                "-map", "0:v:0", "-vf", filters]
        if kind == "video":
            args += ["-map", "0:a:0?", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                     "-preset", "veryfast", "-crf", "18", "-threads", "3", "-c:a", "aac", "-movflags", "+faststart"]
        else:
            args += ["-frames:v", "1", "-update", "1"]
        log(f"轉換輸出尺寸 · {width} × {height}")
        run([*args, output])
        resized.append(str(output))
    return resized


def save_outputs(paths, destination, identifier, kind):
    location = Path(destination)
    if not location.is_absolute() or not location.is_dir():
        raise ValueError("找不到選取的儲存資料夾。")
    published = []
    try:
        for index, source in enumerate(map(Path, paths), 1):
            label = "Video" if kind == "video" else "Image"
            final = location / f"MotionDesk-{label}-{index:02d}-{identifier}{source.suffix.lower()}"
            with final.open("xb"):
                pass
            published.append(final)
            with tempfile.NamedTemporaryFile(dir=location, prefix=".motiondesk-", delete=False) as temporary:
                pending = Path(temporary.name)
            try:
                with pending.open("wb") as temporary, source.open("rb") as incoming:
                    shutil.copyfileobj(incoming, temporary)
                pending.replace(final)
            finally:
                pending.unlink(missing_ok=True)
        return [str(path) for path in published]
    except Exception:
        for path in published:
            path.unlink(missing_ok=True)
        raise


def timeline_transitions(request, clip_count, fps):
    specs = request.get("transitions")
    if specs is None:
        return []
    if not isinstance(specs, list) or len(specs) != max(0, clip_count - 1):
        raise ValueError("轉場設定數量與時間軸的片段交界不符。")
    effects = []
    for index, spec in enumerate(specs, 1):
        if spec is None:
            effects.append(None)
            continue
        kind = spec.get("kind") if isinstance(spec, dict) else None
        if not isinstance(kind, str) or kind not in TIMELINE_EFFECTS:
            raise ValueError(f"第 {index} 個交界的轉場效果不支援。")
        seconds = spec.get("seconds")
        if type(seconds) not in {int, float} or not 0.1 <= seconds <= 3.0:
            raise ValueError(f"第 {index} 個交界的轉場需為 0.1–3 秒。")
        effects.append((TIMELINE_EFFECTS[kind], round(seconds * fps)))
    return effects


def compose_timeline(ffmpeg, segments, frame_counts, effects, fps, destination):
    args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-filter_complex_threads", "2"]
    filters = []
    for index, (segment, frames) in enumerate(zip(segments, frame_counts)):
        args += ["-threads", "2", "-i", segment]
        samples = frames * 48000 // fps
        filters.extend([
            f"[{index}:v]format=yuv444p,tpad=stop_mode=clone:stop_duration={frames / fps:.9f},"
            f"trim=end_frame={frames},settb=1/{fps},setpts=N[v{index}]",
            f"[{index}:a]apad=whole_len={samples},atrim=end_sample={samples},asetpts=N/SR/TB[a{index}]",
        ])
    runs = []
    video, audio = "[v0]", "[a0]"
    length = frame_counts[0]
    for index, effect in enumerate(effects, 1):
        if effect is None:
            runs.append(video + audio)
            video, audio = f"[v{index}]", f"[a{index}]"
            length = frame_counts[index]
            continue
        kind, duration = effect
        output_video, output_audio = f"[blendv{index}]", f"[blenda{index}]"
        filters.extend([
            f"{video}[v{index}]xfade=transition={kind}:duration={duration / fps:.9f}:"
            f"offset={(length - duration) / fps:.9f}{output_video}",
            f"{audio}[a{index}]acrossfade=nb_samples={duration * 48000 // fps}{output_audio}",
        ])
        video, audio = output_video, output_audio
        length += frame_counts[index] - duration
    if runs:
        runs.append(video + audio)
        video, audio = "[vout]", "[aout]"
        filters.append("".join(runs) + f"concat=n={len(runs)}:v=1:a=1{video}{audio}")
    log("合成轉場並混合交界音訊")
    try:
        run([*args, "-filter_complex", ";".join(filters), "-map", video, "-map", audio,
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "veryfast", "-crf", "19",
             "-threads", "3", "-c:a", "aac", "-ar", "48000", "-ac", "2", "-movflags", "+faststart",
             destination])
    except subprocess.CalledProcessError as exc:
        raise ValueError("無法合成轉場，請查看工作紀錄。") from exc


def export(request, folder, *, size=None, crop_to_fill=False):
    if isinstance(request.get("timeline"), dict):
        return timeline_render.export_multitrack(
            request,
            folder,
            ffmpeg=tool("ffmpeg"),
            ffprobe=tool("ffprobe"),
            textrender_bin=textrender_binary(),
            size=size,
            log_fn=log,
        )
    destination = Path(request["destination"])
    if destination.suffix.lower() != ".mp4":
        raise ValueError("匯出檔名需使用 .mp4。")
    width, height = size or pixel_size(request) or {"16:9": (1920, 1080), "9:16": (1080, 1920), "1:1": (1080, 1080)}[request["aspect"]]
    ffmpeg = tool("ffmpeg")
    if crop_to_fill:
        framing = (f"scale={width}:{height}:force_original_aspect_ratio=increase:flags=lanczos,"
                   f"format=yuv444p,crop={width}:{height}:exact=1")
    else:
        framing = (f"scale={width}:{height}:force_original_aspect_ratio=decrease:force_divisible_by=2,"
                   f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2")
    fps = 24
    clips = request["clips"]
    if not clips:
        raise ValueError("請先把素材加入時間軸。")
    effects = timeline_transitions(request, len(clips), fps)
    needs_transitions = any(effects)
    prepared = []
    for i, item in enumerate(clips, 1):
        path = Path(item["path"])
        info = probe(path)
        streams = info.get("streams", [])
        if not any(stream["codec_type"] == "video" for stream in streams):
            raise ValueError(f"時間軸目前支援影片和圖片。{path.name} 沒有影像軌。")
        is_image = path.suffix.lower() in IMAGE_EXT
        duration = float(info.get("format", {}).get("duration", 0) or 0)
        start = 0 if is_image else float(item.get("start") or 0)
        end = float(item.get("end") or (3 if is_image else duration))
        length = end - start
        if not all(map(math.isfinite, (start, end, length))) or start < 0 or length < 1/fps or (not is_image and end > duration + 0.10):
            raise ValueError(f"第 {i} 段時間無效。{path.name} 長度 {duration:.2f} 秒。")
        has_audio = any(stream["codec_type"] == "audio" for stream in streams)
        prepared.append((path, is_image, has_audio, start, length))
    frame_counts = [round(length * fps) for _, _, _, _, length in prepared] if needs_transitions else []
    if needs_transitions:
        overlaps = [0] + [effect[1] if effect else 0 for effect in effects] + [0]
        for index, frames in enumerate(frame_counts):
            incoming, outgoing = overlaps[index:index + 2]
            if max(incoming, outgoing) >= frames or incoming + outgoing > frames:
                raise ValueError(f"第 {index + 1} 段片長不足，請縮短相鄰的轉場。")

    segments = []
    for i, (path, is_image, has_audio, start, length) in enumerate(prepared, 1):
        if needs_transitions:
            length = frame_counts[i - 1] / fps
        segment = folder / f"segment-{i:03d}.mp4"
        args = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-threads", "2"]
        args += ["-loop", "1", "-framerate", str(fps)] if is_image else ["-ss", str(start)]
        args += ["-i", path]
        if not has_audio:
            args += ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
        args += ["-map", "0:v:0", "-map", "0:a:0" if has_audio else "1:a:0",
                 "-vf", f"{framing},setsar=1,fps={fps},format=yuv420p",
                 "-af", "apad", "-t", str(length), "-c:v", "libx264", "-preset", "veryfast",
                 "-crf", "19", "-threads", "3", "-c:a", "aac", "-ar", "48000", "-ac", "2", segment]
        log(f"處理片段 {i}/{len(clips)} · {path.name}")
        run(args)
        segments.append(segment)
    tmp = destination.with_name(f".{destination.stem}-{uuid4().hex}.mp4")
    try:
        if needs_transitions:
            compose_timeline(ffmpeg, segments, frame_counts, effects, fps, tmp)
        else:
            listing = folder / "segments.txt"
            listing.write_text("".join(f"file '{p.name}'\n" for p in segments), encoding="utf-8")
            run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "concat",
                 "-safe", "1", "-i", listing, "-c", "copy", "-movflags", "+faststart", tmp])
        tmp.replace(destination)
    finally:
        tmp.unlink(missing_ok=True)
    return [str(destination)]


def hyperframes(request, folder):
    engine = RESOURCE / "runtime/hyperframes"
    if request["action"] == "title":
        project = folder / "title-project"
        project.mkdir()
        title = html.escape(request["title"].strip())
        if not title:
            raise ValueError("請輸入片頭標題。")
        width, height = {"16:9": (1920, 1080), "9:16": (1080, 1920), "1:1": (1080, 1080)}[request["aspect"]]
        gsap = engine / "node_modules/hyperframes/dist/vendor/npm/gsap@3.15.0/dist/gsap.min.js"
        shutil.copyfile(gsap, project / "gsap.min.js")
        markup = f"""<!doctype html>
<html lang="zh-Hant"><head><meta charset="utf-8"><title>{title}</title>
<style>
*{{box-sizing:border-box}} html,body{{margin:0;background:#101821;overflow:hidden}}
#stage{{position:relative;width:{width}px;height:{height}px;display:grid;place-items:center;color:#edf3f0;
font-family: sans-serif;background:#101821}}
.heading{{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:10%;
text-align:center;font-size:{round(min(width,height)*0.075)}px;line-height:1.24;word-break:break-word}}
.rule{{width:3.4em;height:3px;background:#8ae3c2;margin:0.65em auto 0}}
</style><script src="./gsap.min.js"></script></head>
<body><main id="stage" data-composition-id="title" data-width="{width}" data-height="{height}" data-duration="2">
<div id="title-text" class="heading clip" data-start="0" data-duration="2" data-track-index="0"><span>{title}</span><span class="rule"></span></div>
</main><script>
window.__timelines = window.__timelines || {{}};
window.__timelines.title = gsap.timeline({{paused:true}})
.fromTo(".heading", {{opacity:0,y:20}}, {{opacity:1,y:0,duration:0.42,ease:"power2.out"}},0)
.to(".heading", {{opacity:0,duration:0.28,ease:"power1.in"}},1.72);
</script></body></html>"""
        (project / "index.html").write_text(markup, encoding="utf-8")
    else:
        project = Path(request["workflow"])
    if not (project / "index.html").is_file():
        raise ValueError("請選含 index.html 的 HyperFrames 專案資料夾。")
    node = tool("node")
    version = run([node, "-p", "process.versions.node"], capture_output=True, text=True).stdout.strip()
    if int(version.split(".")[0]) < 22:
        raise ValueError("HyperFrames 需要 Node.js 22 或更新版本。")
    cli = engine / "node_modules/.bin/hyperframes"
    if not cli.is_file():
        raise ValueError("外掛包中找不到 HyperFrames CLI。")
    tool("ffmpeg")
    output = folder / ("title.mp4" if request["action"] == "title" else "hyperframes.mp4")
    jobs = folder.parent
    if jobs.parent.name == "Jobs" and re.fullmatch(r"\d{4}-\d{2}-\d{2}", jobs.name):
        jobs = jobs.parent
    config = jobs.parent / "HyperFrames"
    config.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, HYPERFRAMES_NO_TELEMETRY="1", HYPERFRAMES_NO_UPDATE_CHECK="1",
               HYPERFRAMES_CONFIG_DIR=str(config), HYPERFRAMES_CACHE_DIR=str(config / "cache"))
    chrome = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    if chrome.is_file():
        env["HYPERFRAMES_BROWSER_PATH"] = str(chrome)
    run([cli, "render", "--workers", "1", "--fps", "24", "--experimental-fast-capture=false",
         "--output", output], cwd=project, env=env, timeout=1200)
    if not output.is_file() or output.stat().st_size == 0:
        raise ValueError("HyperFrames 未輸出影片。")
    return [str(output)]


DEFAULT_QWEN_VL_MODEL = "Qwen3-VL-8B-Instruct-abliterated-v2.0.Q4_K_M.gguf"
DEFAULT_QWEN_VL_MMPROJ = "Qwen3-VL-8B-Instruct-abliterated-v2.0.mmproj-f16.gguf"
DEFAULT_QWEN_VL_PREFIX = "Qwen3-VL-8B-Instruct-abliterated-v2.0."
DEFAULT_QWEN_VL_SYSTEM_PROMPT = (
    "你是專業的影視與視覺提示詞設計師。請根據輸入圖片，直接以流暢、具體的繁體中文描述畫面中的主體外觀、"
    "服裝細節、動作姿態、場景環境、光線色彩、構圖與鏡頭視角，寫成適合直接作為圖片或影片生成的提示詞段落。"
    "請直接輸出提示詞本身，不要加入前綴說明或思考過程。"
)
DEFAULT_QWEN_VL_USER_PROMPT = "請詳細描述這張圖片的畫面細節、主體、動作、環境、光影與構圖，產生可直接用於生成圖片或影片的繁體中文提示詞。"


def _model_family_prefix(filename):
    name = Path(filename).name
    m = re.match(r"^(.*?)(?:\.(?:mmproj-[^.]+|IQ\d+_[A-Z0-9_]+|Q\d+_[A-Z0-9_]+|f16|bf16|fp16))\.gguf$", name, re.IGNORECASE)
    if m and m.group(1):
        return m.group(1) + "."
    if ".mmproj" in name.lower():
        idx = name.lower().find(".mmproj")
        return name[:idx + 1]
    parts = name.split(".")
    if len(parts) >= 3:
        return ".".join(parts[:-2]) + "."
    return DEFAULT_QWEN_VL_PREFIX


def resolve_paired_qwen_vl_files(available_llms, requested_model="", requested_mmproj=""):
    if not isinstance(available_llms, list):
        available_llms = []
    model_name = (requested_model or "").strip() or DEFAULT_QWEN_VL_MODEL
    mmproj_name = (requested_mmproj or "").strip() or DEFAULT_QWEN_VL_MMPROJ

    if model_name not in available_llms:
        raise ValueError(f"本機 ComfyUI 的 models/LLM 目錄找不到指定模型：{model_name}")
    if mmproj_name not in available_llms:
        raise ValueError(f"本機 ComfyUI 的 models/LLM 目錄找不到指定視覺投影器：{mmproj_name}")

    m_prefix = _model_family_prefix(model_name)
    p_prefix = _model_family_prefix(mmproj_name)
    if m_prefix.lower() != p_prefix.lower():
        raise ValueError(
            f"模型與視覺投影器不配對（{model_name} vs {mmproj_name}），拒絕混搭推論。"
        )
    return model_name, mmproj_name


def parse_interrogate_seed(raw_seed):
    if raw_seed is None:
        return 42
    if isinstance(raw_seed, bool):
        return 42
    if isinstance(raw_seed, int):
        if not 0 <= raw_seed <= 0xFFFFFFFFFFFFFFFF:
            raise ValueError("Seed 請填 0–4294967295 的非負整數。")
        return raw_seed
    text = str(raw_seed).strip()
    if not text:
        return 42
    try:
        val = int(text, 10)
    except ValueError as exc:
        raise ValueError("Seed 請填 0–4294967295 的整數，或留空使用預設值。") from exc
    if not 0 <= val <= 0xFFFFFFFFFFFFFFFF:
        raise ValueError("Seed 請填 0–4294967295 的非負整數。")
    return val


def interrogate_image(request, folder):
    base = local_base(request["endpoint"])
    api(base, "/system_stats")

    ref = (request.get("reference") or "").strip() if isinstance(request.get("reference"), str) else ""
    ref_video = (request.get("referenceVideo") or "").strip() if isinstance(request.get("referenceVideo"), str) else ""
    if not ref and ref_video:
        source_video = Path(ref_video)
        if source_video.suffix.lower() not in VIDEO_EXT or not source_video.is_file():
            raise ValueError("找不到可讀取的參考影片。")
        frame = folder / "vlm-reference-frame.png"
        run([tool("ffmpeg"), "-nostdin", "-v", "error", "-i", source_video,
             "-map", "0:v:0", "-frames:v", "1", "-update", "1", frame])
        if not frame.is_file():
            raise ValueError("無法從參考影片取出首幀。")
        ref = str(frame)
        log("看圖產生提示詞 · 已從參考影片擷取首幀")

    if not ref:
        raise ValueError("請先選擇一張參考圖片（或首幀圖片／影片）再執行看圖產生提示詞。")
    ref_path = Path(ref)
    if ref_path.suffix.lower() not in IMAGE_EXT or not ref_path.is_file():
        raise ValueError(f"找不到參考圖片或格式不支援：{ref_path.name}")

    required_nodes = ["llama_cpp_model_loader", "llama_cpp_instruct_adv", "llama_cpp_parameters", "PreviewAny"]
    for node_name in required_nodes:
        nodes = api(base, "/object_info/" + quote(node_name, safe=""))
        if node_name not in nodes:
            raise ValueError(
                f"本機 ComfyUI 缺少 VLM 節點 {node_name}（ComfyUI-llama-cpp_vlm）。"
                "請確認已安裝節點並重啟本機 ComfyUI。"
            )

    available_llms = api(base, "/models/LLM")
    model_name, mmproj_name = resolve_paired_qwen_vl_files(
        available_llms,
        requested_model=request.get("vlmModel") or "",
        requested_mmproj=request.get("vlmMmproj") or "",
    )

    uploaded_image = upload(base, ref_path)
    seed_val = parse_interrogate_seed(request.get("seed"))
    user_instruction = (request.get("instruction") or "").strip() or DEFAULT_QWEN_VL_USER_PROMPT
    system_prompt = (request.get("systemPrompt") or "").strip() or DEFAULT_QWEN_VL_SYSTEM_PROMPT

    graph = {
        "1": {
            "class_type": "LoadImage",
            "inputs": {
                "image": uploaded_image,
            },
        },
        "2": {
            "class_type": "llama_cpp_model_loader",
            "inputs": {
                "model": model_name,
                "mmproj": mmproj_name,
                "chat_handler": "Qwen3-VL",
                "n_ctx": 8192,
                "vram_limit": -1,
                "image_min_tokens": 0,
                "image_max_tokens": 0,
                "load_mtp": False,
            },
        },
        "3": {
            "class_type": "llama_cpp_parameters",
            "inputs": {
                "max_tokens": 512,
                "top_k": 30,
                "top_p": 0.9,
                "min_p": 0.05,
                "typical_p": 1.0,
                "temperature": 0.6,
                "repeat_penalty": 1.05,
                "frequency_penalty": 0.0,
                "present_penalty": 0.0,
                "mirostat_mode": 0,
                "mirostat_eta": 0.1,
                "mirostat_tau": 5.0,
                "state_uid": -1,
            },
        },
        "4": {
            "class_type": "llama_cpp_instruct_adv",
            "inputs": {
                "llama_model": ["2", 0],
                "preset_prompt": "Prompt Style - Detailed",
                "custom_prompt": user_instruction,
                "system_prompt": system_prompt,
                "inference_mode": "one by one",
                "max_frames": 24,
                "max_size": 1024,
                "seed": seed_val,
                "force_offload": True,
                "save_states": False,
                "parameters": ["3", 0],
                "images": ["1", 0],
            },
        },
        "5": {
            "class_type": "PreviewAny",
            "inputs": {
                "source": ["4", 0],
            },
        },
    }

    log(f"本機 ComfyUI · Qwen3-VL 看圖產生提示詞（{model_name} · seed={seed_val}）")
    payload = {
        "prompt": graph,
        "client_id": str(uuid4()),
    }
    pid = api(base, "/prompt", payload)["prompt_id"]
    log(f"本機 ComfyUI 已排入看圖任務 {pid}")
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        job = api(base, "/history/" + pid).get(pid)
        if job is not None:
            status = job.get("status", {})
            if status.get("status_str") == "error":
                messages = [
                    p.get("exception_message", "")
                    for kind, p in status.get("messages", [])
                    if kind == "execution_error" and isinstance(p, dict)
                ]
                raise ValueError("Qwen3-VL 看圖產生提示詞失敗：" + " ".join(messages))
            if status.get("completed") is False:
                time.sleep(1.0)
                continue
            outputs = job.get("outputs", {})
            generated_text = ""
            for node_id in ("5", "4"):
                node_out = outputs.get(node_id, {})
                if isinstance(node_out, dict):
                    text_list = node_out.get("text") or node_out.get("result") or node_out.get("string")
                    if isinstance(text_list, list) and text_list:
                        candidate = str(text_list[0]).strip()
                        if candidate:
                            generated_text = candidate
                            break
            if not generated_text:
                for node_out in outputs.values():
                    if isinstance(node_out, dict):
                        for v in node_out.values():
                            if isinstance(v, list) and v and isinstance(v[0], str) and v[0].strip():
                                generated_text = v[0].strip()
                                break
                    if generated_text:
                        break
            if not generated_text:
                raise ValueError("Qwen3-VL 已完成推論，但未回傳提示詞文字。")
            log("Qwen3-VL 看圖產生提示詞完成：\n" + generated_text)
            return [], {
                "interrogatedPrompt": generated_text,
                "interrogatedImage": str(ref_path),
                "vlmModel": model_name,
                "vlmMmproj": mmproj_name,
                "seed": seed_val,
                "promptId": pid,
            }
        time.sleep(1.0)
    raise ValueError("等候本機 ComfyUI Qwen3-VL 看圖逾時。")


def _validate_online_text_to_image_only(request, provider_label):
    if request.get("localOnly"):
        raise ValueError(f"已啟用僅限本機模式，禁止呼叫線上 {provider_label} API。")
    if request.get("kind") != "image":
        raise ValueError(f"{provider_label} 官方 API 僅支援圖片生成；雲端影片請改用 Google Colab。")
    if not request.get("billingAcknowledged"):
        raise ValueError(f"尚未勾選同意 {provider_label} 官方 API 計費說明，已中止呼叫。")
    ref = str(request.get("reference") or "").strip()
    ref_images = [str(p).strip() for p in (request.get("referenceImages") or []) if str(p).strip()]
    ref_video = str(request.get("referenceVideo") or "").strip()
    lora = str(request.get("lora") or "").strip()
    if ref or ref_images:
        raise ValueError(f"{provider_label} 官方 API 本版僅支援純文字生圖，不支援參考圖片；請先移除參考圖片。")
    if ref_video:
        raise ValueError(f"{provider_label} 官方 API 本版僅支援純文字生圖，不支援參考影片；請先移除參考影片。")
    if lora:
        raise ValueError(f"{provider_label} 官方 API 本版僅支援純文字生圖，不支援本機 LoRA；請先取消 LoRA。")


def run_openai_image(request, folder):
    _validate_online_text_to_image_only(request, "OpenAI")
    api_key = os.environ.get("MOTIONDESK_OPENAI_API_KEY", "").strip()
    if not api_key:
        raise ValueError("未提供 OpenAI API 金鑰（請於「元件與連線設定」的 macOS Keychain 設定）。")
    out_dir = folder / "out"
    res = online_image.generate_openai_image(
        prompt=request.get("prompt", ""),
        api_key=api_key,
        output_dir=out_dir,
        model=request.get("onlineModel") or online_image.OPENAI_DEFAULT_MODEL,
        aspect=request.get("aspect") or "1:1",
        quality=request.get("onlineQuality") or "low",
    )
    log(f"OpenAI 圖片 API 完成（model={res['model']}，size={res['size']}，quality={res['quality']}）。")
    return res["paths"]


def run_gemini_image(request, folder):
    _validate_online_text_to_image_only(request, "Gemini")
    api_key = os.environ.get("MOTIONDESK_GEMINI_API_KEY", "").strip()
    if not api_key:
        raise ValueError("未提供 Gemini API 金鑰（請於「元件與連線設定」的 macOS Keychain 設定）。")
    out_dir = folder / "out"
    res = online_image.generate_gemini_image(
        prompt=request.get("prompt", ""),
        api_key=api_key,
        output_dir=out_dir,
        model=request.get("onlineModel") or online_image.GEMINI_DEFAULT_MODEL,
        aspect=request.get("aspect") or "16:9",
        image_size=request.get("onlineImageSize") or "1K",
    )
    log(f"Gemini 圖片 API 完成（model={res['model']}，aspect={res['aspect_ratio']}，image_size={res['image_size']}）。")
    return res["paths"]


def run_mografy_motion(request, folder):
    workspace = Path((request.get("mografyWorkspace") or "").strip()).expanduser()
    if not workspace.is_dir():
        raise ValueError(f"找不到 Mografy 工作區目錄：{workspace}")
    agent = (request.get("agent") or "claude").strip().lower()
    agent_bin = (request.get("agentBinary") or "").strip()
    if not agent_bin or not Path(agent_bin).is_file():
        raise ValueError(f"找不到指定的 Agent 執行檔：{agent_bin or agent}")
    prompt = (request.get("prompt") or "").strip()
    if not prompt:
        raise ValueError("請輸入動態圖形製作需求。")
    aspect = request.get("aspect") or "16:9"
    seconds = max(3, min(30, int(request.get("seconds") or 8)))
    job_slug = f"klipora-{int(time.time())}"
    target_mp4 = folder / f"01-{job_slug}.mp4"

    emit_progress(pct=0.05, stage="準備 Mografy 工作區")
    log(f"Mografy 動態圖形 · 引擎={agent} · 比例={aspect} · {seconds} 秒")

    instruction = (
        f"Use the mografy skill in this workspace to create and render a {seconds}-second "
        f"{aspect} motion graphics MP4 video for the following request:\n\n"
        f"{prompt}\n\n"
        f"Requirements:\n"
        f"1. Create a new project under projects/{job_slug}.\n"
        f"2. Run mografy check to verify layout and frames have no clipping or errors.\n"
        f"3. Export the final rendered MP4 video to: {target_mp4}\n"
        f"4. Reply briefly once the MP4 file is written."
    )

    if agent == "claude":
        cmd = [agent_bin, "-p", instruction, "--dangerously-skip-permissions"]
    elif agent == "codex":
        cmd = [agent_bin, "exec", "--full-auto", instruction]
    else:
        cmd = [agent_bin, "-p", instruction]

    started_at = time.time()
    emit_progress(pct=0.18, stage=f"{agent} 製作動畫中")
    proc = subprocess.run(cmd, cwd=str(workspace), capture_output=True, text=True, timeout=1800)
    if proc.stdout:
        log(proc.stdout[-4000:])
    if proc.stderr:
        log(proc.stderr[-2000:])
    if proc.returncode != 0 and not target_mp4.is_file():
        raise ValueError(f"Agent（{agent}）執行失敗（代碼 {proc.returncode}），請查看工作紀錄。")

    emit_progress(pct=0.88, stage="檢查輸出 MP4")
    if not target_mp4.is_file() or target_mp4.stat().st_size == 0:
        # Fallback: locate the newest MP4 created inside the Mografy workspace during this run
        candidates = []
        for mp4 in workspace.rglob("*.mp4"):
            try:
                st = mp4.stat()
                if st.st_size > 0 and st.st_mtime >= started_at - 2:
                    candidates.append((st.st_mtime, mp4))
            except OSError:
                continue
        if candidates:
            candidates.sort(reverse=True)
            shutil.copy2(candidates[0][1], target_mp4)
    if not target_mp4.is_file() or target_mp4.stat().st_size == 0:
        raise ValueError("Mografy 未產生可匯入的 MP4 成品，請查看工作紀錄確認 Agent 執行細節。")

    emit_progress(pct=1.0, stage="已完成")
    return [str(target_mp4)]


def main():
    req_path, result_path = (Path(value).resolve() for value in sys.argv[1:])
    try:
        request = json.loads(req_path.read_text(encoding="utf-8"))
        folder = req_path.parent
        action = request["action"]
        active_presets = preset_ids()
        removed = removed_model_ids()
        generation = action in active_presets or action in {"comfy", "colab", "openai_image", "gemini_image"}
        extra_result = {}
        if action in removed:
            comfy_workflows.get_profile(action, RESOURCE)  # Raises explicit removed-model error.
        if action == "check_local":
            base = local_base(request["endpoint"])
            stats = api(base, "/system_stats")
            names = ", ".join(d.get("name", "") for d in stats.get("devices", []) if d.get("name"))
            log("本機 ComfyUI 已連線" + (" · " + names if names else ""))
            preset = request.get("preset")
            if preset in removed:
                comfy_workflows.get_profile(preset, RESOURCE)
            if preset in active_presets:
                comfy_workflows.validate_preset_request(preset, request, RESOURCE)
                check_preset(base, preset, request.get("lora", ""))
                profile = comfy_workflows.get_profile(preset, RESOURCE)
                d = profile["defaults"]
                log(f"所選本機 ComfyUI 模型「{profile['displayName']}」皆已就緒（預設 {d['steps']} steps · CFG {d['cfg']} · {d['sampler']}/{d['scheduler']}）。")
            elif preset == "comfy":
                custom_graph(request, base)
                log("所選本機 ComfyUI 自訂工作流的節點已就緒。")
            paths = []
        elif action == "export_workflow":
            paths, extra_result = export_workflow_action(request, folder)
        elif action == "interrogate_image":
            paths, extra_result = interrogate_image(request, folder)
        elif action == "check_colab":
            run([sys.executable, "-u", H3 / "h3run.py", "check"])
            paths = []
        else:
            size = pixel_size(request) if generation else None
            if size:
                tool("ffmpeg")
                tool("ffprobe")
                ratio = size[0] / size[1]
                request["aspect"] = min(ASPECT_RATIOS, key=lambda key: abs(math.log(ratio / ASPECT_RATIOS[key])))
            if action in active_presets or action == "comfy":
                paths, extra_result = comfy(request, folder)
            else:
                handlers = {
                    "colab": cloud,
                    "openai_image": run_openai_image,
                    "gemini_image": run_gemini_image,
                    "export": export,
                    "hyperframes": hyperframes,
                    "title": hyperframes,
                    "mografy_motion": run_mografy_motion,
                }
                if action not in handlers:
                    raise ValueError(f"不支援的動作：{action}")
                paths = handlers[action](request, folder)
            if size:
                paths = resize_outputs(paths, size, folder, request["kind"])
        result = {"paths": paths, **extra_result}
        if paths and generation:
            result["generationAspect"] = request["aspect"]
        if paths and request.get("outputFolder") and (generation or action in {"title", "hyperframes", "mografy_motion"}):
            try:
                kind = request["kind"] if generation else "video"
                saved = save_outputs(paths, request["outputFolder"], folder.name.removeprefix("."), kind)
                result.update(paths=saved, originalPaths=paths)
            except (OSError, ValueError) as exc:
                result["warning"] = f"成品已保留在工作台。無法寫入指定資料夾：{exc}"
                log(result["warning"])
    except Exception as exc:
        result = {"error": str(exc)}
        log(result["error"])
    result_path.write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    return 1 if result.get("error") else 0


if __name__ == "__main__":
    sys.exit(main())
