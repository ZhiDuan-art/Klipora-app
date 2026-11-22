# h3-multimodal-colab installer for Windows (PowerShell).
# 1 uv  2 Python 3.12 + google-colab-cli 0.7.4 (0.7.5 drops its websocket on Windows)  3 Windows patch
# 4 copy the skill into the agent's skills folder. Nothing is downloaded to this computer except these tools;
# the H3 models are downloaded on the Colab GPU.

$ErrorActionPreference = "Stop"


if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Host "Installing uv ..."
    powershell -ExecutionPolicy Bypass -c "irm https://astral.sh/uv/install.ps1 | iex"
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
}
uv python install 3.12
uv tool install --force --python 3.12 "google-colab-cli==0.7.4"
$env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
python "$PSScriptRoot\patch_colab_cli.py"
if (-not $?) { uv run --python 3.12 python "$PSScriptRoot\patch_colab_cli.py" }

colab --help | Out-Null
if (-not $?) { throw "Colab CLI failed to start" }
Write-Host "Colab CLI ready. Check existing login first."
