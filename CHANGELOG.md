# Changelog & Debug Log / 更新與除錯紀錄

## v1.0.2 — 2026-11-23 08:16 (UTC+8)
### New UX Improvements / 素材庫操作體驗升級
- **素材庫支援直接拖曳匯入（Finder Drag-and-Drop Import）**：
  - 在「生成」與「剪輯」兩個工作區的素材庫中，現在可以直接從 Finder 拖曳單個／多個影片、圖片、音檔或資料夾直接放進素材庫匯入，並顯示藍色虛線與「放開滑鼠以匯入素材」提示框。
  - 自動遞迴掃描資料夾內支援格式、去重並背景載入音訊／影片時長。
- **素材庫支援滑鼠框選多選（Marquee Box Selection）與 ⌘+點擊**：
  - 在素材庫空白處／邊緣按住滑鼠左鍵拖拉，即可拉出藍色半透明框選矩形，即時多選所碰觸的素材項目（按住 `Shift` 或 `⌘` 框選可累加選取），不必先按「多選」按鈕。
  - 支援 `⌘ + 點擊` 單項切換多選，點擊空白處立即取消多選；剪輯頁多選列亦新增「**加入軌道**」按鈕，可一次將框選的多個素材依序加入作用中軌道。
- **Affected Files**：`work/studio/src/Studio.swift`, `work/studio/src/MultitrackViews.swift`, `work/studio/Info.plist`

---

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
