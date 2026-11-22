"""Load auditable local fixes before the upstream frozen backend starts."""
import importlib.abc
import importlib.util
from pathlib import Path
import sys

class LocalBackendFixes(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        names = {
            'backend.backends.mlx_backend': 'mlx_backend.py',
            'backend.backends.mlx_worker': 'mlx_worker.py',
            'backend.backends.qwen_custom_voice_backend': 'qwen_custom_voice_backend.py',
        }
        filename = names.get(fullname)
        if filename:
            source = Path(sys.executable).parent.parent / 'Resources/backend-patches' / filename
            if not source.is_file():
                raise ImportError('Bundled backend fix is missing: ' + str(source))
            return importlib.util.spec_from_file_location(fullname, source)

sys.meta_path.insert(0, LocalBackendFixes())

# A blocked model download can outlive uvicorn's graceful shutdown because
# executor threads are non-daemon. Bound that cleanup to the owning App's life.
import os
import threading
import time
if '--parent-pid' in sys.argv:
    _app_pid = int(sys.argv[sys.argv.index('--parent-pid') + 1])
    def _app_lifetime():
        while True:
            try:
                os.kill(_app_pid, 0)
            except ProcessLookupError:
                time.sleep(8)
                os._exit(0)
            time.sleep(2)
    threading.Thread(target=_app_lifetime, daemon=True, name='voicebox-app-lifetime').start()
