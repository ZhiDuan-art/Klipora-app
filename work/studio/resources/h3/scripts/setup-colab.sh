#!/usr/bin/env bash
# Install only the local Colab dependencies; the plugin already supplies the skill.
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
uv python install 3.12
uv tool install --force --python 3.12 "google-colab-cli==0.7.4"
export PATH="$HOME/.local/bin:$PATH"
uv run --python 3.12 python "$SCRIPTS/patch_colab_cli.py"
colab --help >/dev/null
printf 'Colab CLI ready. Check existing login before requesting new authorization.\n'
