#!/usr/bin/env python3
"""Focused verification for MotionDesk Build 39 UI/Settings behavior."""

from __future__ import annotations

import json
import plistlib
from pathlib import Path

STUDIO = Path(__file__).resolve().parent.parent
SRC = STUDIO / "src"
RESOURCES = STUDIO / "resources"


def main() -> int:
    theme = (SRC / "StudioTheme.swift").read_text(encoding="utf-8")
    studio = (SRC / "Studio.swift").read_text(encoding="utf-8")
    setup = (SRC / "PortabilitySetupViews.swift").read_text(encoding="utf-8")
    mt = (SRC / "MultitrackViews.swift").read_text(encoding="utf-8")
    pro = (SRC / "ProStudioPanels.swift").read_text(encoding="utf-8")

    # 1. Vibrant Tidewell coral reserved for primary CTAs + neutral ordinary controls
    assert "#F46B53" in theme and "0.957" in theme, "Expected vibrant Tidewell coral #F46B53 in StudioTheme"
    assert "static let neutralAccent" in theme, "Expected neutralAccent in StudioTheme"
    assert ".tint(StudioTheme.neutralAccent)" in studio, "Main shell must use neutral tint, not global coral"
    assert "onlineGenerationUnavailable" in studio, "Codex build38 API Generate button gate must be preserved"
    assert "mtCyanAccent = StudioTheme.neutralAccent" in mt
    assert "proCyan = StudioTheme.neutralAccent" in pro

    # 2. Four top status cards are clickable Buttons wired to ScrollViewReader with stable anchors
    assert "ScrollViewReader { scrollProxy in" in setup
    for anchor, detail_flag in [
        (".runtime", "manager.showCard6Details = true"),
        (".account", "manager.showCard4Details = true"),
        (".models", "manager.showCard3Details = true"),
        (".service", "manager.showCard2Details = true"),
    ]:
        assert f".id(SetupSectionAnchor{anchor})" in setup, f"Missing ScrollViewReader target {anchor}"
        assert detail_flag in setup, f"Missing detail expansion {detail_flag}"
    assert 'return "2. 雲端登入與 API"' in setup, "Pillar 2 must be renamed to 2. 雲端登入與 API"
    assert "scrollProxy.scrollTo(anchor, anchor: .top)" in setup

    # Ensure navigateToSection never auto-verifies network, logs in, or starts GPU
    nav_start = setup.index("private func navigateToSection(")
    nav_block = setup[nav_start : nav_start + 700]
    for forbidden in ["checkColabLoginStatus", "startColabBrowserAuthentication", "testAPIConnection", "toggleEngine"]:
        assert forbidden not in nav_block, f"navigateToSection must not call {forbidden}"

    # 3. Honest Colab / API / Model statuses
    assert 'accountBadge = .neutral("Colab 授權檔已找到，尚未線上檢查")' in setup
    assert 'return .neutral("Colab 授權檔已找到，尚未線上檢查")' in setup
    assert 'modelBadge = .ready("語音模型就緒' in setup
    assert 'modelBadge = .ready("繪圖模型就緒' in setup
    assert '未設定（選用）' in setup
    assert '固定官方主機：\\(provider.defaultServiceURL)' in setup

    # 4. Responsive sizing (960x680 main app, compact sheet >= 640x500)
    assert ".frame(minWidth: 960, minHeight: 680)" in studio
    assert ".frame(minWidth: 640, idealWidth: 820, maxWidth: 960, minHeight: 500, idealHeight: 620, maxHeight: 760)" in setup

    # 5. Version & manifest synced to build 39
    plist = plistlib.loads((STUDIO / "Info.plist").read_bytes())
    assert plist["CFBundleShortVersionString"] == "0.2.0"
    assert plist["CFBundleVersion"] == "39"
    manifest = json.loads((RESOURCES / "dependency_manifest.json").read_text(encoding="utf-8"))
    assert manifest["appVersion"] == "0.2.0"
    assert manifest["buildNumber"] == "39"

    print("ALL BUILD 39 FOCUSED UI/SETTINGS CHECKS PASSED.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
