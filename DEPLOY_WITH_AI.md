# Deploy Klipora with an AI Agent (Codex / Claude Code / Antigravity)

This guide is designed so any user can hand this GitHub repository URL to an AI coding assistant and have it safely set up **Klipora** on macOS (Apple Silicon).

## Prerequisites Check
1. Verify macOS 14.0+ on Apple Silicon (`uname -m` == `arm64`).
2. Verify Xcode Command Line Tools (`swiftc --version`) and Python 3 (`python3 --version`).
3. Verify FFmpeg (`which ffmpeg` — install via `brew install ffmpeg` if missing).
4. Optional for local image generation: check `/Applications/Comfy Desktop.app` or `/Applications/ComfyUI.app`. If missing, guide the user to download from https://www.comfy.org/download.

## Build & Verify Steps
1. Run locale integrity check:
   ```bash
   python3 work/studio/maintenance/check_locales.py
   ```
2. Run isolated unit tests (never mutates real `~/Library/Application Support`):
   ```bash
   python3 work/studio/maintenance/test_build38.py
   ```
3. Obtain the companion binary assets (`voicebox-server` and `hf-runtime` Node/HyperFrames bundle) from the GitHub Release asset if not already present locally, then build:
   ```bash
   bash work/studio/build-app.sh /tmp/Klipora.app
   codesign --verify --strict --deep /tmp/Klipora.app
   ```
4. Optionally package a drag-to-Applications DMG:
   ```bash
   bash work/studio/build-dmg.sh /tmp/Klipora.app /tmp/Klipora-1.0.0-arm64.dmg
   ```

## Safety Rules for AI Agents
- Never commit `.safetensors`, `.gguf`, `.ckpt`, `.dmg`, `.app`, or files >100 MB to Git.
- Never auto-download multi-GB models without explicit user selection and free-disk check.
- Never store API keys in JSON/env files; use Klipora's macOS Keychain settings UI.
- Never move `.app` bundles to Trash on Macs with AppCleaner SmartDelete enabled.
