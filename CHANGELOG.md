# Changelog & Debug Log / 更新與除錯紀錄

## v1.0.1 — 2026-11-23 00:58 (UTC+8)
### Bug Fixed / 問題修復
- **新建音訊軌／影片軌／文字軌無法拖放素材（A2 / V2 / T2 等多軌拖曳失效）**：
  - **Root Cause (原因)**：
    1. 在 macOS SwiftUI 中，`audioTrackLane` 與 `videoTrackLane` 同時串接了兩層 `.dropDestination(for: URL.self)` 與 `.dropDestination(for: String.self)`，外層 `String` 接收器會遮蔽內層 `URL` 接收器，導致從素材庫或 Finder 拖曳檔案到新軌道時被拒絕。
    2. 空白新軌道（`segments.isEmpty`）的 `.frame(width:height:)` 原本套在 `.dropDestination` 外部，使空白軌道的可拖放熱區縮成單行文字高度。
  - **Fix (修復內容)**：
    1. 新增統一的 `MultitrackDropItem: Transferable`（同時以 `ProxyRepresentation` 支援 `URL` 與 `String` 跨軌／轉場 payload），徹底消除雙層 `.dropDestination` 遮蔽問題。
    2. 為所有三種多軌軌道（`audioTrackLane`、`videoTrackLane`、`textTrackLane`）在 `.contentShape(Rectangle())` 與 `.dropDestination(...)` **之前**補上完整的 `.frame(width: contentWidth, height: ..., alignment: .leading)`，並同步加上拖放高亮與自動切換目前作用中軌道（`selectActiveTrack`）。
  - **Version Sync**：`Info.plist` 與啟動畫面／關於視窗版本同步升級為 `1.0.1`（動態讀取 `CFBundleShortVersionString`）。
  - **Affected Files**：`work/studio/src/MultitrackViews.swift`, `work/studio/src/KliporaStartupViews.swift`, `work/studio/Info.plist`

---

## v1.0.0 — 2026-11-22 23:02 (UTC+8)
- 首次公開釋出 Klipora 1.0（macOS Apple Silicon）。
- 內建乾淨的 68 組預設聲音角色庫（`default-voicebox-data.zip`，首次啟動自動部署至 `~/Library/Application Support/Klipora/voicebox-data/`，不覆蓋既有資料）。
- 預設資料路徑統一為 `~/Library/Application Support/Klipora/`，支援 5 國語言即時切換與 4 步驟新手引導。
