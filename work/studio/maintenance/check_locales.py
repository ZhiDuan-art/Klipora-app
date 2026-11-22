#!/usr/bin/env python3
"""Verify 100% key parity and non-empty strings across all 5 Klipora locale catalogs."""

from __future__ import annotations

import json
from pathlib import Path

LOCALES_DIR = Path(__file__).resolve().parent.parent / "resources" / "locales"
REQUIRED = ["zh-Hant", "zh-Hans", "en", "ja", "ko"]


def main() -> int:
    catalogs = {}
    for code in REQUIRED:
        path = LOCALES_DIR / f"{code}.json"
        assert path.is_file(), f"Missing locale file: {path}"
        data = json.loads(path.read_text(encoding="utf-8"))
        assert isinstance(data, dict) and data, f"Empty/invalid locale: {code}"
        for k, v in data.items():
            assert isinstance(v, str) and v.strip(), f"Empty value in {code} for key {k}"
        catalogs[code] = data

    base_keys = set(catalogs["zh-Hant"].keys())
    for code in REQUIRED[1:]:
        keys = set(catalogs[code].keys())
        missing = sorted(base_keys - keys)
        extra = sorted(keys - base_keys)
        assert not missing, f"{code} missing keys: {missing}"
        assert not extra, f"{code} extra keys: {extra}"

    print(f"ALL 5 LOCALES VERIFIED ({len(base_keys)} keys each: {', '.join(REQUIRED)}).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
