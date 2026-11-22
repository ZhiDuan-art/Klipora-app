# MotionDesk V5 — Third-Party Open Source Notices & Redistribution Boundaries

This document lists the bundled third-party components inside `MotionDesk.app` and clarifies the licensing and distribution boundaries for external/on-demand model weights and system tools.

---

## 1. Bundled Components Inside `MotionDesk.app`

### A. Voicebox Backend Server & MLX / Qwen3-TTS Integration (`Contents/MacOS/voicebox-server`, `Contents/Resources/backend-patches/`, `Contents/Resources/colab/`)
- **Upstream Project**: Voicebox (`sh.voicebox.app`) & Colab H3 Bridge Integration
- **License**: MIT License (see `Contents/Resources/LICENSE-Voicebox`)
- **Copyright**: Copyright (c) 2026 Voicebox Contributors
- **Bundled Files**:
  - `Contents/MacOS/voicebox-server` (PyInstaller standalone arm64 Mach-O server binary)
  - `Contents/Resources/backend-patches/{mlx_backend.py,mlx_worker.py,qwen_custom_voice_backend.py}`
  - `Contents/Resources/colab/{bridge.py,runner.py,local_backend_hook.py,bundle_server.py,README.md,assets}`

### B. Node.js Runtime (`Contents/Resources/runtime/bin/node`)
- **Version**: v22.23.5 (`darwin-arm64`)
- **License**: Node.js Open Source License / MIT (see `Contents/Resources/runtime/NODE-LICENSE`)

### C. HyperFrames Composition Engine (`Contents/Resources/runtime/hyperframes`)
- **License**: MIT License (includes GSAP standard no-charge license for non-paid end-user distribution)

---

## 2. Non-Bundled / User-Triggered Model Weights & External Tools

MotionDesk **does not bundle** multi-gigabyte third-party neural network weights or external GPL applications inside `MotionDesk.app`. Each external or user-downloaded component remains governed by its own upstream license:

1. **Qwen3-TTS 1.7B / 0.6B (Base & CustomVoice)** (`mlx-community/Qwen3-TTS-*`, `Qwen/Qwen3-TTS-*`):
   - **License**: Apache License 2.0 (Alibaba Cloud Qwen Team & mlx-community)
   - **Distribution**: Downloaded on demand by the user from HuggingFace Hub into `~/.cache/huggingface/hub` (or a user-selected cache folder).
2. **Local Audio AI Models (`ai-audio-venv` & `ai-models`)**:
   - **Faster-Whisper Base INT8**: MIT License
   - **UVR MDX-Net ONNX**: MIT License
   - **Sherpa-ONNX Kokoro v1.0 / ZipVoice-Distill INT8**: Apache License 2.0 (Kokoro archive includes `espeak-ng-data` under GPL-3.0, downloaded only when the user clicks Install).
3. **Local ComfyUI / Comfy Desktop**:
   - **License**: GPL-3.0 (external independent process accessed strictly over loopback HTTP API `http://127.0.0.1:<port>`).
4. **FFmpeg / FFprobe**:
   - **License**: LGPL v2.1+ or GPL v3 (depending on the user's system/Homebrew installation or custom binary).
5. **Google Colab CLI (`google-colab-cli`)**:
   - **License**: Apache License 2.0 (Google LLC).
