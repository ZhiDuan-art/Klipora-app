"""
MLX backend implementation for TTS and STT using mlx-audio.
"""

from typing import Optional, List, Tuple
import asyncio
from .mlx_worker import run_mlx, run_mlx_sync, qwen_snapshot_is_complete
import logging
import numpy as np
from pathlib import Path

logger = logging.getLogger(__name__)

# PATCH: Import and apply offline patch BEFORE any huggingface_hub usage
# This prevents mlx_audio from making network requests when models are cached
from ..utils.hf_offline_patch import patch_huggingface_hub_offline, ensure_original_qwen_config_cached

patch_huggingface_hub_offline()
ensure_original_qwen_config_cached()

from . import TTSBackend, STTBackend, LANGUAGE_CODE_TO_NAME, WHISPER_HF_REPOS
from .base import is_model_cached, combine_voice_prompts as _combine_voice_prompts, model_load_progress
from ..utils.cache import get_cache_key, get_cached_voice_prompt, cache_voice_prompt


def resolve_derived_reference_text(
    audio_path: str,
    reference_text: str,
    *,
    override_file: Optional[Path] = None,
) -> str:
    """
    Resolve a non-destructive derived reference transcript override from local
    MotionDesk cache metadata ONLY when the audio file content SHA-256 hash
    matches (and optional sample_id matches).

    Contract:
    - No user-specific transcript text is ever hardcoded in shipped code.
    - Same filename / sample_id with different audio bytes (SHA-256 mismatch)
      NEVER applies an override.
    - Missing or empty cache file preserves `reference_text` unchanged.
    """
    try:
        import hashlib as _hashlib
        import json as _json
        import os as _os

        p = Path(str(audio_path))
        if not p.is_file():
            return reference_text

        target_override = override_file
        if target_override is None:
            env_path = _os.environ.get("MOTIONDESK_REF_OVERRIDES_PATH")
            if env_path:
                target_override = Path(env_path).expanduser()
            else:
                target_override = Path(_os.path.expanduser(
                    "~/Library/Application Support/Klipora/cache/voicebox-reference-overrides.json"
                ))

        if not target_override.is_file():
            return reference_text

        data = _json.loads(target_override.read_text(encoding="utf-8"))
        entries = []
        if isinstance(data, dict):
            if isinstance(data.get("entries"), list):
                entries = data["entries"]
            elif isinstance(data.get("by_sha256"), dict):
                for sha_k, val in data["by_sha256"].items():
                    if isinstance(val, str):
                        entries.append({"audio_sha256": sha_k, "reference_text": val})
                    elif isinstance(val, dict):
                        e = dict(val)
                        e.setdefault("audio_sha256", sha_k)
                        entries.append(e)
        elif isinstance(data, list):
            entries = data

        if not entries:
            return reference_text

        audio_sha256 = _hashlib.sha256(p.read_bytes()).hexdigest().lower()
        stem = p.stem

        for entry in entries:
            if not isinstance(entry, dict):
                continue
            expected_sha = str(entry.get("audio_sha256") or "").strip().lower()
            if not expected_sha or expected_sha != audio_sha256:
                continue
            expected_sample_id = str(entry.get("sample_id") or "").strip()
            if expected_sample_id and expected_sample_id != stem:
                continue
            candidate_text = str(entry.get("reference_text") or "").strip()
            if candidate_text:
                return candidate_text
    except Exception as exc:
        logger.debug("Derived reference text check skipped: %s", exc)
    return reference_text



