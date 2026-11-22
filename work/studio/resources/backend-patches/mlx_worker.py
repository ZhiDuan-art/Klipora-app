"""Keep MLX model arrays and GPU streams on one owning OS thread."""
import asyncio
import functools
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

def qwen_snapshot_is_complete(folder):
    folder = Path(folder)
    return all((folder / name).is_file() for name in (
        'config.json', 'model.safetensors', 'tokenizer_config.json',
        'speech_tokenizer/config.json', 'speech_tokenizer/model.safetensors',
    ))

_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='voicebox-mlx')
_owner = None

def _invoke(fn, args, kwargs):
    global _owner
    _owner = threading.get_ident()
    return fn(*args, **kwargs)

async def run_mlx(fn, *args, **kwargs):
    return await asyncio.wrap_future(_executor.submit(_invoke, fn, args, kwargs))

def run_mlx_sync(fn, *args, **kwargs):
    if threading.get_ident() == _owner:
        return fn(*args, **kwargs)
    return _executor.submit(_invoke, fn, args, kwargs).result()
