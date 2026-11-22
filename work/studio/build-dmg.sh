#!/bin/bash
set -euo pipefail

APP_PATH="${1:?Pass absolute path to Klipora.app}"
DMG_OUT="${2:?Pass absolute output path for Klipora-1.0.0-arm64.dmg}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: App bundle not found: $APP_PATH" >&2
  exit 1
fi

STAGE="$(mktemp -d /tmp/klipora-dmg-stage.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP_PATH" "$STAGE/Klipora.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/首次開啟說明.txt" <<'EOF'
Klipora 1.0 (Apple Silicon · 開發／內測分發版)

安裝方式：
1. 將「Klipora.app」拖曳至「Applications」資料夾。
2. 首次開啟時若 macOS 提示無法驗證開發者：
   - 對 Klipora.app 按右鍵 → 選擇「打開」→ 再點「打開」；或
   - 至「系統設定 → 隱私權與安全性」點擊「強制打開」。
3. 啟動後將自動執行元件自檢並開啟四步驟安裝引導（支援繁中／簡中／英／日／韓 5 國語言）。
EOF

rm -f "$DMG_OUT"
mkdir -p "$(dirname "$DMG_OUT")"
hdiutil create \
  -volname "Klipora 1.0" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_OUT"

echo "DMG_CREATED: $DMG_OUT"
ls -lh "$DMG_OUT"
