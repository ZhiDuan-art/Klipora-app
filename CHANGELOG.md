# Changelog & Debug Log / 更新與除錯紀錄

## v1.0.8 — 2026-11-23 20:46 (UTC+8)
### Multi-File Reference Upload for Motion Graphics / 動態圖形支援多檔案參考素材與文件上傳
- **動態圖形（Mografy Skill）分頁新增「參考素材與資料檔案」多檔案上傳與拖放區**：
  - 支援點擊「上傳多檔…」或直接從 Finder 拖放**多個檔案**（圖片／PNG／SVG Logo、Word `.docx`、Excel `.xlsx`、`.csv`、`.pdf`、`.md`、`.txt`、`.json`），附類型標籤、檔案計數與單筆／清空移除按鈕。
  - **自動分類佈署與零相依 Office 內容預先擷取**（`worker.py`）：
    - 圖片與 SVG Logo 自動複製到 `projects/<slug>/assets/`，讓 Mografy 場景以原圖像素級精準繪製不變形；
    - Word / Excel / CSV / PDF 等資料檔自動複製到 `projects/<slug>/brief-files/`，並以 Python 標準庫自動擷取 `.docx` 段落與 `.xlsx` 工作表數據至 `_extracted_summary.txt` 供 Agent 直接讀取，確保數據圖表與文案 100% 精準。
- **Affected Files**：`work/studio/src/MografySkillIntegration.swift`, `work/studio/src/Studio.swift`, `work/studio/resources/worker.py`, `work/studio/Info.plist`

---

## v1.0.7 — 2026-11-23 20:25 (UTC+8)
### Accurate ETA & Antigravity Live Streaming / 預估剩餘時間精準化與 Antigravity 即時串流日誌
- **修正底部狀態列「預估剩餘時間（ETA）」失真問題**：
  - **Root Cause (原因)**：AI Agent 撰寫動畫腳本期間進度條停在固定的起始里程碑（如 `12%`），原本的 ETA 公式拿 `已耗時 ÷ 12%` 硬推算，導致畫面顯示「預估剩餘 ~46 分 / ~1 小時 18 分」等失真數字。
  - **Fix (修復內容)**：`formattedJobETA` 改為僅在具備**真實線性步數／影格數**（如 ComfyUI 的 `step/max` 或 Mografy 渲染的 `Capturing frames X/Y`，且至少完成 2 步）時才顯示預估剩餘時間；Agent 撰寫與思考階段只顯示即時經過時間（`已耗時 MM:SS`），不再出現誤導數字。
- **Antigravity (`agy`) 即時串流輸出**：
  - `worker.py` 呼叫 `agy -p` 時加上 `--output-format stream-json` 並解析 NDJSON 事件，讓「工作紀錄」與目前執行階段在 Antigravity 製作動畫期間能即時更新。
- **Affected Files**：`work/studio/src/Studio.swift`, `work/studio/resources/worker.py`, `work/studio/Info.plist`

---

## v1.0.6 — 2026-11-23 19:26 (UTC+8)
### Independent ComfyUI Mode Switcher & Mografy Motion Graphics Skill Integration / ComfyUI 雙模式獨立切換與 Mografy 動態圖形整合
- **本機 ComfyUI 雙模式改為同層獨立切換（不再互相巢狀隱藏）**：
  - 將原本藏在「本機 ComfyUI 連線」折疊選單底下的「由 Klipora 啟動本機 ComfyUI」抽離為同層級二選一切換：**`Klipora 託管引擎`**（預設推薦，顯示狀態燈／自動埠號／一鍵啟停，並自動套用 `--fp32-vae`）與 **`外部 ComfyUI Desktop`**（獨立位址欄／開啟 Comfy Desktop／外部連線檢查）。
