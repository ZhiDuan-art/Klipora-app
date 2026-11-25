# Changelog & Debug Log / 更新與除錯紀錄

## v1.1.5 — 2026-11-25 13:53 (UTC+8)
### BreezyVoice Default + Curated 3-Engine Voice Menu, Timeline Marquee Multi-Select, Full-Capsule Hit Testing, Auto-Match Source Aspect & Apple Silicon MPS FP8 Fix for Wan 2.2 14B MoE / BreezyVoice 設為預設、軌道滑鼠拖曳框選、整顆膠囊點擊、自適應原圖比例與 Wan 2.2 14B MoE Apple Silicon MPS 完整支援
- **語音模型精簡 + `MediaTek BreezyVoice` 設為預設**：
  - 修復 `cloningEngineNames` 相容性判斷並將 68 聲線主選單精簡為 3 個核心引擎：**`MediaTek BreezyVoice（台灣國語 · 68 聲線）`**（設為預設）、**`Qwen3-TTS 1.7B Base（多語／中文）`**、**`Chatterbox Turbo（英文快速）`**，點擊未下載模型皆支援一鍵下載，並強化 4 檔核心權重完整度驗證。
- **多軌時間軸支援滑鼠拖曳框選多個素材（Marquee Multi-Selection）**：
  - 於空白軌道區拖曳超過 `4px` 即可拉出青色選取框，跨軌同時框選影片／音訊／文字／形狀片段（支援 `Shift` 疊加框選），並新增單一 Undo 批次刪除（Ripple 模式採各軌時間區間聯集計算，不重複扣除重疊區段）。
- **全站按鈕改為整顆膠囊可點擊**：
  - 於 `StudioTheme.swift`（`KliporaPillButtonStyle`、`KliporaSegmentedControl`、`KliporaPillMenuPicker`）及剪輯／生成工作台全部 `.buttonStyle(.plain)` 膠囊按鈕加上 `.contentShape(.interaction, Capsule())`，並將原本寫在 `Button` 外層的尺寸與背景收進 `label:` 內，消除僅文字區可點的死角。
- **本機影片生成重大升級與 Apple Silicon MPS 完整相容**：
  - 新增「**自適應原圖比例**」輸出尺寸模式：自動讀取首幀／參考圖解析度，等比對齊至 16 倍數安全像素尺寸（不拉扯、不硬裁切）。
  - 本機影片模型選單改為**僅顯示本機已下載模型**（移出 `LTX-Video 13B Distilled`）；`Wan 2.2 TI2V-5B` 預設步數提升至 `25 steps`（上限 `35`）；`Wan 2.2 14B MoE + 4-step` 輸出後自動套用 **16fps → 24fps 光流補幀**消除 24fps 時間軸卡頓感。
  - 於 `engine.py` 加入 **Apple Silicon MPS 低記憶體逐層 FP8 → FP16 反量化 Hook**（攔截 `TensorCoreFP8Layout`、`comfy.quant_ops` 與 `stochastic_rounding`，搭配 `--fp16-unet --lowvram`），在不改動使用者 ComfyUI venv 的前提下徹底解決 `Float8_e4m3fn` MPS 報錯與 48 GB 統一記憶體爆量問題，實測雙 14B 專家 + 4-step LoRA 端對端 100% 通過。
- **Affected Files**：`work/studio/Info.plist`, `work/studio/src/StudioTheme.swift`, `work/studio/src/Studio.swift`, `work/studio/src/MultitrackModels.swift`, `work/studio/src/MultitrackViews.swift`, `work/studio/src/ProStudioPanels.swift`, `work/studio/src/VoiceboxIntegration.swift`, `work/studio/src/PortabilitySetupViews.swift`, `work/studio/resources/engine.py`, `work/studio/resources/worker.py`, `work/studio/resources/model_profiles.json`, `work/studio/resources/wan22_14b.json`

---

## v1.1.2 — 2026-11-25 02:14 (UTC+8)
### MediaTek BreezyVoice (Taiwanese Mandarin · 68 Shared Voices), Edit Mode Capsule UI & Focus Fix / 聯發創新基地 BreezyVoice（台灣國語 · 68 聲線共用）、剪輯模式全站膠囊 R 角統一與專案命名焦點修復
- **接入 MediaTek `BreezyVoice`（台灣國語 Zero-Shot TTS · 共用 68 聲線）**：
  - 新增獨立本機執行腳本 `breezyvoice_tts.py`（隔離於 `breezyvoice-venv`，按需一鍵安裝，不膨脹 DMG 體積），支援 `MediaTek-Research/BreezyVoice`（Apache-2.0）自然台灣國語合成與注音多音字標註（如 `[:ㄏㄠ3]`）。
  - 直接共用 Klipora 現有 **68 種聲音角色**的參考 `.wav` 與逐字稿，無須重新錄音或重建角色；合成前自動卸載 MLX 語音模型以保護 Apple Silicon 統一記憶體。
  - 於「本機神經語音工作室」引擎選單與設定頁「管理語音模型」彈窗加入一鍵下載、即時進度條與移除釋放空間功能（並預留 `BreezyVoice-26` 台語權重接入介面）。