class MLXTTSBackend:
    """MLX-based TTS backend using mlx-audio."""

    def __init__(self, model_size: str = "1.7B"):
        self.model = None
        self.model_size = model_size
        self._current_model_size = None

    def is_loaded(self) -> bool:
        """Check if model is loaded."""
        return self.model is not None

    def _get_model_path(self, model_size: str) -> str:
        """
        Get the MLX model path.

        Args:
            model_size: Model size (1.7B or 0.6B)

        Returns:
            HuggingFace Hub model ID for MLX
        """
        mlx_model_map = {
            "1.7B": "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16",
            "0.6B": "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16",
        }

        if model_size not in mlx_model_map:
            raise ValueError(f"Unknown model size: {model_size}")

        hf_model_id = mlx_model_map[model_size]
        logger.info("MLX model repository: %s", hf_model_id)

        return hf_model_id

    def _is_model_cached(self, model_size: str) -> bool:
        repo = self._get_model_path(model_size)
        if not is_model_cached(repo, weight_extensions=(".safetensors", ".bin", ".npz")):
            return False
        try:
            from huggingface_hub import snapshot_download
            folder = Path(snapshot_download(repo, local_files_only=True))
            return qwen_snapshot_is_complete(folder)
        except Exception:
            return False

    async def load_model_async(self, model_size: Optional[str] = None):
        """
        Lazy load the MLX TTS model.

        Args:
            model_size: Model size to load (1.7B or 0.6B)
        """
        if model_size is None:
            model_size = self.model_size

        # If already loaded with correct size, return
        if self.model is not None and self._current_model_size == model_size:
            return

        # Run blocking load in thread pool
        await run_mlx(self._load_model_sync, model_size)

    # Alias for compatibility
    load_model = load_model_async

    def _load_model_sync(self, model_size: str):
        """Synchronous model loading."""
        if self.model is not None and self._current_model_size == model_size:
            return
        if self.model is not None:
            self._unload_model_sync()
        model_path = self._get_model_path(model_size)
        model_name = f"qwen-tts-{model_size}"
        is_cached = self._is_model_cached(model_size)
        if is_cached:
            from huggingface_hub import snapshot_download
            model_path = snapshot_download(model_path, local_files_only=True)

        with model_load_progress(model_name, is_cached):
            from mlx_audio.tts import load

            logger.info("Loading MLX TTS model %s...", model_size)

            self.model = load(model_path)

        self._current_model_size = model_size
        self.model_size = model_size
        logger.info("MLX TTS model %s loaded successfully", model_size)

    def unload_model(self):
        return run_mlx_sync(self._unload_model_sync)

    def _unload_model_sync(self):
        """Unload the model to free memory."""
        if self.model is not None:
            del self.model
            self.model = None
            self._current_model_size = None
            logger.info("MLX TTS model unloaded")

    async def create_voice_prompt(
        self,
        audio_path: str,
        reference_text: str,
        use_cache: bool = True,
    ) -> Tuple[dict, bool]:
        """
        Create voice prompt from reference audio.

        MLX backend stores voice prompt as a dict with audio path and text.
        The actual voice prompt processing happens during generation.

        Args:
            audio_path: Path to reference audio file
            reference_text: Transcript of reference audio
            use_cache: Whether to use cached prompt if available

        Returns:
            Tuple of (voice_prompt_dict, was_cached)
        """
        await self.load_model_async(None)
        reference_text = resolve_derived_reference_text(audio_path, reference_text)

        # Check cache if enabled
        if use_cache:
            cache_key = get_cache_key(audio_path, reference_text)
            cached_prompt = get_cached_voice_prompt(cache_key)
            if cached_prompt is not None:
                # Return cached prompt (should be dict format)
                if isinstance(cached_prompt, dict):
                    # Validate that the cached audio file still exists
                    cached_audio_path = cached_prompt.get("ref_audio") or cached_prompt.get("ref_audio_path")
                    if cached_audio_path and Path(cached_audio_path).exists():
                        return cached_prompt, True
                    else:
                        # Cached file no longer exists, invalidate cache
                        logger.warning("Cached audio file not found: %s, regenerating prompt", cached_audio_path)

        # MLX voice prompt format - store audio path and text
        # The model will process this during generation
        voice_prompt_items = {
            "ref_audio": str(audio_path),
            "ref_text": reference_text,
        }

        # Cache if enabled
        if use_cache:
            cache_key = get_cache_key(audio_path, reference_text)
            cache_voice_prompt(cache_key, voice_prompt_items)

        return voice_prompt_items, False

    async def combine_voice_prompts(self, audio_paths, reference_texts):
        return await _combine_voice_prompts(audio_paths, reference_texts)

    async def generate(
        self,
        text: str,
        voice_prompt: dict,
        language: str = "en",
        seed: Optional[int] = None,
        instruct: Optional[str] = None,
    ) -> Tuple[np.ndarray, int]:
        """
        Generate audio from text using voice prompt.

        Args:
            text: Text to synthesize
            voice_prompt: Voice prompt dictionary with ref_audio and ref_text
            language: Language code (en or zh) - may not be fully supported by MLX
            seed: Random seed for reproducibility
            instruct: Natural language instruction (may not be supported by MLX)

        Returns:
            Tuple of (audio_array, sample_rate)
        """
        await self.load_model_async(None)

        logger.info("Generating audio for text: %s", text)

        def _generate_sync():
            """Run synchronous generation in thread pool."""
            # MLX generate() returns a generator yielding GenerationResult objects
            audio_chunks = []
            sample_rate = 24000
            lang = LANGUAGE_CODE_TO_NAME.get(language, "auto")

            # Set seed if provided (MLX uses numpy random)
            if seed is not None:
                import mlx.core as mx

                np.random.seed(seed)
                mx.random.seed(seed)

            # Extract voice prompt info
            ref_audio = voice_prompt.get("ref_audio") or voice_prompt.get("ref_audio_path")
            ref_text = voice_prompt.get("ref_text", "")
            if ref_audio:
                ref_text = resolve_derived_reference_text(str(ref_audio), ref_text)

            # Validate that the audio file exists
            if ref_audio and not Path(ref_audio).exists():
                logger.warning("Audio file not found: %s", ref_audio)
                logger.warning("This may be due to a cached voice prompt referencing a deleted temp file.")
                logger.warning("Regenerating without voice prompt.")
                ref_audio = None

            # Inference runs with the process's default HF_HUB_OFFLINE
            # state. Forcing offline here (previously used to avoid lazy
            # mlx_audio lookups hanging when the network drops mid-inference,
            # issue #462) regressed online users because libraries make
            # legitimate metadata calls during generation.
            try:
                if ref_audio:
                    # Check if generate accepts ref_audio parameter
                    import inspect

                    sig = inspect.signature(self.model.generate)
                    if "ref_audio" in sig.parameters:
                        # Generate with voice cloning
                        for result in self.model.generate(text, ref_audio=ref_audio, ref_text=ref_text, lang_code=lang):
                            audio_chunks.append(np.array(result.audio))
                            sample_rate = result.sample_rate
                    else:
                        # Fallback: generate without voice cloning
                        for result in self.model.generate(text, lang_code=lang):
                            audio_chunks.append(np.array(result.audio))
                            sample_rate = result.sample_rate
                else:
                    # No voice prompt, generate normally
                    for result in self.model.generate(text, lang_code=lang):
                        audio_chunks.append(np.array(result.audio))
                        sample_rate = result.sample_rate
            except Exception as e:
                # Never silently replace the selected voice with an unrelated voice.
                raise RuntimeError(f"所選聲音生成失敗：{e}") from e

            # Concatenate all chunks
            if audio_chunks:
                audio = np.concatenate([np.asarray(chunk, dtype=np.float32) for chunk in audio_chunks])
            else:
                raise RuntimeError("本機模型未產生音訊，請重試或切換模型。")

            return audio, sample_rate

        # Run blocking inference in thread pool
        audio, sample_rate = await run_mlx(_generate_sync)

        return audio, sample_rate


