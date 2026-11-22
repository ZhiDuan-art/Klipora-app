"""Start a private loopback-only ComfyUI instance and report its actual port."""
import os
import runpy
import sys
import tempfile
from pathlib import Path

import torch
from aiohttp import web

ready = Path(sys.argv[1])
main = Path(sys.argv[2]).resolve()
original_start = web.TCPSite.start


async def report_ready(site):
    await original_start(site)
    if not site.name.startswith("http://127.0.0.1:"):
        return
    port = site._server.sockets[0].getsockname()[1]
    with tempfile.NamedTemporaryFile(mode="w", dir=ready.parent, delete=False) as marker:
        marker.write(str(port))
    os.replace(marker.name, ready)


web.TCPSite.start = report_ready
sys.path.insert(0, str(main.parent))
options = [] if torch.backends.mps.is_available() else ["--cpu"]
sys.argv = [str(main), *sys.argv[3:], "--listen", "127.0.0.1", "--port", "0", *options]
runpy.run_path(str(main), run_name="__main__")