- **新增 Mografy 動態圖形（Motion Graphics Skill）條件式擴充整合**：
  - 新增 [MografySkillIntegration.swift](work/studio/src/MografySkillIntegration.swift)，並在「元件與連線設定」加入 **AI Agent 技能擴充（Mografy Skill）** 引導卡片：可一鍵複製安裝指令給 **Claude Code / Codex CLI / Antigravity**、自動偵測本機 Agent CLI 與 `SKILL.md` 安裝狀態，並支援自訂 Mografy 工作區目錄。
  - **條件解鎖「動態圖形」分頁**：未安裝時輸出列維持極簡 `[圖片 | 影片]`；偵測到已安裝 Mografy Skill 且至少一款 Agent CLI 可用時，生成頁輸出列自動出現第三個分頁 **`動態圖形`**。
  - **Klipora 頁內直接下指令 → 自動入庫**：在「動態圖形」分頁可選擇 Agent 引擎、比例（16:9 / 9:16 / 1:1）與片長（3–30 秒），透過 `worker.py`（`mografy_motion`）於 Mografy 工作區背景呼叫 Agent 撰寫與渲染 MP4，完成後自動匯入素材庫並同步顯示即時進度與經過時間。
- **Affected Files**：`work/studio/src/MografySkillIntegration.swift`, `work/studio/src/PortabilitySetupViews.swift`, `work/studio/src/Studio.swift`, `work/studio/resources/worker.py`, `work/studio/build-app.sh`, `work/studio/Info.plist`

---

## v1.0.5 — 2026-11-23 18:55 (UTC+8)
### New Local Video Models & Optional Downloader / 新增本機高階影片預設與可選下載清單
- **新增 2 款 ComfyUI 原生免外掛本機影片一鍵預設工作流**：
  1. **`Wan 2.2 14B MoE + 4-step 加速 (FP8)`（`wan22_14b`）**：
     - 採用 ComfyUI 原生 High-Noise / Low-Noise 雙專家 FP8 模型 + `LightX2V 4-step LoRA` + `Wan 2.1 VAE`（免裝第三方 GGUF 外掛），僅需 **4–8 步（CFG 1.0、16fps）** 即可完成，手部物理與人物互動品質遠勝 5B（需 5 個檔案、合計約 31.3 GB，建議 36GB+ RAM）。
  2. **`LTX-Video 13B Distilled (FP8)`（`ltxv13b`）**：
     - 採用 Lightricks 官方 8 步蒸餾 FP8 Checkpoint（內建 VAE，共用既有 T5-XXL），支援文生影（`EmptyLTXVLatentVideo`）與圖生影（`LTXVImgToVideo`）自動切換，Apple Silicon 速度最快（5 秒約 1–3 分鐘、約 15.7 GB，建議 32GB+ RAM）。
- **可選模型下載清單升級（`KliporaStartupViews.swift`）**：
  - 升級 `StarterModelOption` 支援多檔案套件下載（`StarterModelFile`），可一鍵下載 **LTX-Video 13B Distilled (15.70 GB)** 與 **Wan 2.2 14B MoE + 4-step 加速 (31.30 GB，5 檔自動分目錄存放)**，並附中文說明、速度／畫質建議與建議記憶體門檻；所有 6 條 HuggingFace 官方連結均實測 `HTTP 200`。
- **完整驗證**：全部 9 款內建工作流（含 `wan22_14b_i2v`、`ltxv13b_t2v`、`ltxv13b_i2v`）通過 `comfy_workflows.py --self-test`（`0 roundtrip diffs`）與 Build 38 隔離測試。
- **Affected Files**：`work/studio/resources/wan22_14b.json`, `work/studio/resources/ltxv13b.json`, `work/studio/resources/model_profiles.json`, `work/studio/resources/comfy_workflows.py`, `work/studio/resources/worker.py`, `work/studio/src/KliporaStartupViews.swift`, `work/studio/src/ModelProfileViews.swift`, `work/studio/src/Studio.swift`, `work/studio/src/GenerationDockViews.swift`, `work/studio/build-app.sh`, `work/studio/Info.plist`

---

