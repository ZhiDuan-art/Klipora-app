# 外掛執行與來源

## 依賴與登入

需要本機命令執行能力、uv、Python 3.12、google-colab-cli 0.7.4。雲端生成使用 Google Colab 的運算單元。沿用目前有效的 Colab 登入；只有缺少或失效時重新登入。
安裝外掛不會自動申購訂閱或開啟 GPU。Google AI 付費方案權益依地區、方案與實際帳號為準；不要保證每月 400 點。以 `h3run.py check` 的帳號點數為準。

登入使用 google-colab-cli 的 OAuth 設定，會要求 openid、個人資料、email、cloud-platform、colaboratory、drive.file scopes。登入由使用者在 Google 網頁完成。token 與待完成登入狀態留在本機 `~/.config/colab-cli/`；GPU 狀態放 `~/.config/h3skill/`。
生成時會將該批 manifest 與指定素材上傳至使用者自己的 Colab runtime；ComfyUI、節點及模型在遠端下載。成果下載回工作區，結束時依設定釋放 runtime。外掛包不包含憑證、模型、個人素材或測試成果。

## 查詢停滯的恢復流程

若本機 `h3run.py` 查詢進度停滯，先用短的 `colab exec -s SESSION -f CHECK_SCRIPT --timeout 30` 讀取 `/content/h3job/status.json`。確認 `done: true`、`error: null`，且每項 job 為 `done`，再用 `colab download -s SESSION /content/h3job/out/FILE LOCAL_PATH` 下載缺少成果，核對 status 的 bytes。保存完整遠端狀態，依使用者設定關閉該 session，再終止卡住的本機查詢程序。不可為了恢復進度而重複生成或停止其他 session。最後 `h3run.py sessions` 確認資源狀態。

## 來源

上游：https://github.com/dseditor/h3-colab-skill
來源 commit：226905d2482f12a9d5a49d34458d7b741c7d0e1e
程式碼及文件依 MIT 授權，保留在外掛根目錄 LICENSE；模型另依各自授權。此私人封裝新增外掛描述、圖示、依賴安裝入口與使用者偏好，並保留原始執行腳本。