- **剪輯模式全站 R 角統一（Capsule & `StudioTheme.Radius`）**：
  - 全面升級 `MultitrackViews.swift`、`ProStudioPanels.swift`、`VoiceboxIntegration.swift`：將預覽上方 `時間軸 / 素材原檔` 切換鈕、右側 Inspector 頁籤與輸出面板（`720p / 1080p / 4K / 直式 9:16 / 方形 1:1`、`影格率`、`編碼器`、`位元深度`、`預覽成片 / 匯出 MP4`）、空狀態按鈕、左側搜尋欄、AI 工具卡片與所有功能按鈕統一為圓潤 `Capsule()` 與 `12pt` 連續圓角卡片。
- **修復剪輯頁輸入焦點卡在「專案名稱」的問題**：
  - 將頂部專案名稱改為**點擊才進入編輯模式**（預設顯示靜態文字＋鉛筆圖示），並於按下 Enter / Esc、失焦或切換「生成／剪輯」工作區時自動釋放 First Responder，確保剪輯頁空白鍵播放與快速鍵不再被專案名稱欄攔截。
- **Affected Files**：`work/studio/resources/breezyvoice_tts.py`, `work/studio/build-app.sh`, `work/studio/src/VoiceboxIntegration.swift`, `work/studio/src/PortabilitySetupViews.swift`, `work/studio/src/MultitrackViews.swift`, `work/studio/src/ProStudioPanels.swift`, `work/studio/src/Studio.swift`, `work/studio/Info.plist`

---

## v1.1.1 — 2026-11-24 19:36 (UTC+8)
### Edits-Style 6-Tab Settings, Unified Capsule UI, Antigravity No-API Image Gen & Taiwan Breeze-ASR-26 Subtitles / 極簡雙欄設定頁、全站膠囊 R 角統一、Antigravity 免 API 生圖與台灣 Breeze-ASR-26 自動字幕
- **全新 6 分頁雙欄極簡設定頁（比照 Edits 設計語言）**：
  - 取消頂部佔位狀態卡與長捲動，改為左側 6 分頁導覽列（`一般` / `本機引擎` / `雲端與 API` / `AI 代理與自動化` / `模型與快取` / `元件與關於`，帶精巧狀態圓點）＋ 右側低噪 `14pt` 分組卡片與低調深灰 `儲存` 膠囊按鈕。
  - **「AI 代理與自動化」分頁**：內建漸進顯示的 `Enable Automation Server`（MCP）預留設定卡片（開啟後展開 `Port` / `Endpoint` / `Access token` 與 `Claude Code` / `Codex` / `Antigravity` 一鍵複製設定）。
- **全站 R 角統一（`Capsule()` 圓潤膠囊按鈕、下拉選單與分段開關）**：
  - 於 `StudioTheme.swift` 建立統一設計規範 `StudioTheme.Radius`（卡片 `14pt`、輸入框／內嵌槽 `10pt`）與自訂 **`KliporaPillButtonStyle`、`KliporaSegmentedControl`、`KliporaPillMenuPicker`**，將主工作台與設定頁全面統一為圓潤膠囊風格。
- **本機模型管理升級（圖片＋語音對稱體驗）**：
  - 設定頁 **ComfyUI 卡片**與「模型與快取」分頁新增 **`管理圖片模型`** 直達入口。
  - 設定頁 **本機語音引擎** 支援直接點擊 **`未下載`** 的 Qwen3-TTS 模型從 HuggingFace 背景下載（含即時進度條），並新增對稱的 **`本機語音模型管理`（`LocalVoiceModelManagerSheet`）** 視窗（支援一鍵下載與移除釋放空間）。
- **免 API 直連生圖（Antigravity `agy`）＋ 來源選單淨化 ＋ 風格預設修正**：
  - 偵測到本機 `Gemini.app` 內建 `agy` CLI 時，自動解鎖 **`桌面 Agent · Antigravity（免 API）`** 圖片來源（免 API Key、支援多圖參考、生成完自動入庫）。
  - 未設定 OpenAI / Gemini API Key 時，這兩項自動從 `來源` 選單退場；來源未就緒時自動隱藏下方無效提示詞與參數區。
  - 左側素材庫新增 **`貼上圖片`** 膠囊按鈕（一鍵從剪貼簿匯入 ChatGPT / Gemini 複製的圖片）與外部桌面 AI 快捷選單。
  - 「風格」選單預設改為 **`不套用風格`**，不再自動附加紀實風格英文詞干擾提示詞。