## v1.0.4 — 2026-11-23 12:30 (UTC+8)
### Video Quality Fix, Live Progress Bar & Long-Video Timeout Fix / 本機影片畫質修復、即時進度條與長片逾時修復
- **修復本機 Wan 2.2 影片在 Apple Silicon (MPS) 上出現螢光綠網格／馬賽克顆粒（`--fp32-vae`）**：
  - **Root Cause (原因)**：ComfyUI 在 macOS MPS 上預設以 `torch.bfloat16` 載入並解碼 `wan2.2_vae.safetensors`，導致 3D VAE 解碼階段產生嚴重的綠色網格與點陣雜訊。
  - **Fix (修復內容)**：由 Klipora 啟動本機 ComfyUI 時自動帶入 `--fp32-vae`，以全精度 `torch.float32` 進行 VAE 解碼；經同提示詞與同種子碼實機對照驗證，綠色網格徹底消除、毛髮與森林細節恢復銳利自然。
  - 同步修正模型參數摘要列將 `Wan 2.2 TI2V-5B (FP16)` 誤標為 `FP8` 的顯示問題（改為優先判定模型名稱精度）。
- **新增即時進度條、完成度 %、執行階段、步數、經過時間與預估剩餘時間（ETA）**：
  - `worker.py` 新增零相依標準庫 RFC 6455 WebSocket 監聽器（`_ComfyProgressMonitor`），連線至本機 ComfyUI `/ws?clientId=...` 即時回報目前節點階段（載入模型／編碼條件／採樣生成中／VAE 解碼中／儲存影片中）與採樣步數（`step/max`）。
  - 底部狀態列在生成或匯出時即時顯示進度條、粗體完成度 `%`、步數 `(step/max)`、動態計時器（`已耗時 MM:SS`）與 `預估剩餘 ~X 分`。
- **修復本機長秒數影片在 30 分鐘強制中斷問題**：
  - **Root Cause (原因)**：`worker.py` 原先對所有本機 ComfyUI 工作寫死 `1800` 秒（30 分鐘）逾時並自動送出 `/interrupt`，導致 6–15 秒 Wan 2.2 影片在 MPS 上尚未跑完即被強制中斷。
  - **Fix (修復內容)**：本機影片逾時上限放寬至 **2 小時（7200 秒）**，且只要 WebSocket 監聽到 ComfyUI 仍在持續推進步數，將自動延長上限至最高 4 小時，不再誤殺長片生成工作。
- **Affected Files**：`work/studio/resources/worker.py`, `work/studio/src/Studio.swift`, `work/studio/src/ModelProfileViews.swift`, `work/studio/Info.plist`

---

## v1.0.3 — 2026-11-23 11:10 (UTC+8)
### Bug Fixed & Video Duration Upgrade / 本機影片生成修復與片長擴充
- **修復 Wan 2.2 本機影片生成出現「ComfyUI 畫布工作流反解驗證失敗（SaveVideo 遺失 format / codec）」**：
  - **Root Cause (原因)**：新版 ComfyUI 將 `SaveVideo` 節點的 `format` 與 `codec` 升級為 V3 動態下拉類型 `COMFY_DYNAMICCOMBO_V3`，`comfy_workflows.py` 的 `PRIMITIVE_WIDGET_TYPES` 原未包含該類型，導致比對本機 ComfyUI `/object_info` 時漏填 widget 並觸發反解驗證失敗。
  - **Fix (修復內容)**：將 `COMFY_DYNAMICCOMBO_V3` 加入 `PRIMITIVE_WIDGET_TYPES`，完整相容新版 ComfyUI V3 節點（全部 7 款內建工作流皆已通過即時 `/object_info` 反解驗證 `0 diffs`）。
- **本機 Wan 2.2 影片片長上限由 5 秒擴充至 15 秒（2–15 秒）**：
  - 同步放寬 `Studio.swift`、`ModelProfileViews.swift`、`GenerationDockViews.swift` 與 `model_profiles.json` 的本機影片片長範圍至 `2–15` 秒（24×秒+1 幀，實測通過 2s=49 幀、5s=121 幀、15s=361 幀工作流驗證與實機生成驗收）。
- **Affected Files**：`work/studio/resources/comfy_workflows.py`, `work/studio/resources/model_profiles.json`, `work/studio/src/Studio.swift`, `work/studio/src/ModelProfileViews.swift`, `work/studio/src/GenerationDockViews.swift`, `work/studio/Info.plist`

---

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