class MLXSTTBackend:
    """MLX-based STT backend using mlx-audio Whisper."""

    def __init__(self, model_size: str = "base"):
        self.model = None
        self.model_size = model_size

    def is_loaded(self) -> bool:
        """Check if model is loaded."""
        return self.model is not None

    def _is_model_cached(self, model_size: str) -> bool:
        hf_repo = WHISPER_HF_REPOS.get(model_size, f"openai/whisper-{model_size}")
        return is_model_cached(hf_repo, weight_extensions=(".safetensors", ".bin", ".npz"))

    async def load_model_async(self, model_size: Optional[str] = None):
        """
        Lazy load the MLX Whisper model.

        Args:
            model_size: Model size (tiny, base, small, medium, large)
        """
        if model_size is None:
            model_size = self.model_size

        if self.model is not None and self.model_size == model_size:
            return

        # Run blocking load in thread pool
        await run_mlx(self._load_model_sync, model_size)

    # Alias for compatibility
    load_model = load_model_async

    def _load_model_sync(self, model_size: str):
        """Synchronous model loading."""
        progress_model_name = f"whisper-{model_size}"
        is_cached = self._is_model_cached(model_size)

        with model_load_progress(progress_model_name, is_cached):
            from mlx_audio.stt import load

            model_name = WHISPER_HF_REPOS.get(model_size, f"openai/whisper-{model_size}")
            logger.info("Loading MLX Whisper model %s...", model_size)

            self.model = load(model_name)

        self.model_size = model_size
        logger.info("MLX Whisper model %s loaded successfully", model_size)

    def unload_model(self):
        return run_mlx_sync(self._unload_model_sync)

    def _unload_model_sync(self):
        """Unload the model to free memory."""
        if self.model is not None:
            del self.model
            self.model = None
            logger.info("MLX Whisper model unloaded")

    async def transcribe(
        self,
        audio_path: str,
        language: Optional[str] = None,
        model_size: Optional[str] = None,
    ) -> str:
        """
        Transcribe audio to text.

        Args:
            audio_path: Path to audio file
            language: Optional language hint
            model_size: Optional model size override

        Returns:
            Transcribed text
        """
        await self.load_model_async(model_size)

        def _transcribe_sync():
            """Run synchronous transcription in thread pool."""
            # MLX Whisper transcription using generate method
            # The generate method accepts audio path directly
            decode_options = {}
            if language:
                decode_options["language"] = language

            # Inference runs with the process's default HF_HUB_OFFLINE
            # state — see the comment in MLXTTSBackend.generate for the
            # regression this revert fixes (issue #462).
            result = self.model.generate(str(audio_path), **decode_options)

            # Extract text from result
            if isinstance(result, str):
                return result.strip()
            elif isinstance(result, dict):
                return result.get("text", "").strip()
            elif hasattr(result, "text"):
                return result.text.strip()
            else:
                return str(result).strip()

        # Run blocking transcription in thread pool
        return await run_mlx(_transcribe_sync)
