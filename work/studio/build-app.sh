#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="${1:?Pass the absolute path to the output .app}"
runtime="${MOTIONDESK_RUNTIME_DIR:-$here/hf-runtime}"
if [[ ! -d "$runtime" ]]; then
  runtime="/Users/zhangzhiduan/Documents/Codex/2026-11-09/https-github-com-dseditor-h3-colab/work/studio/hf-runtime"
fi
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources/runtime/bin" "$resources/backend-patches" "$resources/colab" "/tmp/md-v5-module-cache"

# Compile main Klipora app from modular Swift sources
swiftc -swift-version 5 -module-cache-path "/tmp/md-v5-module-cache" -parse-as-library \
  -target arm64-apple-macos14.0 \
  "$here/src/StudioTheme.swift" \
  "$here/src/LocalizationManager.swift" \
  "$here/src/KliporaStartupViews.swift" \
  "$here/src/Studio.swift" \
  "$here/src/MultitrackModels.swift" \
  "$here/src/MultitrackViews.swift" \
  "$here/src/TransitionAndMediaEngine.swift" \
  "$here/src/GenerationDockViews.swift" \
  "$here/src/ModelProfileViews.swift" \
  "$here/src/ManualLoRA.swift" \
  "$here/src/LocalModelManager.swift" \
  "$here/src/OnlineImageService.swift" \
  "$here/src/CustomWorkflow.swift" \
  "$here/src/ProStudioPanels.swift" \
  "$here/src/VoiceboxIntegration.swift" \
  "$here/src/PortabilitySetupViews.swift" \
  -o "$app/Contents/MacOS/Klipora"

# Compile native CoreText subtitle/title renderer helper
swiftc -swift-version 5 -module-cache-path "/tmp/md-v5-module-cache" \
  -target arm64-apple-macos14.0 \
  "$here/src/TextRender.swift" \
  -o "$resources/textrender"

# Bundle Voicebox standalone arm64 server into Contents/MacOS/voicebox-server
# and backend-patches into Contents/Resources/backend-patches (required by embedded local_backend_hook.py relative path)
VOICEBOX_BIN="${VOICEBOX_SERVER_BIN:-}"
if [[ -z "$VOICEBOX_BIN" ]]; then
  for cand in \
    "$here/../../outputs/Klipora.app/Contents/MacOS/voicebox-server" \
    "$here/../../outputs/MotionDesk.app/Contents/MacOS/voicebox-server" \
    "$here/../../releases/MotionDesk-Beta-Final/MotionDesk.app/Contents/MacOS/voicebox-server"; do
    if [[ -f "$cand" ]]; then
      VOICEBOX_BIN="$cand"
      break
    fi
  done
fi
if [[ -z "$VOICEBOX_BIN" || ! -f "$VOICEBOX_BIN" ]]; then
  echo "ERROR: voicebox-server binary not found" >&2
  exit 1
fi
if [[ ! "$VOICEBOX_BIN" -ef "$app/Contents/MacOS/voicebox-server" ]]; then
  cp -f "$VOICEBOX_BIN" "$app/Contents/MacOS/voicebox-server"
fi
chmod +x "$app/Contents/MacOS/voicebox-server"

cp -f "$here/resources/backend-patches/mlx_backend.py" \
      "$here/resources/backend-patches/mlx_worker.py" \
      "$here/resources/backend-patches/qwen_custom_voice_backend.py" \
      "$resources/backend-patches/"

ditto "$here/resources/colab" "$resources/colab"

# Copy Python worker, single-source-of-truth workflow engine, multitrack renderer, audio AI engine, and active model workflows
cp "$here/resources/worker.py" \
   "$here/resources/comfy_workflows.py" \
   "$here/resources/online_image.py" \
   "$here/resources/timeline_render.py" \
   "$here/resources/audio_ai.py" \
   "$here/resources/effects_catalog.json" \
   "$here/resources/model_profiles.json" \
   "$here/resources/zimage.json" \
   "$here/resources/redcraft.json" \
   "$here/resources/krea2.json" \
   "$here/resources/wan22.json" \
   "$here/resources/moss.json" \
   "$here/resources/flux.json" \
   "$here/resources/sdxl.json" \
   "$here/resources/engine.py" \
   "$here/resources/Klipora.icns" \
   "$here/resources/KliporaLogo.png" \
   "$here/resources/dependency_manifest.json" \
   "$here/resources/THIRD_PARTY_NOTICES.md" \
   "$here/resources/LICENSE-Voicebox" \
   "$resources/"

ditto "$here/resources/locales" "$resources/locales"

ditto "$here/resources/h3" "$resources/h3"
if [[ -r "$runtime/node-v22.23.5-darwin-arm64/bin/node" ]]; then
  cp "$runtime/node-v22.23.5-darwin-arm64/bin/node" "$resources/runtime/bin/node"
  cp "$runtime/node-v22.23.5-darwin-arm64/LICENSE" "$resources/runtime/NODE-LICENSE"
  ditto "$runtime/hyperframes" "$resources/runtime/hyperframes"
elif [[ -r "/private/tmp/MotionDesk-V4-Review3.app/Contents/Resources/runtime/bin/node" ]]; then
  cp "/private/tmp/MotionDesk-V4-Review3.app/Contents/Resources/runtime/bin/node" "$resources/runtime/bin/node"
  cp "/private/tmp/MotionDesk-V4-Review3.app/Contents/Resources/runtime/NODE-LICENSE" "$resources/runtime/NODE-LICENSE"
  ditto "/private/tmp/MotionDesk-V4-Review3.app/Contents/Resources/runtime/hyperframes" "$resources/runtime/hyperframes"
else
  echo "ERROR: bundled node + hyperframes runtime not found" >&2
  exit 1
fi
cp "$here/Info.plist" "$app/Contents/Info.plist"

# Sign helper executables first, then app bundle
codesign --force --sign - "$resources/textrender"
codesign --force --sign - "$app/Contents/MacOS/voicebox-server"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
