<div align="center">

<img src="work/studio/resources/KliporaLogo.png" alt="Klipora" width="128" />

# Klipora

**All-in-One Local AI Image, Voice & Multitrack Video Studio for Apple Silicon**

*Clip (`Klip`) × Luminous Spatial Aura (`-ora`) — Create, Voice, Cut & Export Offline on macOS.*

[![Platform](https://img.shields.io/badge/macOS-14.0%2B%20Apple%20Silicon-111113?style=flat-square)](#hardware-requirements)
[![Languages](https://img.shields.io/badge/Languages-繁中%20%7C%20简中%20%7C%20EN%20%7C%20日本語%20%7C%20한국어-4F8BFF?style=flat-square)](#5-language-localization)
[![Release](https://img.shields.io/badge/Release-v1.0.0%20DMG-F46B53?style=flat-square)](#installation)

</div>

---

## Why Klipora?

Most AI creators bounce between 5 disconnected apps: one web tab for generating images, another script for LoRAs, a terminal for local TTS voiceovers, a browser for cloud video, and a heavy NLE just to cut and add subtitles.

**Klipora unifies the entire creative pipeline into a single native macOS darkroom workstation:**

- **Local-First AI Image Generation**: Native ComfyUI bridge with built-in profiles (`SDXL 1.0`, `Z-Image Turbo`, `RedCraft`, `Iniverse FLUX`, `MOSS`, `Krea-2`), custom `.safetensors` model manager, central deduplicated storage, compatible LoRA manager, and custom ComfyUI API workflow support.
- **Multitrack Pro Video Editor**: Native SwiftUI + CoreText + FFmpeg + HyperFrames timeline with video/audio/subtitle/title tracks, transitions, color filters, and MP4 export.
- **Local Neural Voice Studio**: Bundled MLX / Qwen3-TTS voice synthesis with custom voice profiles, reference voice cloning, and offline AI audio tools.
- **Optional Cloud & Official APIs**: Seamless Google Colab OAuth bridge for Wan 2.2 / H3 cloud video & audio, plus opt-in OpenAI (`gpt-image-2.5-flare`) and Gemini (`gemini-nano-banana-2.1`) image APIs with Keychain-only credential storage and strict offline fallback.
- **Startup Self-Check & 4-Step Onboarding**: Adobe-style launch self-check verifies every engine before you start; first-run wizard checks hardware, guides ComfyUI setup, lets you pick starter models with clear disk-space budgets, and configures optional accounts.

---

## 5-Language Localization

Switch languages anytime inside **Setup & Connections** or the **Onboarding Wizard** — no restart required:

- 繁體中文 (`zh-Hant`)
- 简体中文 (`zh-Hans`)
- English (`en`)
- 日本語 (`ja`)
- 한국어 (`ko`)

---

## Hardware Requirements

| Tier | Mac Hardware | Unified Memory | Free Disk | Recommended Workflow |
| :--- | :--- | :--- | :--- | :--- |
| **Standard** | Apple Silicon (M1/M2/M3/M4/M5) | 16 GB | 25 GB+ | SDXL 1.0 Base + Qwen3-TTS 0.6B/1.7B + Multitrack Edit |
| **Pro / Flagship** | Apple Silicon Pro / Max / Ultra | 24–64 GB+ | 80 GB+ | Z-Image Turbo / FLUX / Krea-2 / MOSS + Multiple LoRAs |
| **Cloud Hybrid** | Any Apple Silicon Mac | 16 GB | 10 GB+ | Local Editing + Google Colab / Official Web or Opt-in APIs |

---

## Installation

### Option 1 — Download `.dmg` (Recommended for Beta Testers)
1. Download **`Klipora-1.0.0-arm64.dmg`** from [GitHub Releases](https://github.com/ZhiDuan-art/Klipora-app/releases).
2. Drag **Klipora.app** into **Applications**.
3. On first launch (developer/beta ad-hoc signed build), right-click **Klipora.app** → **Open** → **Open**.
4. Follow the built-in 4-step Onboarding Wizard to check hardware, connect ComfyUI, and select starter models.

### Option 2 — Deploy Automatically with Your AI Coding Agent (Codex / Claude / Antigravity)
Give your AI coding agent `https://github.com/ZhiDuan-art/Klipora-app` and ask it to follow **[DEPLOY_WITH_AI.md](DEPLOY_WITH_AI.md)**.

### Option 3 — Build from Source
```bash
git clone https://github.com/ZhiDuan-art/Klipora-app.git
cd Klipora-app/work/studio
bash build-app.sh /tmp/Klipora.app
```

---

## Architecture & Security Principles

- **Central Model Storage**: Weights live once under `~/Library/Application Support/MotionDesk/models/comfy/` and `models/loras/` and are exposed to ComfyUI via per-file symlinks or `extra_model_paths.yaml`.
- **Zero Plaintext Secrets**: API keys are stored exclusively in **macOS Keychain** (`kSecClassGenericPassword`), never written to project JSON, request logs, or CLI arguments, and automatically redacted from error output.
- **Honest Offline Mode**: `NWPathMonitor` disables only online providers when offline while keeping local ComfyUI loopback (`127.0.0.1`), local Voicebox, and multitrack editing 100% operational.

---

## Licenses & Third-Party Notices

Copyright © 2026 **Chih Tuan Chang** ([meteor199311@gmail.com](mailto:meteor199311@gmail.com)). All rights reserved.

See `work/studio/resources/THIRD_PARTY_NOTICES.md` and `work/studio/resources/LICENSE-Voicebox`. Large AI model weights are never bundled in this repository and remain subject to their respective upstream model licenses.
