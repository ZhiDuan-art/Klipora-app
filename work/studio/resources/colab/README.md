# Voicebox standalone desktop integration

Based on Voicebox v0.5.0 (2bcb98d). Shared React UI + native Cocoa/WKWebView shell, with an embedded PyInstaller backend. The installed original Voicebox is no longer a runtime dependency. Models and voice library remain external in the existing shared cache/data directory; no model weights or account credentials are bundled.

Build on macOS27/arm64: install frontend dependencies with pnpm. A build-time Python3.12 environment requires PyInstaller. Run `colab-integration/build-macos.sh [output.app]`. Set VOICEBOX_BACKEND_SOURCE to an official v0.5.0 or existing integrated backend binary and VOICEBOX_ICON_SOURCE to its icon if not using the default build source under Applications. These source paths are used only when building; an existing integration bootstrap is replaced without nesting.

The bundler preserves every upstream archive member and replaces only the server entry with a bootstrap hook. Reviewed source overrides in Resources/backend-patches keep MLX loading, inference and unloading on one owning OS thread. The bundled runtime retains the original compiled dependencies. The original installed app is never edited by the build script.

Desktop local server:127.0.0.1:17495. Loopback bridge:127.0.0.1:17494. Bridge proxies the server and adds Colab job controls. Mutations require Host and a random per-launch token. Model/voice UI filters incompatible engines, automatically switches compatible engines when a voice changes, and labels download state. MLX worker regression tests verify all lifecycle calls remain on one thread. Busy health probes never start duplicate backends.

Colab sends the selected waveform and new Chinese dialogue to a new owned A100 session. The notebook uses LoadAudio with ref_audios.ref_audio_1. MP4 audio is extracted into PCM WAV and imported through the standard Voicebox history API. H3 provenance is recorded in instruct; duplicate voice names are guarded. The session is stopped after the job. Existing logged-in Colab CLI and FFmpeg on this Mac are used.

Checks: frontend tsc/build; test_bridge.py; test_mlx_worker.py; actual local generation and native playback/export. Original Tauri-specific global dictation/OS shortcuts are not ported.

Runner/notebook adapted from the local minimax-h3-colab skill. No OAuth state, models, generated voices or user library are included in this source overlay.

Version 0.5.4 removes the duration selector and manuscript character validation. The bridge plans punctuation-aware chunks, infers per-segment duration, submits one sequential H3 batch, trims only boundary silence, concatenates normalized PCM in order, and imports one history entry containing the full manuscript. Segment files survive batch errors.