- **接入台灣語音自動字幕引擎 `MediaTek-Research/Breeze-ASR-26`（INT8 / Apache-2.0）**：
  - 於 `audio_ai.py` 與剪輯工作區 **AI 工具** 接入聯發創新基地開源的 **`Breeze-ASR-26`**（專為台灣台語與國／台／英夾雜日常對話優化，直接輸出繁體漢字字幕並匯入多軌 T 軌與 `.srt`），支援一鍵安裝、移除與與 Faster-Whisper Base 並存切換。
- **Affected Files**：`work/studio/src/StudioTheme.swift`, `work/studio/src/Studio.swift`, `work/studio/src/PortabilitySetupViews.swift`, `work/studio/src/OnlineImageService.swift`, `work/studio/src/GenerationDockViews.swift`, `work/studio/src/LocalModelManager.swift`, `work/studio/src/CustomWorkflow.swift`, `work/studio/src/MografySkillIntegration.swift`, `work/studio/src/ModelProfileViews.swift`, `work/studio/src/ProStudioPanels.swift`, `work/studio/resources/worker.py`, `work/studio/resources/audio_ai.py`, `work/studio/Info.plist`

---

## v1.1.0 — 2026-11-23 22:32 (UTC+8)
### UI Layout Polish, Online Controls Cleanup & Desktop App Quick-Launch / 介面排版優化、線上設定欄淨化與桌面程式快捷啟動
- **「元件與連線設定」上方 1~4 狀態卡改為單排 4 欄顯示**：
  - 修正 `PortabilitySetupViews.swift` 中「1. 執行環境 / 2. 雲端登入與 API / 3. 模型快取 / 4. 服務連線」原本第 4 張卡片會折行落到第二排的問題，改為固定 4 欄等寬橫排，畫面更緊湊對齊。
- **切換至線上來源時自動隱藏「本機 ComfyUI 參數」面板**：
  - 修正 `Studio.swift` 判斷條件（由 `app.source != "colab"` 修正為 `app.source == "zimage"`），切換為 **線上 OpenAI / Gemini / Colab** 時右側不再誤顯示本機 ComfyUI 步數／CFG／Sampler 設定欄。
- **線上圖片設定面板（`OnlineImageService.swift`）文案與排版優化 ＋ 桌面版快捷啟動**：
  - 更新過時提示文案，同步反映 `v1.0.9` 已支援的多參考圖（最多 8 張）功能。
  - 修正「品質 / 解析度」標籤斷行擠壓問題（改為單行不換行標籤＋清爽分段控制）。
  - 自動偵測本機是否已安裝 **`ChatGPT.app`** 或 **`Gemini.app`**，於官方入口卡片直接顯示「**開啟 ChatGPT 桌面版** / **開啟 Gemini 桌面版**」一鍵啟動按鈕（不讀取或竊取任何第三方登入狀態）。
- **Affected Files**：`work/studio/src/PortabilitySetupViews.swift`, `work/studio/src/Studio.swift`, `work/studio/src/OnlineImageService.swift`, `work/studio/Info.plist`

---

## v1.0.9 — 2026-11-23 21:15 (UTC+8)
### Unified Multi-Reference Board UI & Online Multi-Image API Support / 統一中央下方參考素材板與線上多圖原生支援
- **解鎖線上圖片（OpenAI & Gemini）原生多參考圖輸入（最多 8 張）**：
  - `online_image.py` 升級 OpenAI 圖片 API 於附帶參考圖時自動走官方 `/v1/images/edits`（`multipart/form-data` 多張 `image[]`），Gemini Interactions API 自動送出多模態 `input` 圖文陣列，並自動附上 `@圖片1（角色）／@圖片2（場景）` 對照說明。
  - 維持原本所有安全與計費防線（固定官方 HTTPS 主機、阻擋重導向、金鑰遮蔽、離線停用）。
- **全新統一中央下方「參考素材板（`GenerationImageReferenceDock`）」＋ 右側欄瘦身優化**：
  - 將原本擠在右側窄欄的圖片參考素材統一移至中央預覽區下方橫向 Dock（與影片序列 Dock 視覺一致），徹底清爽右側參數欄。
  - 支援從左側素材庫或 Finder 一次拖放多張圖片（如多位角色三視圖、場景、物品），每張卡片可自由切換用途標籤（**`角色` / `場景` / `物品` / `風格`**），點一下卡片上的 **`@圖片N`** 膠囊即可直接插入提示詞框！
- **Affected Files**：`work/studio/resources/online_image.py`, `work/studio/resources/worker.py`, `work/studio/src/GenerationDockViews.swift`, `work/studio/src/Studio.swift`, `work/studio/Info.plist`

---

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
