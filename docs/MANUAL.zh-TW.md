# Niffler Manual

[English](MANUAL.md) · [简体中文](MANUAL.zh.md) · 繁體中文

執行、設定和復原 Niffler harness 所需的一切，另加隨附元件的參考章節。設計理由見
[research/REBOOT.md](research/REBOOT.md)；線協議見
[WIRE.md](WIRE.md)；core/元件邊界見
[ARCHITECTURE.md](ARCHITECTURE.md)；進行中的工作彙總在
[research/PLAN.md](research/PLAN.md)。

> 🤖 AI 自動翻譯，可能與英文版存在偏差；以 [English](MANUAL.md) 為準。
> 章節標題保留英文，以便跨文檔錨點保持有效。
> 本檔案於 2026-09-23 由英文版（docs/MANUAL.md）完整重新生成。

## Contents

- [Layout of a running system](#layout-of-a-running-system)
- [Store engines](#store-engines)
- [State and configuration](#state-and-configuration) · [Environment variables](#environment-variables) · [The `.env` file](#the-env-file)
- [The bus in one screen](#the-bus-in-one-screen) · [Approvals](#approvals)
- [Context window](#context-window) · [Self-extension and component lifecycle](#self-extension-and-component-lifecycle)
- [Component ecosystem (`plugins`)](#component-ecosystem-plugins) · [Skills](#skills)
- [Provider registry (`provider`)](#provider-registry-provider) · [Fetch](#fetch) · [`grep` in detail](#grep-in-detail)
- [External MCP servers (`mcp`)](#external-mcp-servers-mcp)
- [Language servers (`lsp`)](#language-servers-lsp) · [Repository inspection (`git`)](#repository-inspection-git) · [Background processes (`processes`)](#background-processes-processes)
- [Progressive tool discovery (`discover`/`invoke`)](#progressive-tool-discovery)
- [Model catalog (`models`)](#model-catalog-models)
- [System prompt (`systemprompt`)](#system-prompt-systemprompt)
- [Observation and logs (`observe`, `logfile`)](#observation-and-logs)
- [Hooks](#hooks)
- [Fabric and subagents](#fabric-and-subagents)
- [Expert advisory peer (`expert`)](#expert-advisory-peer-expert)
- [Advisory discovery (`jev`) and the Von launcher](#advisory-discovery-jev-and-the-von-launcher)
- [Recovery](#recovery) · [The store](#the-store) · [Testing](#testing)
- [Starting and stopping](#starting-and-stopping) · [Common tasks](#common-tasks) · [Troubleshooting](#troubleshooting)

## Layout of a running system

| 路徑 | 內容 |
|---|---|
| `core/` | 控制平面：系統載具（`niffler.nim`：匯流排啟動、監督器、目錄、派送）＋會話執行器（`session.nim`）及其驅動的回合迴圈（`conversation.nim` — 最大的模組 — 加上 `compaction.nim`、`approval.nim`、`retry.nim`、`uireg.nim`、`tty.nim`） |
| `components/` | 隨附的元件原始碼 — 每個元件一個目錄（Nim、Go、TypeScript 及一個 bash 示範）；清單即下方的[隨附元件](#shipped-components)表，這是必須保持最新的部分。有兩個目錄不是匯流排公民：`components/nats` 建置 `var/bin/nats-server`，當匯流排必須啟動時由 core 生成；`components/ctxtest` 是巢狀呼叫測試（`t_fabric`、`t_agent`）為自己編譯的測試夾具 |
| `sdk/` | Nim SDK（`sdk/niffler`）＋`sdk/go`（Go）＋`sdk/ts`（TypeScript/Node.js，npm 套件 `niffler-sdk`）；`sdk/envelope.nim` 中的信封是產物 |
| `docs/` | 本手冊、線路規格（`WIRE.md`）、設定設計（`research/SETTINGS.md`）、core 邊界理由（`ARCHITECTURE.md`）、fabric 使用者指南（`FABRIC_GUIDE.md`）、待辦工作（`research/PLAN.md`）及 `research/`（設計歷史） |
| `manifest.yaml` | 啟動 manifest：core 生成哪些元件、重啟原則，以及選用的無狀態 `replicas` 數量；`--minimal` 將其篩選為 `store`、`bash` 和 `llm` |
| `var/` | **執行時狀態，gitignored，可丟棄** — 儲存庫是快照 |
| `var/bin/` | 建置的二進位檔（系統 core ＋會話執行器＋元件），加上 `builder.build` 編譯的一切 — 代理建置的元件也落在此處，與系統元件並列。由 `make build` 重建 |
| `var/store.db` | SQLite 儲存的資料檔（預設引擎）— **單一寫入者**：恰好一個 `store` 程序可以開啟它。較舊、未遷移的載具仍使用 `var/barrel-db`；已遷移的根目錄會讓該檔案原封不動地留在 `var/store.db` 旁。每個引擎鎖定自己的檔案 — `var/store.db.lock`、`var/barrel-db.lock` |
| `var/nats-url` | 最後生成的匯流排的匯流排位址；UI 橋接讀取它以找到 core |
| `var/nats-monitor-url` | 當 core 生成匯流排時的 HTTP 監控端點；對於重用/遠端匯流排則不存在 |
| `var/logs/`、`var/captures/` | 輪替的結構化日誌和明確的 observe 探針匯出（見[觀察與日誌](#observation-and-logs)） |
| `var/toolout/` | `bash` 溢出檔案（`<session>/<pid>-<epoch>-<counter>.out`），當命令的輸出超過內嵌上限時寫入 — `read` 可以分頁瀏覽的絕對路徑；1 小時後清掃，因此舊回合的路徑可能已不存在 |
| `var/approval-sources/`、`var/mcp-results/`、`var/review-receipts/`、`var/fabric-cache/`、`var/plugins/` | 核准提示負載、MCP 橋接結果、`review_receipt` 指紋、已編譯的 fabric 程式和已安裝的外掛複製 — 全部可丟棄 |
| `var/models/`、`var/processes/`、`var/repomap-tags/`、`var/fetch/` | 元件狀態：models.dev 目錄快取、背景程序記錄、repomap 標籤快取、溢出的 fetch 主體 |
| `var/nats-pid` | 生成的匯流排 core 的 pid（僅用於崩潰清理 — 執行中的 core 在退出時停止自己的匯流排） |
| `var/build/` | 代理建置元件的原始碼檔案（builder 的暫存目錄）：Nim 為一個 `<name>.nim`，Go 和 TypeScript 為整個專案目錄（`go.mod`、`package.json`/`tsconfig.json`、`node_modules/`、`dist/`）。它是代理建置元件原始碼的**唯一**副本 — 持久化的 `component` 記錄不攜帶任何原始碼，因此 `make clean` 會使其成為孤兒 |
| `nimcache/` | 建置產物；`make clean` 移除它們（連同 `var/`） |

### Shipped components

| Component | Language | Manifest | What it does |
|---|---|---|---|
| `store` | Nim/Go | required | 匯流排上的文件儲存（`put/get/list/search/del`，基於 rev 的並行控制）。全部五個工具都是隨需的，且 `del` 額外被隱藏 — core 刪除記錄，模型不能。引擎以相同名稱註冊相同的五個工具（`put`/`get`/`list`/`search`/`del`；barrel 引擎額外註冊一個隱藏的 `selftest` — `/doctor` 展開的那個 — Go 引擎不實作）：`store-sqlite`（Go，SQLite ＋ goose 遷移，`var/store.db`）是**預設**；`barrel`（`var/bin/store`）和 `tidb` 仍可透過 `NIF_STORE_BACKEND` 選擇 — 見[儲存引擎](#store-engines) |
| `bash` | Nim | required | 經典工具：帶逾時＋輸出上限的 shell 命令。命令作為其自身程序群組的領導者執行，因此逾時或取消的回合會殺死整棵樹（退出碼 124 / 130）— 沒有孤兒子程序。結果攜帶 `text`（一個 `(exit N)` 狀態行 — 非零 = 失敗；124 = 逾時，130 = 已取消，126 = cwd 無法進入（該工具也使用 126 表示找到但不可執行），127 = `bash` 不在 `PATH` 上，128 ＋信號表示命令殺死了自己（139 = SIGSEGV，143 = SIGTERM）— 後接合併的 stdout/stderr；這是 LLM 對話記錄顯示的內容）加上機器欄位 `exit_code`、`cancelled`，以及當過大輸出溢出到 `var/toolout/` 下的檔案時的 `spill {path, bytes, lines}`（絕對路徑在 `spill.path` 中；可用 `read` 分頁，1 小時後清掃）。`run_in_background: true` 將長時間執行的命令（伺服器、監看器）交給 `processes` 元件而非阻塞 — 見[背景程序](#background-processes-processes) |
| `repomap` | Nim | optional | 排序的工作區地圖（docs/research/REPOMAP.md）：約 1KB 的關鍵檔案及其關鍵定義，由 tree-sitter ＋原生 Nim 標籤圖與個人化 PageRank 建構（aider repomap 移植）。`repo_map {workspace?, focus?, mentionedIdents?, budget?}` 是 onDemand 且為讀取效應。工作區開啟自動附加（在 `ev.workspace.opened` 上的一個僅附加歷史條目）**預設開啟但受閘控**（`docs/research/REPOMAP-GATES.md`）：工作區必須至少有 50 個涵蓋檔案，且其渲染的地圖必須至少有 800 位元組、25 個符號和 5 個帶符號的檔案。小型/殘缺的地圖會被扣留並記錄為 `repo map withheld`；設定 `NIF_REPOMAP_AUTOAPPEND=0` 以停用附加。明確的 `repo_map` 工具無論這些閘門如何都可用。快取：`var/repomap-tags/`（以 mtime 為鍵）。選用元件 — 不存在意味著沒有地圖，其他一切不變。參數、標籤層級和附加負載：[`repomap` 詳解](#repomap-in-detail) |
| `processes` | Nim | optional | 帶有擁有者的長時間執行命令：`process_start`（分離，自有程序群組，立即返回一個 id）、`process_poll`（排空增量輸出）、`process_kill`（停止群組）、`process_list` — 見[背景程序](#background-processes-processes) |
| `builder` | Nim | required | 使用 `build {lang, name, source, files?, defines?}` 編譯代理撰寫的 Nim/Go/TypeScript 原始碼，並使用 `build_package {name, lang, sourceRoot, project, steps, artifact}` 建置 manifest-v2 外掛專案（受核准閘控，隨需）。套件專案保留自己的依賴 manifest 和鎖定檔；builder 暫存它們，僅展開受控的 SDK/輸出佔位符，執行有界的 argv 配方，驗證宣告的 `executable`/`node` 產物，並返回已發佈的二進位檔/執行時套件。配方可以組合工具鏈（例如 `npm ci` 後接 `wails build`）；配方使用有界的 argv 工具集，不能呼叫 shell 包裝器。`info` 返回 SDK 路徑、全域工具命名規則，以及兩種建置流程 |
| `llm` | Go | required | 串流聊天轉接器 — 三個隱藏工具，都不在會話的直接集合中：`chat`（一次推論，`ev.llm.token` 增量，取消；`runner` 豁免，逾時 `NIF_LLM_TIMEOUT_MS`）、`llm_resolve`（客戶端呼叫的無憑證解析探針）和 `llm_models_source`（`models` 目錄呼叫的 `x-models-source` v1 即時 id 來源）— 協定：OpenAI 相容的 Chat Completions、OpenAI Codex（ChatGPT OAuth）Responses 和 Anthropic Messages；`components/llm-openai` 中的 `llm-openai` 是最小非串流範例（它只讀取 `NIF_OPENAI_API_KEY`、`NIF_OPENAI_BASE_URL`、`NIF_OPENAI_MODEL` 和 `NIF_OPENAI_CONTEXT` — 不讀 `NIF_OPENAI_PROVIDER` — 且總是發送 `max_tokens: 32768`，一個沒有旋鈕的硬編碼值）；透過 `manifest.yaml` 換入它 — 在同一次編輯中將 `llm` 註解掉，因為 `chat` 是全域唯一的工具名稱，重複註冊會被拒絕；`make build` 無論如何都會建置 `var/bin/llm-openai`。除了聊天契約之外不要期望任何東西：沒有 `ev.llm.token` 串流，沒有取消，沒有 `finish_reason`，沒有 `llm_resolve`（core 對最後一個優雅降級） |
| `models` | Go | optional | models.dev 提供者/模型目錄、原子快取、嚴格解析，以及外掛修正/探索層（見[模型目錄](#model-catalog-models)） |
| `provider` | Go | optional | 儲存後端的 LLM 提供者註冊表：`provider_add`/`list`/`switch`/`active`/`remove`/`export`/`import`，訂閱 OAuth 登入（`provider_oauth_start`/`complete`/`cancel`），`ev.provider.switch` 通知 |
| `plugins` | Nim | optional | 生態系統前門：主題搜尋 ＋套件的安裝/更新/移除 |
| `skills` | Nim | optional | Agent Skills（SKILL.md）：探索、載入、資源存取、基於 git 的安裝/移除 |
| `fetch` | Nim | optional | 網頁內容擷取：http/https、HTML→文字擷取、帶檔案溢出的尺寸上限 |
| `edit` | Nim | optional | 檔案工具：`read`（規範的 `reads` 陣列 — 一次呼叫最多 12 個檔案/範圍（每項 2000 行、256 KB、每行 2 KB — 更長的行變成 `bash: sed -n …` 通知；每次呼叫總計 512000 位元組，剩餘部分報告為不會使批次失敗的每項錯誤），可分頁，單檔 `path` 語法糖；對超過 1000 行的檔案進行整檔讀取且其類型有語言伺服器時，改為返回 lsp 符號大綱 — 用 offset/limit 開窗，或用 `offset: 1` 無論如何整檔讀取，`NIF_READ_OUTLINE_LINES` 調整/停用 — 對本會話已完整讀取過且位元組完全相同的 ≥512 位元組檔案進行整檔重讀時，返回 `[unchanged] <path>: N bytes, M lines, digest <sha1>` 而非文字；`force: true`（或任何 offset/limit 視窗）強制重新傾印，且視窗讀取和小檔案總是重新傾印），`edit`（只改變*現有*文字檔 — 缺失路徑為 `E_NOT_FOUND`，空檔案為 `E_EMPTY`，兩者都指向 `write` 作為建立內容的方式；接受 `{old_string, new_string, replace_all?}` 對的 `edits[]` 陣列 — 沒有單獨的多重編輯工具 — 全部對照*原始*檔案匹配，檢查重疊和無變化，然後以一次原子重命名寫入；受保護的後備級聯是尾隨空白 → 縮排漂移 → unicode 標點 → 按 Levenshtein 相似度 ≥ 0.65 的區塊錨點 → 雙重轉義文字，且每一層仍必須恰好匹配一次；陳舊閘門位於匹配*之前* — 當會話最後觀察到的檔案摘要與磁碟不同（外部編輯，或讀取/寫入以來的 `bash` 變更），`edit` 以 `E_STALE` 拒絕而非匹配模型從未見過的文字：重新讀取並重做。無會話呼叫者（`cli`、其他元件）不被追蹤並跳過閘門），`write`（原子整檔：建立父目錄、跟隨符號連結、保留目標的權限、將負載上限設為 `NIF_WRITE_MAX_BYTES` = 900000），`undo_last_edit`（每檔單層 — 僅前一次編輯，不是堆疊 — 跨重啟持久化並以絕對路徑為鍵，精確還原內容、BOM 和行尾；當檔案在編輯後被修改或刪除時以 `E_UNDO_STALE` 拒絕，此時陳舊記錄被*丟棄*（重新讀取並向前編輯）；undo 記錄在檔案之前寫入，因此儲存失敗會以 `E_UNDO_UNAVAILABLE` 拒絕編輯而非失去還原能力；受核准閘控的變更）；錨定區塊移動位於 [niffler-hashline](https://github.com/gokr/niffler-hashline) 外掛中 |
| `lsp` | Nim | optional | 語言伺服器接縫：一個 `lsp` 工具 — `diagnostics`（無需測試執行的編譯器/lint 錯誤）、`documentSymbol`（檔案大綱：每個符號及其種類、名稱和一基位置）、`workspaceSymbol`（在伺服器索引上進行全儲存庫符號搜尋 — 模糊 `query`，跨檔案結果）、`goToDefinition`、`findReferences`、`goToImplementation`、`hover`、`warmup` — 加上 `lsp_servers`（列出合併的註冊表）和 `lsp_registry`（`add`/`remove` 一個條目，受核准閘控）— 在任何已配置的 stdio 語言伺服器上（預設為 gopls、nimtortoise、typescript-language-server、pyright、rust-analyzer、clangd、bash-language-server、jdtls、intelephense、solargraph、csharp-ls）。註冊表是資料（`$XDG_CONFIG_HOME/niffler-lsp/servers.json`）：新增語言是一個配置條目或代理可以自行進行的 `lsp_registry add` — 絕不是程式碼（AGENTS.md：語言無關的 core）。隨需工具 |
| `git` | Nim | optional | 唯讀儲存庫檢查：在固定 argv 上的 `git_status`/`git_diff`/`git_log`/`git_show`/`git_blame`（免核准；變更留在 bash 中）加上 `review_receipt` — 在 `var/review-receipts/` 下的本地 diff 指紋寫入/檢查對，用於推送前審查交接（絕不呼叫模型；當 diff 自收據以來已變更時檢查失敗）。隨需工具 — 工作者透過 `discover` ＋ `invoke` 到達它們，保持直接工具集精簡 |
| `agent` | Nim | optional | 子代理會話，九個工具：`agent_run`/`agent_spawn`（全新或延續的子項、背景工作、持久結算通知）加上 `agent_status`/`agent_wait`/`agent_stop`/`agent_steer`/`agent_ask`/`agent_notices`/`agent_list` — 見[Fabric 與子代理](#fabric-and-subagents) |
| `expert` | Nim | optional | 諮詢同儕：並行跟隨一個或多個會話，由 LLM 判斷，回合綁定的引導（見[專家諮詢同儕](#expert-advisory-peer-expert)） |
| `jev` | Nim | optional | 基於本機決策模型的建議式探索（docs/research/JEV-SPIKE.md）：`jev_recommend {task, query, kind: "tools"|"skills"}` 透過 `core.discover`/`skill_list` 取得全新候選清單，再詢問所設定的 System One 後端哪一項合適；`jev_suggest` 接受呼叫方提供的 1–24 項候選清單，`jev_decide` 提問原始類型化（`noul`/`choice`/`score`）問題。三者皆為隨需、讀取效應且**僅供建議** — 不授予任何權限、不載入 schema/技能、不呼叫任何東西；後端故障是失敗開放（fail-open）的結果，且機率值未經校準。僅限本機：`NIF_JEV_URL` 必須是回環 `/v1/systemone` 端點（不允許重導向）。後端（Von）由 `von` 啟動器啟動，或手動啟動 — 見[建議式探索（`jev`）與 Von 啟動器](#advisory-discovery-jev-and-the-von-launcher)。每回合的**影子**觀測預設開啟（`NIF_JEV_SHADOW=0` 關閉；`NIF_JEV_SHADOW_KIND`/`_SKILL_QUERY`/`_TOOL_QUERY` 可調整）並存入儲存 kind `jevshadow`，絕不進入會話；後端缺席時不寫任何記錄 — 一則警告，接著靜默冷卻 |
| `von` | Nim | **不在 manifest 中** | `jev` 背後 Von 決策執行時的受監督啟動器：由 `make build` 建置（`var/bin/von`），透過持久化的 `core.spawn` 記錄啟用（`make von-up`；`make von-down`/`core.remove` 停用），絕不自動啟動。以內核清理的子項（`setpriv --pdeathsig`）啟動 `var/jev-venv/bin/von`，會收養已在端點提供服務的 Von，並透過 `von_status` 回報 `starting`/`serving`/`absent`/`failed`。venv 缺失 = 一則警告加上誠實的 `absent` 狀態，於閒置接縫重新檢查（因此稍後的 `make install-jev` 會被發現）— 絕不崩潰循環。環境變數：`NIF_VON_BIN`、`NIF_VON_ARGS`、`NIF_VON_MODEL`、`NIF_VON_DEVICE`、`NIF_VON_HOST`、`NIF_VON_PORT`、`NIF_VON_POLL_MS`、`NIF_VON_BACKOFF_MAX_S` |
| `fabric` | Nim | optional | 可程式化工具呼叫：模型撰寫一個 Nim 程式來編排工具；只有其 `finish()` 值進入會話（見[Fabric 與子代理](#fabric-and-subagents)） |
| `grep` | Nim | optional (4 replicas) | ripgrep 後端的搜尋：`grep`（內容，path:line:match，直接，輸出有上限）和 `files`（排序列表，隨需）；感知 .gitignore，無需 shell 引號；無狀態佇列群組副本重疊同元件搜尋 — 參數、上限、退出碼和效應分類在 [`grep` 詳解](#grep-in-detail) |
| `systemprompt` | Nim | optional | 會話憲章：會話執行器每個會話從 `svc.systemprompt.call` 取得一次系統提示（見[系統提示（`systemprompt`）](#system-prompt-systemprompt)） |
| `compaction` | Nim | optional | 預設可替換的 `compaction_propose` 實作：驗證執行器擁有的分頁快照，選擇允許的切割，並返回結構化檢查點候選；只有執行器驗證並提交投影 — 該工具本身是 `hidden` ＋ `x-harness.runner: true`（讀取效應，120 秒），因此沒有模型見過它，只有執行器或其他元件呼叫它；當元件不存在或被殺死時，摘要關閉，確定性階梯（無損修剪，然後是有損後備層級）仍然執行 |
| `recall` | Nim | optional | 隨需的 `context_recall` 解析器，用於規範訊息、完整溢出文件和當前持久檢查點 — 加上 `mode: search`，對會話的整個規範歷史（包括被修剪/壓縮掉的消息）進行 grep |
| `cli` | Nim | — | 用於腳本/CI 的隨需匯流排驅動程式（`catalog`/`wait`/`call`/`install`）— 一個從不發佈 `reg.publish` 的純客戶端，因此它從不出現在 `catalog` 中，且 `cli wait cli` 永遠不可能成功 |
| `console` | Nim | — | 隨需匯流排檢視器（在 stdout 上渲染每個信封） |
| `observe` | Nim | optional | 有界的即時匯流排環、監聽/追蹤探針、安全擷取匯出和 NATS 監控（見[觀察與日誌](#observation-and-logs)）— 全部十二個工具都是隨需的，且沒有一個宣告 `x-harness.effect`，因此 fabric 批次主機將甚至 `observe_events`/`observe_logs` 排程為寫入 |
| `logfile` | Nim | optional | 輪替的 JSONL 接收器和有界的持久日誌搜尋（見[觀察與日誌](#observation-and-logs)）— 兩個工具都是隨需的，且兩者都不宣告 `x-harness.effect`，因此 fabric 批次主機將甚至 `logfile_search` 排程為寫入 |
| `hooks` | Nim | off by default | 當選定的匯流排事件觸發時執行操作者 shell 命令（僅觀察；stdin 上的 JSON，環境配置；見[掛鉤](#hooks)） |
| `mcp` | Go | optional | 外部 MCP 伺服器（Model Context Protocol）：儲存後端的註冊表（`mcp_servers`/`mcp_search`/`mcp_add`/`mcp_edit`/`mcp_remove`/`mcp_refresh`），每個伺服器一個受監督的橋接（子項是單獨的 `mcp-bridge` 二進位檔 — `var/bin/mcp-bridge`，由 `make build` 建置，路徑可用 `NIF_MCP_BRIDGE_BIN` 覆寫；它沒有 manifest 條目，且絕不手動啟動）；工具成為可透過 `discover` ＋ `invoke` 到達的普通目錄工具（見[外部 MCP 伺服器](#external-mcp-servers-mcp)） |
| `nats-server` | Go | **not in the manifest** | 匯流排本身作為一等元件：官方 `nats-server` main 的忠實重建（固定在 `components/nats/go.mod`），由 `make build` 建置到 `var/bin/nats-server`，core 優先於 PATH 安裝，因此不需要 NATS 先決條件。刻意*不是*匯流排元件 — core 在匯流排存在之前啟動它，它不註冊任何工具，且 `core.spawn` 無法啟動它。Niffler 新增一個旗標 `--max_payload <bytes>`（core 傳遞 8388608），並在 Linux 上設定 `PR_SET_PDEATHSIG` 使沒有孤兒匯流排比其載具活得更久。沒有什麼需要為它安裝：`make install-nats` 只是這麼說，而 `make doctor` 報告 `nats-server: OK` 或解釋它是從原始碼建置的 |
| `dialog` | bash | — | 完全以 bash 撰寫的示範元件 — nats CLI ＋ jq，無 SDK，無編譯步驟：`dialog_show` 彈出桌面對話框（zenity、notify-send 或日誌後備），`dialog_ask` 向使用者詢問是/否問題並返回答案（`dialog_show` → `{ok, shown: yes|no, via: zenity|notify|log, kind}` — `shown` 是後端的真實結果：失敗的對話框或日誌後備是 `no`，絕不是假的 `yes`；`dialog_ask` → `{ok, answer: yes|no|timeout|no-display}` — `timeout` 意味著有人有對話框並讓它失效，`no-display` 意味著沒有人能回答）。兩個工具都不受核准閘控或隨需，因此兩者都落入 `dialog` 啟動時開始的每個會話的直接工具集中，且沒有顯示器（`DISPLAY` 未設定或 zenity 缺失）時 `dialog_ask` 立即回答 `no-display` 而不詢問任何人。隨附於 `var/bin/dialog`（`make build`）但**不會自動啟動**；用 `spawn {name: "dialog", binary: ".../var/bin/dialog"}`（core 的工具）生成它。先決條件：nats CLI 和 `jq` 是硬性的 — 沒有任一者元件完全無法回答；`zenity`（或 `notify-send`）僅用於可見部分，且僅在 `DISPLAY` 已設定時。`make setup` 安裝全部三個，`make doctor` 檢查它們 |

`components/ctxtest/` 是每個元件一個目錄 = 一個隨附元件的例外：它是契約測試自己的夾具 — 一個 stub `chat` LLM 加上巢狀呼叫探針 — 測試自己編譯成註冊為 `ctxtest` 和 `ctxsink` 的二進位檔。它不在此表中，不在 `manifest.yaml` 中，且絕不由 `make build` 建置。

### `bash` in detail

上方的 bash 列是摘要；這是模型據以工作的契約。`bash {command, timeoutMs?, cwd?, run_in_background?}` 以全新程序群組的領導者身分執行 `bash -c <command>`（`$PATH` 解析，無覆寫），stderr 按到達順序合併到 stdout，子項繼承元件的環境（`NIF_ROOT`、`.env`、core 匯出的一切）和 stdin，且高於 stderr 的描述符在生成前關閉。每次呼叫全新 shell 意味著 `cd` 不持久；`cwd`（會話工作區）實現為 `cd -- <cwd> || exit $?`，因此缺失的工作區目錄會使呼叫失敗而非在別處執行。

兩個逾時容易混淆。參數（`timeoutMs`，預設 30 秒）界定*命令* — 逾時殺死整個程序群組並報告退出碼 124 — 而 schema 的 `x-harness.timeoutMs`（60 秒）界定*core* 等待回覆多久。因此命令可以合法地比派送預算活得更久：使用 `timeoutMs: 120000` 時呼叫者看到派送逾時，而非整齊的 124。

輸出由兩個編譯期常數界定且**沒有環境旋鈕** — 元件中唯一的 `getEnv` 是 `NIF_ROOT`，因此更大的對話記錄預算意味著重建它：最多擷取 2,000,000 位元組，且最多 12,000 位元組的對話記錄到達模型，保留頭部和尾部並將中間替換為
`[... truncated <omitted> of <total> bytes (capped at <max>) — <hint> ...]`，
其中提示告訴*模型*縮小命令或分頁溢出檔案，而非告訴人類提高設定。更大的擷取溢出到 `var/toolout/`（絕對路徑在 `spill.path` 中，1 小時後清掃）。當完全無法擷取任何東西時 — 未終止的 heredoc、不平衡的引號 — 對話記錄攜帶
`[no output captured — the command failed to parse or start; check quoting and
heredoc termination]` 而非裸退出碼。Heredoc 本身受支援：包含 `<<` 的命令被包裝使重定向從自己的行開始。

取消具有該列描述的相同形狀，額外一點：`cancel.bash` 僅在其時間戳的 **30 秒**內被遵守，且對*不同*會話的取消被暫存 — 該會話的下一個排隊請求變成合成的 `(exit 130 — cancelled by request)` **而不執行命令**。退出碼是工具的契約：124 逾時，130 已取消，126 cwd 無法進入，127 `PATH` 上沒有 `bash`，128 ＋信號表示殺死自己的命令。`bash` 不宣告 `x-harness.effect`，因此 fabric 批次主機將其分類為**寫入**並獨佔執行它，絕不在讀取並行上限內。

### `repomap` in detail

上方的 `repomap` 列是摘要。`repo_map` 工具是僅可探索的 — 不在會話的凍結直接集合中，可透過 `discover` ＋ `invoke` 到達 — 攜帶 `x-harness.effect: read` 且無需核准。合格的工作區在開啟時透過僅附加歷史接收一個地圖；更小或殘缺的工作區什麼都得不到，除非模型要求。`budget` 以 token 為單位，預設 1024，最多 4096。

`focus` 圍繞會話正在處理的檔案對圖進行排序 — 並省略它們自己的定義，因為它已經有它們 — 而 `mentionedIdents` 提升路徑或定義與任務命名的符號匹配的檔案。

標籤涵蓋範圍是兩層：Go、Python、TypeScript、JavaScript、C、C++、Rust 和 Ruby 用 tree-sitter（文法內嵌在 `components/repomap/csrc/` 下，每語言查詢在 `components/repomap/queries/` 下），以及 `.nim`/`.nims` 用原生 Nim 標籤器，因為 Nim 文法的生成解析器是 40 MB。這些層之外的副檔名不貢獻符號，因此無法標籤的語言的地圖是空的而非錯誤的。

餵給圖的人口普查走訪工作區一次，跳過隱藏目錄、`docs/`、`var/`、`logs/`、`vendor/`、`node_modules/`、建置輸出（`dist/`、`build/`、`target/`、`nimcache/`、…）和其他垃圾目錄，並在 5000 個檔案或 5 秒後停止。單次建置在工具的 120 秒信封內上限為 90 秒。因此僅文件或否則很小的工作區映射為空 — 附加路徑記錄 `repo map withheld`，且工具回答 `No map: …`。

**附加注入什麼。** 每個會話一則使用者角色訊息：一個方括號前言命名工作區並警告它是會話開始時拍攝的快照，然後是地圖。它進入普通的僅附加歷史 — 執行器在會話的下一個 LLM 請求之前將其折入，絕不進入凍結前綴 — 因此稍後的壓縮可能修剪掉它，且 `repo_map` 隨需重新建立它。元件將完成的地圖發佈到 `svc.session.<id>.map`（執行器的排空主體）；它然後進行的附加對觀察者可見為 `ev.session.<id>.map
{sessionId, workspace, bytes}`。

### `grep` in detail

上方的 `grep` 列是摘要。兩個工具都以固定 argv 執行 ripgrep — 模式作為 `--` 之後的參數傳遞，絕不通過 shell — 因此引號、反斜線和空格無需轉義，這是相對 `bash grep` 的可靠性優勢。`rg` 透過 `PATH` 解析；當它缺失時兩個工具都以退出碼 127 回答並附帶指向 `bash grep -rn` 的安裝提示。`.gitignore` 和隱藏/二進位檔案預設跳過，`hidden: true` 新增隱藏檔案而 `.gitignore` 仍適用，且 `glob` 縮小而不取消隱藏。`path` 在派送時相對於工作區，結果以絕對路徑返回。

`grep {pattern, path?, glob?, context? (≤50), case_insensitive?, hidden?,
max_results? (default 200), timeoutMs? (default 30000)}` 返回 `path:line:match`
行；`files {path?, glob?, hidden?, max_results? (default 500), timeoutMs?}`
返回排序的路徑。`max_results` 上限為 10000 行，文字上限為
32 KB（保留頭部和尾部，並附標記說明切掉了多少），且長於 300 欄的行被省略為 `[Omitted long matching line]`（rg 的 `--max-columns 300`）。`exit_code` 是契約：0 匹配，1 無（`[no
matches]`/`[no files]`），2 錯誤正則，124 逾時，127 rg 缺失。`grep`
宣告 `parallel: true` 而 `files` 不宣告，且兩者都不宣告
`x-harness.effect` — fabric 批次主機將兩者排程為寫入。四個
無狀態 manifest 副本透過一個佇列群組服務它們。

### Minimal boot profile (`--minimal`)

正常 manifest 是完整的、自我擴展的載具。對於最小有用的持久執行時，啟動：

```bash
./var/bin/niffler --minimal
```

這將 manifest 啟動集篩選為恰好三個服務元件：

- `store` — 會話/訊息持久化和元件記錄
- `bash` — 一個通用機器工具
- `llm` — OpenAI 相容的模型存取和串流

Core 和 NATS 仍然執行，且第一個會話啟動其正常的臨時
`var/bin/session <id>` 執行器。`builder`、`plugins`、`skills`、`fetch`、
`models`、`provider`、專用檔案工具和觀察/日誌不啟動。透過 `core.spawn` 建立的持久化元件刻意不還原，但它們的儲存記錄不被刪除；稍後的正常啟動還原它們。最小模式只是啟動設定檔，不是原則邊界 — 呼叫者仍可在執行期間使用 `core.spawn`。

因為 `provider` 和 `models` 都不存在，正常會話回合直接從 `NIF_OPENAI_API_KEY`、
`NIF_OPENAI_BASE_URL` 和 `NIF_OPENAI_MODEL` 解析後端。當確切的上下文視窗重要時設定 `NIF_OPENAI_CONTEXT`；否則 `llm` 使用其小型內建模型表然後是 128K 後備 — 但該表仍列出已停用的 `deepseek-chat`/`deepseek-reasoner` id，因此 `NIF_OPENAI_CONTEXT` 是當今 DeepSeek 上唯一正確的答案。

```bash
NIF_OPENAI_API_KEY=sk-... \
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1 \
NIF_OPENAI_MODEL=deepseek-chat \
NIF_OPENAI_CONTEXT=1000000 \
./var/bin/niffler --minimal
```

桌面 UI 的自動啟動使用正常設定檔。要將 UI 與最小設定檔一起使用，先啟動上述命令然後啟動 `niffler-ui`；它連接到現有的 core。`--minimal --recover` 也有效：復原先重建並清除生成的元件記錄，然後啟動三元件設定檔。這只是執行時選擇；`make build` 仍建置完整的隨附集。

### Session runners

一個會話 = 一個程序（`var/bin/session <sessionId>`），由系統載具隨需生成。客戶端持續呼叫 `svc.core.call`（工具 `session`）；系統確保每個會話 id 一個執行器並將回合轉發到 `svc.session.<sessionId>.call`。該轉發是非同步的 — core 的泵擁有收件匣 — 因此一個長回合不能阻塞另一個會話的執行器；就緒是執行器出現在目錄中，在生成後輪詢最多 10 秒。執行器是受監督的子項（重啟原則 `never`），且這是字面意義的：死掉的執行器不被重啟 — 下一個會話呼叫從儲存重新確保它，且屍體在等待中途被收割使替換立即生成。它宣告自己為元件 `session-<id>` 且零工具，啟動時從 `catalog {op: snapshot}` 播種其目錄，寫入會話標頭使會話在其第一則訊息之前可見，並發出與經典 core 內迴圈相同的 `ev.session.<id>.*` 事件。會話是臨時的：歷史存在儲存中，因此全新的執行器在下一次呼叫時恢復會話。`NIF_RUNNER_IDLE_S`（預設 600 秒）內沒有會話呼叫的執行器優雅退役並在下一次呼叫時重新建立；閒置時鐘在回合完成時蓋章，因此長回合算作活動而非閒置。殺死執行器只殺死該會話 — 程序是隔離單位。回合也絕不雙向巢狀。除了 `.call` 之外，執行器服務五個每會話主體，每個攜帶相同的會話 id：`.steer`（回合中引導）、`.advise`（專家建議，從閒置槽回答）、`.map`（repomap 自動附加）、`.diag`（由 `edit` 推送的非同步診斷）和 `.tool`（fabric 和子代理使用的巢狀會話呼叫代理）。

刪除會話是一個受閘控的 core 工具，對 LLM 隱藏：`conversation_delete` 先停止該會話的執行器（否則執行中的回合會復活記錄），然後移除標頭、訊息、凍結工具集、子代理血統和工作記錄。

stdin/stdout tty（`make run`）是**管理 shell**，不是會話 UI：它只檢查載具本身 — `help`、`status`、`catalog`、`tools`、`sessions`、`exit` — 帶有方向鍵歷史和 tab 補全（見 `core/tty.nim`）。LLM 聊天位於 `niffler-tui` 終端客戶端和網頁 UI 中；腳本透過 `cli` 元件進行。

### Clients and the UI registry

每個互動式前端在匯流排上註冊為零工具元件並保持租約存活：core 的隱藏 `ui` 工具 — `register`、`renew`、`release`、`owner`，加上用於每會話擁有權的 `claim`/`release_session` — 追蹤哪個視窗擁有哪個會話（名為 `ui` 的元件是桌面橋接，不是此工具）。租約持續 20 秒，且過期租約在每個請求上惰性清掃 — 不存在計時器執行緒。顯示編號（「Niffler 1」、「Niffler 2」）在載具的生命週期內單調遞增。這是協調，不是認證：它決定哪個視窗渲染會話，僅此而已。在 `/restart` 之後，繼任者從交接記錄（TTL 120 秒，以匯流排 ＋工作區為鍵）採用其前任的 ui id，因此會話及其「Niffler N」標籤存活。

### Store engines

儲存的**匯流排契約就是產物本身**：`put/get/list/search/del`、`expectRev` 樂觀並行控制、依 id 排序的清單（docs/WIRE.md）。多個引擎實作它，並以元件 `store` 註冊、提供完全相同的工具——消費者永遠不會知道哪個引擎正在運作。選擇是開機時的決定：`NIF_STORE_BACKEND=sqlite|barrel|tidb`（預設 `sqlite`）；core 據此解析 manifest 項目的二進位檔，並在遇到未知值時拒絕開機。未設定 `NIF_STORE_BACKEND` 是預設，不是要求：當 `var/bin/store-sqlite` 從未建置時，core 會警告並改為啟動 manifest 的二進位檔（`var/bin/store`，barrel）。明確的值則是要求——二進位檔缺失只會發出警告，絕不會被悄悄換成另一個引擎的資料庫。

**`search`** 是伺服器端過濾器（`{kind, query, limit?, after?}` —— 不下載整個種類，即可依 id/標題尋找對話、依內容尋找訊息；niffler-tui 的 `/session` 使用它）。語義在每個引擎中都是契約：依 kind 劃分的索引欄位（conversation = id + title，message = id + content 文字（單文件上限 16KB），其他 kind 僅 id）、每個查詢詞的不分大小寫**前綴**比對（AND），非字母數字字元一律無作用，因此使用者輸入無需跳脫；排序/游標/上限沿用 `list` 的規則。引擎只在應答方式上不同：**sqlite** 維護一個 FTS5 索引（`docs_fts`，rowid 與 `docs` 共享，與文件在同一個交易中維護；啟動時兩者不一致就從 `docs` 重建 —— 派生狀態，可安全丟棄），而 **barrel** 和 **tidb** 沒有索引，依 id 順序掃描該 kind 並套用相同的比對器（結果等價，每次呼叫 O(kind 中的文件數)）。

- **sqlite**（預設，`var/bin/store-sqlite`，Go）：在 SQLite 上實作同一份文件契約。文件以 JSON TEXT 原樣存放；`put` 是單一原子陳述式（doc 與 rev 一起移動——KV 引擎的雙鍵崩潰窗口不復存在）；schema 透過內嵌的 goose migration 管理；純 Go 驅動程式（`modernc.org/sqlite`，無 cgo）。資料檔 `var/store.db`（WAL），可用任何 SQLite 工具檢視（`sqlite3 var/store.db 'select kind, count(*) from docs group by kind'`），也可從 DuckDB 以唯讀方式掛載以進行離線分析。自 context compaction 落地後即為預設：context projection 需要原子寫入與可範圍讀取的清單（docs/research/COMPACTION.md §2）。SQLite pragma 是程式碼內建、不可配置（`_txlock=immediate`、WAL、`synchronous(NORMAL)`、10 秒 `busy_timeout`、單一連線池），且 goose migration 會在啟動時自動套用。
- **barrel**（`var/bin/store`）：內嵌的 BitBarrel KV（Bitcask 風格）位於 `var/barrel-db`——設計上無 schema、零依賴、久經考驗。仍完整支援（`NIF_STORE_BACKEND=barrel`）；其 `put` 是雙鍵序列（先 doc，再 rev）：兩者之間發生崩潰可能導致內容更新而修訂未更新，而對於*新*文件，doc 鍵會被寫入但完全沒有 rev 鍵，`get` 與 `list` 會將其讀為不存在（`rev == 0`）——該文件在再次寫入之前無法觸及。
- **tidb**（`var/bin/store-tidb`，Go）：透過 MySQL 協定（go-sql-driver）實作同一份 schema——一個網路共享的儲存，任何數量的 harness 都能從中提供服務。`NIF_STORE_TIDB_DSN` 指向叢集（`root@tcp(host:4000)/niffler`；單節點 docker：`docker run -p 4000:4000 pingcap/tidb`）。`value` 維持 MEDIUMTEXT，而非原生 JSON 型別——二進位 JSON 會正規化鍵順序與數字精度，破壞原樣文件契約；索引查詢日後會以 TEXT 上的生成欄位形式到來（一個 goose migration）。`kind`/`id` 為 utf8mb4_bin：位元組精確相等、位元組序清單排序，以及大小寫敏感的 LIKE 前綴（與其他引擎的契約對等）。無 flock——叢集依設計即為共享狀態；資料列鎖（`SELECT … FOR UPDATE`、悲觀式交易）仲裁寫入者，而 rev 計數器仍是樂觀並行控制的檢查。也可對純 MySQL 8 運作。DSN 使用者需要 goose 建立其版本表並套用 migration 所需的權限；連線/讀取/寫入逾時為硬編碼（5 秒 / 60 秒 / 30 秒），且引擎持有單一連線池連線（單一會話，因此 `FOR UPDATE` 交易的陳述式會保持在一起）——同一叢集上的 N 個 harness 持有 N 條連線，不共享連線池。

除了 root 與引擎選擇之外，引擎不接受任何配置：檔案路徑、鎖路徑、pragma、逾時與連線池大小皆為程式碼內建（`NIF_ROOT` 決定 root，`NIF_STORE_BACKEND` 決定引擎，`NIF_STORE_TIDB_DSN` 決定叢集）。

檔案型引擎（`sqlite`、`barrel`）以相同方式強制單一寫入者：一個行程擁有該檔案（flock；崩潰時由核心釋放），其他所有人以 envelope 溝通。`tidb` 沒有檔案可鎖——叢集依設計即為共享狀態，並由資料列鎖加上 rev 計數器在 harness 之間仲裁。

`list` 是**一頁**，不是完整檢視：`limit` 預設為 100，並被限制在 1000 以內，回覆帶有 `hasMore` 以及 `nextAfter` id 游標。將 `nextAfter` 作為 `after` 傳回以走完其餘部分——`after` 為排他性，而當 `hasMore` 為 false 時 `nextAfter` 不存在。儲存保留完整歷史，因此一段長對話無法容納於單次呼叫；core 自身的全 kind 讀取（resume、`session_info`、`conversation_delete`）會自動分頁。

儲存契約是對每個引擎執行同一套測試：`make test-store`（選定/預設引擎）、`make test-store-sqlite`、`make test-store-tidb`（需要 `NIF_STORE_TIDB_DSN`，否則印出 SKIP）；`t_store_paging` 釘住 resume 與 migration 所依賴的 `after`/`hasMore`/`nextAfter` 游標語意。

### Migrating between engines

**切換引擎不會搬移資料。** 升級後，歷史位於 `var/barrel-db` 的 harness 會拒絕開機，而不是開啟一個空的 `var/store.db` 並看起來像失去了每一段對話：

```
core: this harness has conversation history in var/barrel-db, but the
      default store engine is now SQLite and no var/store.db exists yet.
core: migrate first (nothing is moved automatically):
core:     niffler-store-migrate --root /path/to/harness
core: scan for other un-migrated roots (benchmarks, clones):
core:     niffler-store-migrate --scan
core: or keep using the old engine: NIF_STORE_BACKEND=barrel
```

`niffler-store-migrate`（位於 `var/bin`）以**離線**方式執行——它啟動自己私有的 NATS 伺服器與 store 行程，因此無需啟動任何 harness，且它絕不編輯來源資料。儲存契約無法列舉 kind（`list` 需要一個），因此它讀取**它所探查之 kind 的**每一份文件——這份候選清單是對 harness 今日所寫每一種 kind 的經驗證普查（`agentjob`、`agentnotice`、`approval`、`attachment`、`attachmentdata`、`compaction_input`、`component`、`context_projection`、`contextreceipt`、`conversation`、`fabricprog`、`mcp`、`message`、`plugin`、`profile`、`session`、`sessionmeta`、`slash`、`spill`）——而收尾驗證會逐 kind 走過它實際**搬運**的 kind，對照目標進行驗證。日後加入 harness 的 kind 仍會被悄悄略過，直到普查被擴充（匯流排無法看到它），這就是為什麼這份清單維護在 store 的 kind 表旁邊。
今日接上的方向是 barrel → `sqlite`（預設）或 barrel → `tidb` 搭配 `--to tidb`；純 SQLite 的 root 會被拒絕，並顯示「root already uses sqlite — nothing to migrate」。每份文件都會被重放到全新的目標，然後逐 kind 驗證。`attachmentdata` 一次分頁一份文件（一整頁中的 4 MB base64 負載會超過匯流排的 8 MiB 上限），而格式錯誤的 `list` 游標會中止遷移，而不是靜默截斷它。旗標（`--root`、`--to <engine>`、`--dry-run`、`--scan [<top>]`、`--all [<top>]`、`--force`）由工具自身的 `--help` 說明；`--force` 會覆蓋既有的目標資料庫（舊的會被移到一旁為 `<name>.<timestamp>.aside`），而每個階段背後的設計見 [research/STORE_V2.md](research/STORE_V2.md) 的「Moving data between engines」。

`--scan` 會尋找頂層目錄、同層複本與 benchmark 樹（`var/bench/**/niffler-root`）。Migration 會拒絕在同時持有 `var/barrel-db` 與 `var/store.db` 的 root 上執行——那是完成遷移後留下的狀態，重跑會失敗並顯示「ambiguous source; move one aside first」（將過時的 `var/store.db` 移到一旁即可重複執行）。回復就只是 `NIF_STORE_BACKEND=barrel`，因為 barrel 檔案未被觸碰；反方向的資料搬移——從 SQLite 或 TiDB 移出——尚未接上。

## State and configuration

Niffler 沒有單一設定檔。狀態分散於五個地方，依生命週期選擇：開機決定是環境，身分/選擇是儲存，每段對話的選擇是對話標頭，顯示是瀏覽器，而所有衍生的東西都在 `var/`（可重新產生——刪除它並執行 `make build` 加上一次開機即可重建整個世界）——**除了 agent 建置的元件**：`builder.build` 只將其原始碼保留在 `var/build/` 下、其二進位檔只保留在 `var/bin/` 下，而持久化的 `component` 記錄兩者皆不儲存，因此當那些輸出消失而儲存仍存活時，下次開機會警告 `stored component <name> has missing binary` 並略過它。用 `builder.build` + `core.spawn` 重建它，或用 `core.remove` 刪除該記錄。

| Where | What | Lifetime |
|---|---|---|
| **Environment / `.env`** | 所有 `NIF_*` 變數（下表）：開機與匯流排、LLM 連線、各元件調校。`.env`（root，gitignored）存放機密與本機覆寫；shell 環境優先；含預設值的參考副本在 `.env.example` | 行程生命週期——元件在開機時讀取環境一次，因此變更需要 `core.kill` + `core.spawn`。*在啟動 core 的 shell 中匯出*的變數會被每個子行程繼承，改為需要重啟 harness |
| **The store**（kind 表見 [The store](#the-store)） | 對話標頭、訊息、`provider` 註冊表（含憑證）、凍結的每對話工具集、slash 表、plugin/component 安裝記錄、subagent 工作/血統記錄、fabric 程式、MCP 伺服器配置 | 持久——harness 的資料庫 |
| **Conversation header**（`conversation` kind） | 每對話選擇：provider、providerOverride、model、modelOverride、thinking、profile、title、預算/token 計量——透過 `session` 呼叫設定（UI 中的 `/model`、`/effort`），並在回合結果中回顯 | 每對話 |
| **Home / project files** | skills 樹（專案 `.agents|.claude|.opencode/skills` > 內附 `skills/` > home `~/.niffler/skills` + agent 標準目錄 > `~/.config/opencode/skills`，然後是最後手段、編譯進二進位檔的樹）；LSP 註冊表 `~/.config/niffler-lsp/servers.json`（`NIF_LSP_REGISTRY`） | 持久，使用者可編輯 |
| **Home files（edit undo store）** | `$XDG_CONFIG_HOME/niffler-edit/undo.json`（否則 `~/.config/niffler-edit/undo.json`）：每個檔案最後的編輯前位元組，加上每對話的已見狀態摘要。每個被編輯的檔案一筆記錄，無大小上限、無淘汰——它隨被編輯的不同檔案數量成長，且隨時可安全刪除（刪除它只會失去 undo 歷史與未變更讀取 stub，絕不會失去檔案內容） | 持久，使用者可編輯 |
| **`var/`**（gitignored） | `bin/` 建置的二進位檔、`logs/` 匯流排 JSONL 與各元件 JSONL（`.1`…`.N` 輪替）加上子行程日誌、`models/` 目錄快取、`nats-url`/`nats-pid` 匯流排認領、`processes/` spool（每次啟動的 `pN.out`/`pN.err`，開機時清空；id 從持久化計數器繼續，而非從 `p1` 重新開始）、`repomap-tags/` 每檔案標籤快取（以絕對路徑的 sha1 為鍵的 `{mtime, tags}` JSON；空結果永不快取）、`fetch/`、`captures/`、`store.db`（SQLite 引擎的檔案）或 `barrel-db`（barrel 引擎的）——取決於 `NIF_STORE_BACKEND` 選了哪個——加上其 `.lock`，同一時間只能由一個 `store` 行程持有 | 執行時，可重新產生 |
| **Browser localStorage** | 僅顯示：reasoning/工具卡詳細程度、locale（`niffler-think`、`niffler-tools`） | 每瀏覽器 |
| **Repo files** | `manifest.yaml`（隨附的元件註冊表）、`skills/`（內附 skills）、建置檔（`config.nims`、`*.nimble`、`Makefile`） | 版本化 |

值得知道的優先順序規則：shell 環境勝過 `.env`；作用中的 `provider` 勝過 `NIF_OPENAI_*`；對話凍結的工具集快照勝過即時目錄（這正是讓 resume 位元組穩定的原因）；skill 樹的遮蔽順序為專案 > 內附 > home > config。`lsp` 元件另外將建置檔（`go.mod`/`go.work`、`tsconfig.json`/`package.json`、`*.nimble`/`config.nims`、`Cargo.toml`）視為 repo *標記*——是從哪裡開始走訪，而非它解析的配置，而 `repomap` 則將這類標記檔列為其地圖中的裸項目；`skills` 只使用固定目錄。

此表的環境變數部分，是候選要移入儲存、成為全域設定並搭配 `/settings` 指令的部分——其設計（優先順序 `conversation header > store settings > env > code default`、哪些鍵在第一階段移入、哪些永遠留在環境）見 `research/SETTINGS.md`。

## Environment variables

所有元件都會載入 `.env`（從 harness root 與 cwd，既有的 shell 環境永遠優先——見下文）並繼承 core 的環境。`NIF_BIN_DIR`、`NIF_BUILD_LOCK`、`NIF_STORE_BIN`、`NIF_REPO_ROOT` 與 `NIF_LSP_BIN` 是僅供建置與腳本使用的旋鈕（`NIF_NATS_CLI` 是例外——被啟動的 bash 元件 `dialog` 將它讀作最後手段的 nats CLI）：它們引導 `make` 與 `scripts/`，且絕不會被隨附的元件查詢——僅供測試的 `ctxtest` fixture 會讀取 `NIF_REPO_ROOT` 以載入 fabric 範例——因此它們不屬於下表的執行時部分。`NIF_LSP_BIN` 在那裡仍有一列：它是 `make install-lsp` 的目標目錄，其預設值（`~/.local/bin`）也是 `lsp` 元件會搜尋的。完整集合：

| Variable | Meaning | Default |
|---|---|---|
| `NIF_ROOT` | harness root（repo）。core 在未設定時從其二進位檔位置推導，並為所有子行程設定它。元件用它來尋找 SDK、`var/`、`.env`。每個元件都以 **cwd = NIF_ROOT** 執行，因此 agent 的 `bash pwd` 永遠是 home——無論你從何處啟動 harness | `<binary location>/../..` |
| `NIF_NATS_URL` | 匯流排位址。在**環境**中（測試、bench、腳本）：僅附加——core 使用恰好那個匯流排。宣告於 **`.env`**（或眾所周知的 `nats://127.0.0.1:4222`）：複本的 **home 匯流排**——空閒時認領，僅在回應的 core 服務此 root 時附加（身分透過目錄的 `root` 欄位），大聲讓給外來 core 或裸 nats-server（改用隔離的隨機匯流排；會先回收記錄下來的殘留 `var/nats-pid`），並寫入 `var/nats-url` | auto |
| `NIF_NATS_SPAWN` | `1` 強制在隨機埠上使用隔離的 core 自有匯流排——絕不是 4222，絕不附加（開發複本與測試）。搭配明確的 `NIF_NATS_URL` 時 URL 優先 | unset |
| `NIF_AUTOSTART` | 當 UI 必須啟動 core 時由 SDK 的 `ensureHarness` 設定：該 core 在最後一個互動式客戶端離開時結束（見 Starting and stopping） | unset |
| `NIF_AUTOSTART_IDLE_S` | 最後一個互動式客戶端離開後，自動啟動的 core 結束前的秒數 | `10` |
| `NIF_AUTOSTART_BOOT_S` | 自動啟動的 core 在放棄前等待其第一個互動式客戶端的秒數 | `60` |
| `NIF_ENSURE_ATTACH` | `0` 讓 `ensureHarness` 略過附加並總是啟動一個 core（測試） | `1` |
| `NIF_STORE_BACKEND` | 開機時選定的儲存引擎：`sqlite`（預設 → `var/bin/store-sqlite`）、`barrel`（→ `var/bin/store`）、`tidb`（→ `var/bin/store-tidb`）；其他任何值都拒絕開機。所有引擎都以元件 `store` 註冊、提供完全相同的工具——見 [Store engines](#store-engines)。未遷移的 barrel（歷史在 `var/barrel-db`，尚無 `var/store.db`）會讓 core 拒絕開機並附上 `niffler-store-migrate` 指示；此處的 `barrel` 是逃生口。**未設定**值而其引擎二進位檔缺失（`var/bin/store-sqlite` 不存在）時會警告並退回 `var/bin/store`——明確的要求絕不退回 | `sqlite` |
| `NIF_STORE_TIDB_DSN` | `tidb` 儲存引擎的 TiDB/MySQL DSN，例如 `root@tcp(127.0.0.1:4000)/niffler`（docker 單節點：`docker run -p 4000:4000 pingcap/tidb`）。該引擎必需——無本機預設；元件在沒有它時拒絕開機。除非 DSN 設定 `time_zone`，否則會話被強制為 UTC。帳號需要 goose 的 DDL migration 權限，於每次開機套用（全新資料庫，然後是每個新出貨的 migration）；連線/讀取/寫入逾時（5 秒/60 秒/30 秒）與單一連線池連線為程式碼內建，不可透過環境調校 | unset |
| `NIF_GIT_MIRROR` | 當 `plugins` 元件複製套件時取代 `https://github.com` 的主機前綴（例如 `https://cnb.cool` 或 Gitee 鏡像）——API/搜尋端點仍留在 GitHub | unset |
| `NIF_NPM_REGISTRY` | `builder` ts-component 安裝所用的 npm registry（例如 `https://registry.npmmirror.com`） | npm default |
| `NIF_OPENAI_API_KEY` | LLM 配接器（`llm`）的 API 金鑰。任何對話回合都需要；完全沒有金鑰時配接器會在任何 HTTP 請求之前拒絕（`provider "default": no API key (set NIF_OPENAI_API_KEY or NIF_LLM_PROVIDERS apiKey)`），這與金鑰存在但被拒絕（HTTP 401/403）是不同的症狀 | — |
| `NIF_OPENAI_BASE_URL` | OpenAI 相容端點 | `https://api.openai.com/v1` |
| `NIF_OPENAI_MODEL` | 模型名稱 | `deepseek-chat` |
| `NIF_OPENAI_PROVIDER` | 預設 LLM 連線的 models 目錄 provider id；未設定時會推斷常見端點 | inferred |
| `NIF_OPENAI_CONTEXT` | llm 向 core 的 context guard 報告的明確 context window（token）。解析順序：已儲存的 provider `context` → 此值 → `models` 目錄 → `llm` 的內建表（`deepseek-chat`/`deepseek-reasoner` 1M、`syn:large:text` 524288、`zai-org/glm-5.3-flash` 524288——程式碼內建，因此新模型需要改原始碼）→ 128000（`llm-openai` 替換範例只解析 `NIF_OPENAI_CONTEXT` → 兩項的 `deepseek-chat`/`deepseek-reasoner` 表 → `128000`，並在每次呼叫時重新讀取該變數） | `models` catalog, then the built-in table, then `128000` |
| `NIF_AGENT_MODEL_WEAK` / `NIF_AGENT_MODEL_MEDIUM` / `NIF_AGENT_MODEL_STRONG` | 當請求 `modelTier` 時，全新 subagent 使用的確切模型 id；子行程的 tier 會被限制在父行程配置的 tier | unset |
| `NIF_AGENT_DEFAULT_TIER` | 當父行程的確切模型不存在於配置的階梯中時使用的 tier 上限（`weak`、`medium` 或 `strong`） | `strong` |
| `NIF_AGENT_WAKES` | 當背景 subagent 在其閒置時落定後，一段對話可連續執行的自主喚醒回合數（docs/WIRE.md「Autonomous wake」）；人類的下一則訊息會重置預算，`0` 停用喚醒（通知則等待下一回合的 pull drain） | `3` |
| `NIF_AGENT_NOTICE_HOLD` | `0` 讓回合即使在其最後一步期間收到落定通知也能關閉（通知等待下一回合的 drain）；預設會讓回合多開一步，使其無法在剛完成的子行程之上關閉（docs/WIRE.md「Busy-parent inbox」） | `1` |
| `NIF_LLM_PROVIDERS` | 具名 provider 的 JSON 物件 `{nickname: {baseUrl, apiKey, model, context, catalog, protocol?, authType?, accountId?, stripPrefix?}}`，供 `chat` 工具的 `provider` 引數解析。`protocol` 為 `openai-chat`（預設）、`anthropic` 或 `openai-codex`；`authType` 預設為 `api_key`；`stripPrefix` 為依標準 id 路由的閘道改寫具命名空間的 id（`alibaba/glm-5.2` → `glm-5.2`）；`accountId` 是 Codex 通道標頭所帶的 ChatGPT 帳號 id，當記錄未持有時從 OAuth token 推導（兩者皆無時，呼叫失敗並顯示 `OpenAI Codex OAuth token has no ChatGPT account id; sign in again`）。格式錯誤的 JSON 與缺少 `apiKey` 各自會明確使呼叫失敗。provider 註冊表（`provider` 元件）作用中時會取代預設 | `{}` |
| `NIF_MODELS_URL` | models.dev 相容的目錄基底或 JSON 端點 | `https://models.dev/api.json` |
| `NIF_MODELS_PATH` | 釘選的本機基準目錄：設定時，此檔案*就是*基準——元件絕不下載 `NIF_MODELS_URL`（即使 `models_refresh {force: true}` 也不），並在下次重新整理時拾取該檔案的變更。Plugin 來源與 `NIF_MODELS_OVERRIDE` 仍會套用 | unset |
| `NIF_MODELS_OVERRIDE` | 在每個 plugin 來源之後套用的本機 JSON Merge Patch | unset |
| `NIF_MODELS_OFFLINE` | `1` 停止元件下載 models.dev；快取/種子基準與每個 plugin 來源仍會使用，來源工具仍會被呼叫。搭配 `NIF_MODELS_REFRESH_INTERVAL=0` 可得到完全靜態的目錄 | unset |
| `NIF_MODELS_CACHE_DIR` | 目錄與來源修補快取 | `$NIF_ROOT/var/models` |
| `NIF_MODELS_CACHE_TTL` | 重新抓取基準前的最短時間；`0` 停用快取窗口，因此每次重新整理都會重新抓取 | `5m` |
| `NIF_MODELS_REFRESH_INTERVAL` | 背景重新整理間隔；`0` 停用 | `1h` |
| `NIF_FETCH_DIR` | 大型 fetch 結果與暫存解壓縮檔 | `$NIF_ROOT/var/fetch` |
| `NIF_FETCH_ALLOW_PRIVATE` | `1`（也接受 `true`/`yes`）允許 `fetch` 工具連線 loopback/私有/link-local 目的地；僅用於受信任的本機開發服務 | unset (blocked) |
| `NIF_SKILLS_BUNDLED_DIR` | `skills` 元件內附樹的明確位置，取代 `<repo>/skills` 及其 `$NIF_ROOT/skills` 後備。不存在的路徑會讓探索改為提供編譯進去的副本（目錄 `(baked)`） | `<repo>/skills` |
| `NIF_MCP_DIRECT_THRESHOLD` | 配置為 `expose: direct` 的 MCP 伺服器可直接發布的快取工具數；更大的伺服器延後至漸進式探索 | `10` |
| `NIF_MCP_BRIDGE_BIN` | mcp-bridge 二進位檔的明確路徑 | `<root>/var/bin/mcp-bridge` |
| `NIF_PROCESSES_SPOOL_CAP` | `processes` spool 大小，超過時背景行程的輸出檔會在下次輪詢被截斷至其尾端——保留的尾端為 `min(2 MiB, cap div 2)`，且該值不經驗證，因此上限為零或以下會清空 spool | `33554432` |
| `NIF_PROCESSES_POLL_CHUNK` | 一次 `process_poll` 每串流回傳的最大新位元組數（保持在 spool 上限之下，因此突發總會被切分；限制在 1 KiB-1 MiB） | `65536` |
| `NIF_LSP_REGISTRY` | 語言伺服器使用者註冊表（`servers.json`）的絕對路徑 | `$XDG_CONFIG_HOME/niffler-lsp/servers.json` |
| `NIF_LSP_WARM_MAX` | 在 `ev.workspace.opened` 時每工作區預先啟動的重型（持有索引）語言伺服器數 | `2` |
| `NIF_LSP_WARM_CHEAP` | 從自身預算預先啟動的輕量（非索引）伺服器數——它們絕不會取代重型選擇 | `1` |
| `NIF_LSP_WARM_TOTAL` | 每工作區預先啟動行程的上限 | `4` |
| `NIF_LSP_BIN` | `make install-lsp` 使用的安裝目錄（伺服器包裝與使用者本機 JDK）；也作為預設後備 bin 目錄解析 | `~/.local/bin` |
| `NIF_LSP_BIN_DIRS` | 在 PATH 之外搜尋伺服器二進位檔的額外目錄（以冒號分隔；開頭的 `~` 表示你的 home 目錄） | — |
| `NIF_TRAFILATURA` | Trafilatura 執行檔路徑/名稱；`off` 停用外部擷取 | auto-detect `trafilatura` on `PATH` |
| `NIF_LOG_LEVEL` | SDK 結構化日誌發布閾值（`debug`、`info`、`warn`、`error`） | `info` |
| `NIF_RECONNECT_GRACE_S` | Nim 或 Go SDK 元件在匯流排不可達時容忍的秒數，超過後**重新接入**：重新解析 URL（`NIF_NATS_URL` → `$NIF_ROOT/var/nats-url` → 眾所周知的連接埠，因此在新連接埠上重啟的 core 也能被找到）、帶退避地重新撥號、重建每個訂閱並重新發佈 `reg.publish`。刻意高於 NATS 用戶端自身的重連預算（約 2 分鐘），因此更短的中斷絕不觸發它；不是正數的值會保留預設值。TypeScript SDK 目前尚不重新接入 | `180` |
| `NIF_LLM_MAX_RETRIES` | 對暫時性 LLM 失敗（429/5xx/超載/連線中斷）的額外嘗試次數，採指數退避；每次重試會宣告 `ev.session.<id>.retry`。驗證/配額/錯誤請求錯誤一律快速失敗 | `2` |
| `NIF_LLM_MAX_STREAM_RETRIES` | 串流回應中途中斷時的額外嘗試次數——與一般情況分開編列預算，因為中斷的串流可能已經計費輸出 | `2` |
| `NIF_LLM_MAX_CONNECT_RETRIES` | 連線/撥號失敗的額外嘗試次數 | `2` |
| `NIF_LLM_RETRY_AFTER_CAP_MS` | 伺服器 `retry-after` 提示所遵守的上限：`llm` 包裝 HTTP 客戶端、解析 `Retry-After`（秒數或 HTTP 日期），並在 provider 的錯誤後附加 `; retry-after-ms: <n>`，讓 core 能遵守等待，而無需每個配接器都依賴同一個客戶端程式庫；提示的等待長於此上限時會被限制，而無效或缺漏的標頭則讓錯誤保持原樣 | `3600000` |
| `NIF_LLM_TIMEOUT_MS` | 一次 `llm` `chat` 完成的時間上限；緩慢的推理模型（例如透過 llmgateway 的 GLM thinking=max）可能在單一回應上超過預設值 | `300000` |
| `NIF_CTX_RESERVE` | context 准入所保留的輸出 token；預設為模型解析出的目錄輸出上限，未知時為 `16384`；`0` 停用保留 | catalog output cap |
| `NIF_COMPACTION_TOOL` | runner 選定的 contract-v1 候選工具；空值停用摘要，但不影響 prune/trim/錯誤准入 | `compaction_propose` |
| `NIF_COMPACTION_TIMEOUT_MS` | 整個候選呼叫的期限，限制在 5000–600000 ms；runner 將它作為 dispatch 界限（`budget.timeoutMs`）傳遞，而候選工具自身的 `x-harness.timeoutMs` 是同樣的 600000 上限，因此最高到此限制的配置才是 runner 實際等待的（高於限制的值仍只會延長元件的輔助呼叫期限——runner 先放棄，而快照等待 600 秒的掃掠） | `90000` |
| `NIF_COMPACTION_MAX_LLM_CALLS` | 授予單次嘗試的輔助摘要呼叫預算，限制在 1–16；候選回報的呼叫數多於授予數時會被視為無效而拒絕，且授予數會縮放請求的 `maxTotalInputTokens`/`maxTotalOutputTokens`。隨附的 `compaction` 元件總是恰好進行一次輔助呼叫並回報 `llmCalls: 1`——此預算是給會迭代的摘要器用的 | `4` |
| `NIF_COMPACTION_MAX_SUMMARY_TOKENS` | 每次呼叫的 checkpoint 輸出上限，限制在 128–32768，且隨附元件以 128 為下限 | `4096` |
| `NIF_OBSERVE_RING` | observe 全域環中保留的訊息數；接受範圍 1–10000，超出時元件以非零值結束 | `2000` |
| `NIF_OBSERVE_RING_BYTES` | 全域環中保留的近似 wire 位元組數；接受範圍 65536–104857600 | `16777216` |
| `NIF_OBSERVE_ENTRY_BYTES` | 每則被觀察訊息保留的最大位元組數；接受範圍 1024–1048576，更大的訊息會以該上限四分之三的 base64 預覽保留 | `65536` |
| `NIF_OBSERVE_MAX_PROBES` | 同時保留的作用中 + 已停止 probe 數；接受範圍 1–256，到達上限時下一次 `observe_listen`/`observe_trace` 會失敗並顯示 `probe limit reached` | `32` |
| `NIF_OBSERVE_PROBE_BYTES` | 每個 probe 保留的位元組數；接受範圍 65536–16777216，項目依最舊優先淘汰，單一項目超過上限時計入 `dropped` | `2097152` |
| `NIF_OBSERVE_CAPTURE_DIR` | `observe_dump` 的受限目錄 | `$NIF_ROOT/var/captures` |
| `NIF_OBSERVE_CAPTURE_BYTES` | 產生的擷取檔總配額；最舊的檔案會被修剪。接受範圍 65536–1073741824，而當即使修剪也無法容納一次 dump 時，工具會失敗並顯示 `capture directory quota is exhausted` | `67108864` |
| `NIF_OBSERVE_MONITOR_URL` | 外部/重用匯流排的明確 nats-server HTTP 端點 | core discovery file |
| `NIF_LOGFILE_DIR` | JSONL 輸出目錄——絕對路徑按原樣使用，相對路徑對 harness root 解析 | `$NIF_ROOT/var/logs` |
| `NIF_LOGFILE_SUBJECTS` | 要持久化的逗號分隔 NATS 模式，於開機時驗證：格式錯誤或超過 512 位元組的模式、超過 64 個唯一模式，或空清單，都會讓元件以非零值結束 | `ev.log.>` |
| `NIF_LOGFILE_MAX_BYTES` | 每個 JSONL 檔輪替前的使用中位元組數；接受範圍 256–104857600，超出時元件以非零值結束 | `10485760` |
| `NIF_LOGFILE_KEEP` | 保留的輪替世代數（`0` 停用）；接受範圍 0–100，高於該值的世代會在每次開機時刪除 | `5` |
| `NIF_LOGFILE_MAX_FILES` | 回退至 `bus.jsonl` 前的元件專屬檔案數；接受範圍 1–1024，開機時已存在的 JSONL 檔也計入 | `64` |
| `NIF_LOGFILE_SCAN_BYTES` | 一次 `logfile_search` 檢查的最大位元組數，接受範圍 1024–104857600，並在該次搜尋的所有檔案間共享 | `16777216` |
| `NIF_LOGFILE_DIRECTORY_ENTRIES` | 每次查詢列舉的最大候選 JSONL 路徑數；接受範圍 100–100000，也適用於 `logfile_paths`，截斷會回報為 `directoryTruncated` | `10000` |
| `NIF_AUTO_APPROVE` | `1` → 略過核准閘門（見下文），且每個 `/limit` 是否繼續的問題都以是回答（它隱含 `NIF_AUTO_CONTINUE`）。僅供無介面自動化；絕不要在你重視的會話中設定它 | unset |
| `NIF_AUTO_CONTINUE` | `1` → 到達對話軟性限制（`/limit`）之一的回合會不詢問地繼續（`NIF_AUTO_APPROVE=1` 隱含它）。僅供無介面自動化 | unset |
| `NIF_MAX_TURN_ROUNDS` | 每回合的 LLM 回合硬上限；明確的每會話 `maxRounds` 可縮小它 | `1000` |
| `NIF_MAX_DIRECT_TOKENS` | 對話直接工具集用於 `invoke {sticky: true}` 提升的估計 token 上限；會超過它的提升會被延後並在工具結果中回報 | `4000` |
| `NIF_PROFILE` | 新對話的預設具名工具 profile，在 `session` 呼叫未帶 `profile` 引數時使用 | unset |
| `NIF_AGENT_MAX_DEPTH` | 限制 `agent_spawn` 委派可嵌套的深度（core 在 dispatch 時強制；agent 元件鏡像它）。`0` 禁止委派；到達上限時 spawn 工具仍可見 | `1` |
| `NIF_HOOKS_EVENTS` | hooks 元件監看的逗號分隔匯流排主體，支援 NATS 萬用字元（`*` 一個 token，結尾的 `>` 代表其餘）。於開機時讀取——配置變更是 `core.kill` + `core.spawn` | `ev.session.*.turn` |
| `NIF_HOOKS_<SUBJECT>` | 為一個受監看主體執行的 shell 命令（點與萬用字元變成 `_`，`*.` 與 `>.` 會收合：`ev.session.*.turn` → `NIF_HOOKS_EV_SESSION_TURN`、`ev.log.>` → `NIF_HOOKS_EV_LOG__`）；事件 payload 以 JSON 經 stdin 送入 | unset |
| `NIF_HOOKS_TIMEOUT_MS` | 每個 hook 的逾時，限制在 100–60000 ms；逾時會殺掉 hook 並記錄 exit 124 | `10000` |
| `NIF_MCP_REGISTRY_URL` | 外部 MCP 伺服器目錄的基底 URL（氣隙/代理設定） | `registry.modelcontextprotocol.io` |
| `NIF_MCP_PROBE_TIMEOUT_MS` | `mcp_add`/`mcp_edit` 中一次真實連線 probe 的逾時（bridge 自身的 `--probe` 模式也會讀取它，因此手動執行的 probe 會遵守它）：設定（正值）時它勝過 30 秒預設值與伺服器自身的 `timeoutMs` | `30000` |
| `NIF_READ_OUTLINE_LINES` | 整檔讀取的行數閾值，超過時 read 回傳語言伺服器符號大綱而非原始窗口；`0` 停用大綱 | `1000` |
| `NIF_REPOMAP_AUTOAPPEND` | 工作區開啟時的 repo-map 自動附加預設為開啟，仍受普查/內容准入閘門約束（`docs/research/REPOMAP-GATES.md`）。`0` 選擇退出；`1` 明確選擇加入。`repo_map` onDemand 工具不受影響 | `1` |
| `NIF_REPOMAP_MIN_CENSUS` | 附加的普查檔案下限：涵蓋來源檔少於此的工作區永不被映射（docs/research/REPOMAP-GATES.md）。閘門僅限附加——`repo_map` 永不受閘門約束，小地圖是對明確問題的好答案 | `50` |
| `NIF_REPOMAP_MIN_BYTES` | 附加內容閘門：渲染後地圖低於此位元組數即為 stub 並被保留不發。閘門僅限附加——`repo_map` 永不受閘門約束 | `800` |
| `NIF_REPOMAP_MIN_SYMBOLS` | 附加內容閘門：渲染後符號列下限。閘門僅限附加——`repo_map` 永不受閘門約束 | `25` |
| `NIF_REPOMAP_MIN_FILES` | 附加內容閘門：帶符號檔案下限。閘門僅限附加——`repo_map` 永不受閘門約束 | `5` |
| `NIF_RUNNER_IDLE_S` | 會話 runner 在此時間內沒有會話呼叫即退役；下一次呼叫會啟動全新的（subagent 子行程按需重新確保） | `600` |
| `NIF_JEV_URL` | `jev` 所詢問、實作 System One 契約的回環 HTTP 端點。必須是 `http`，主機為 `127.0.0.1`/`localhost`/`[::1]`，路徑恰為 `/v1/systemone`，無憑證/查詢/錨點且不允許重導向 — 決策輸入攜帶私有倉庫脈絡，因此遠端端點會被拒絕 | `http://127.0.0.1:8000/v1/systemone` |
| `NIF_JEV_BACKEND` / `NIF_JEV_MODEL` | 結果中回顯的後端標籤，以及傳送給該後端的模型 id | `von` / `von-1.1` |
| `NIF_JEV_SHADOW` | 每回合影子觀測：每次回合開始時 `jev` 排入最多兩個獨立判斷（已安裝技能；可透過任務衍生的詞法查詢發現的隨需工具），並記錄到儲存 kind `jevshadow` — 絕不向模型暴露任何內容。`0`/`false`/`no`/`off` 關閉。後端缺席時不寫記錄：一則 `ev.log.jev` 警告，接著靜默冷卻 | `1` |
| `NIF_JEV_SHADOW_KIND` / `NIF_JEV_SHADOW_SKILL_QUERY` / `NIF_JEV_SHADOW_TOOL_QUERY` | 要觀測的影子集合（`tools`、`skills`、`both`），以及覆寫任務衍生預設值的明確詞法查詢 | `both` / — / — |
| `NIF_VON_BIN` | `von` 啟動器要啟動的 Von 二進位檔路徑（缺失 = 一則警告 ＋ `absent` 狀態，於閒置接縫重新檢查） | `<root>/var/jev-venv/bin/von` |
| `NIF_VON_ARGS` | 子項的完整 argv，以空白拆分；覆寫內建的 `serve --model … --host … --port …` | `serve --model $NIF_VON_MODEL --host $NIF_VON_HOST --port $NIF_VON_PORT` |
| `NIF_VON_MODEL` / `NIF_VON_DEVICE` / `NIF_VON_HOST` / `NIF_VON_PORT` | 未設定 `NIF_VON_ARGS` 時啟動器建構的 serve 參數 | `von-1.1` / `cpu` / `127.0.0.1` / `8000` |
| `NIF_VON_POLL_MS` / `NIF_VON_BACKOFF_MAX_S` | 啟動器閒置間隔，以及子項退出後重啟退避的上限 | `1000` / `60` |
| `NIF_WRITE_MAX_BYTES` | `write` 工具整檔 payload 的上限 | `900000` |
| `NIF_OAUTH_CALLBACK_HOST` | 本機 OAuth 回呼監聽器的主機（埠固定為 1455/53692） | `127.0.0.1` |
| `NIF_LOG_MAX_MB` | core 在 `var/logs` 的子行程日誌保留上限（MB） | `200` |
| `NIF_LOG_RETENTION_DAYS` | core 掃掠前保留子行程日誌的天數 | `7` |
| `NIF_SPAWN_WAIT_MS` | `core.spawn` 在使呼叫失敗前，等待新元件在目錄中註冊的時間（限制 250–120000）；當目錄記錄到拒絕時等待會提早結束，因此此旋鈕只約束沉默的元件 | `5000` |

**建置與腳本旋鈕**——由 harness 周圍的腳本讀取，絕不由元件讀取：`NIF_BIN_DIR`（`scripts/install.sh` 將 PATH 項目連結進去的 bin 目錄）、`NIF_BUILD_LOCK`（`scripts/with-build-lock.sh` 以 flock 鎖定的鎖檔——建置時排他，測試執行時共享）、`NIF_NATS_CLI`（`components/dialog/dialog.sh` 驅動的 nats CLI——此處唯一一個元件確實會讀取的項目：僅在 `nats` 既不在 `PATH` 也不在 `$HOME/go/bin` 時才會查詢它）、`NIF_CONF_KEEP`，加上測試輔助 `NIF_STORE_BIN` 與 `NIF_REPO_ROOT`。`NIF_LSP_BIN` 與 `NIF_LSP_BIN_DIRS` 是執行時變數，留在上表。鎖只涵蓋 `make`：`builder.build` 在其外執行，因此執行時元件建置可能與 `make build` 競爭——而 `make clean` 會在其下刪除 `var/bin` 與 `var/build`。當 agent 正在建置元件時，請停止 harness。

每個 Niffler 變數都帶有 `NIF_` 前綴，因此 harness 絕不會與使用裸慣例（`NATS_URL`、`OPENAI_API_KEY`）的工具衝突。

### The `.env` file

`.env`（repo root，gitignored）存放本機機密/配置：

```bash
NIF_OPENAI_API_KEY=sk-...
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1
NIF_OPENAI_MODEL=deepseek-chat
```

載入規則（Nim、Go 與 TypeScript SDK 皆同）：既有的 shell 環境**永遠優先**於 `.env`；SDK 先載入當前目錄的 `.env`，其次載入 harness root 的，鍵的第一次定義優先。桌面 UI bridge 以相反順序載入它們（harness root，然後 cwd——`ui/bridge.go`），因此在那裡 root 檔案優先。所以 `NIF_OPENAI_API_KEY=other ./var/bin/niffler` 會覆寫檔案，而若你想要檔案的值，請在啟動前 `unset NIF_OPENAI_API_KEY`。`.env` 必須是純一般檔案：符號連結或硬連結的副本會被拒絕，檔案上限為 1 MiB，且值絕不進行 `$VAR` 展開。

repo root 的 `.env.example` 是參考副本——每個變數都被註解掉，其預設值作為註解值——但它在兩個方向上都不完整（上表有少數項目不在其中，而它帶有 harness 在正常運作中不會讀取的測試/工具變數）；表格才是權威。

## The bus in one screen

Core 只說一種協定：NATS 上的 JSON 封套（詳見
[WIRE.md](WIRE.md)）。主體——你在操作時會遇到的骨幹，而非完整清單（每個元件也會
發布自己的事件家族：來自 SDK 的 `ev.log.<component>`、`ev.lsp.warm`、`ev.agent.*`、
`ev.fabric.*`）：

```
reg.publish            component announces itself: {name, version, pid, tools:[{name, schema}]}
reg.depart             graceful shutdown announcement
svc.<component>.call   queue-grouped tool call request/reply
svc.session.<id>.steer   fire-and-forget mid-turn message injection ({content})
svc.session.<id>.advise  turn-bound advisory request/reply (the expert peer):
                         accepted only while the named turnId is live
svc.session.<id>.map     repomap → runner: the workspace map to append once
ev.workspace.opened    core → components: {workspace, conversationId} — a
                       conversation's workspace, for pre-warm and the repo-map append
ev.session.<id>.turn        {sessionId, turnId, phase: start|done, content?, error?}
                       #   per-conversation event namespace: a client watching
                       #   one conversation subscribes ev.session.<id>.>, an
                       #   observer subscribes ev.session.> for everything
                       #   (ev.session.*.token for every token stream)
ev.session.<id>.assistant   {sessionId, turnId?, content, provider?, model?, context?, usage?}
ev.session.<id>.status      {sessionId, turnId?, provider?, model?, context?, usedTokens?}
ev.session.<id>.token       {sessionId, turnId?, content, reasoning}  (live token deltas)
ev.session.<id>.toolcall    {sessionId, turnId?, callId?, phase: start|done, tool, args, result|error, durationMs?}
ev.session.<id>.advice      {sessionId, turnId?, source, content, reason} an advisory was
                             folded in (`reason` is the judge's one-line justification)
ev.session.<id>.notice      {sessionId, turnId?, kind?, content?, jobId?, child?,
                             status?} runtime machinery was folded in (subagent
                             settlement, background process exit, autonomous wake);
                             `content` is the rendered text UIs show
ev.session.<id>.done        {sessionId, turnId?, reply} | {sessionId, turnId?, error}
ev.session.<id>.context     {sessionId, turnId?, promptTokens, usedTokens, context, warning?|trimmed?}
ev.catalog.updated     direct (prompt-facing) tool projection after any
                       registration change; `catalog {op: snapshot}` still
                       returns everything incl. hidden/on-demand schemas
ev.models.updated      effective provider/model/source counts after refresh
ev.provider.switch     provider component → bus: {nickname, previous, source, at}
ev.provider.changed    redacted provider registry invalidation event
ev.llm.token           llm adapter → core: {sessionId, content, reasoning} deltas
ev.sys.drain           core → components: stop taking calls, finish, exit
ev.log.<component>     structured SDK logs: {component, level, msg, ctx?, at}
ev.lsp.warm            lsp → bus when a workspace warmup settles: {workspace, warmed, skipped}
ev.agent.started|done|notice  agent: a background job started, a job became
                       terminal, a settlement was folded into the turn
ev.fabric.started|phase|log|call.started|call.done|done
                       one fabric program's lifecycle, correlated by `runId`
llm.cancel.<sessionId> abort an in-flight streaming call (see Streaming below)
svc.approval.<name>.request  directed approval to the component driving the
                           turn (derived from the call envelope's `caller`);
                           driver acks {id, ack: true}, then answers {id, ok}
ev.approval.request    core → UI: {id, tool, args, caller?, fallback?} —
                       human gate, broadcast (see Approvals below)
ev.approval.reply      UI → core: {id, ack?} | {id, ok}
ev.approval.resolved   core → UIs: {id, ok} — gate verdict; dismiss stale modals
cancel.<component>     cancellation side-channel: a runner publishes it when a
                       turn cancel lands while a dispatch is in flight; bash
                       kills the command's process group (see WIRE.md)
```

**串流。** `llm` 元件在生成時串流 token：`ev.llm.token` 差異（內容 + 推理）→ core
將它們轉發為作用中回合的 `ev.session.<id>.token` → UI 將它們附加到即時助理泡泡。
差異訊框只會針對帶有非空 `sessionId` **且**保留 `emitTokens` 開啟的呼叫發布——
輔助呼叫者會在內部串流以便取消，但將其部分輸出排除在會話之外（壓縮傳遞
`emitTokens: false`；專家評審的呼叫甚至不會串流，因此兩種情況下都不會發出任何
內容）——並且每個具有內容或推理的串流區塊會發出一個訊框。這些呼叫者傳送的
`purpose` 引數僅供遙測使用（provider、model、effort、ttft 和 tok/s 會與其一起
記錄），且絕不會改變 provider 行為。最終的 `ev.session.<id>.assistant` 事件一律
攜帶完整內容，因此遺漏的最後一個訊框會自我修復。透過發布至
`llm.cancel.<sessionId>` 來中止進行中的呼叫——或者，當呼叫者傳遞了 `cancelId`
時，發布至 `llm.cancel.<cancelId>`：訂閱僅針對串流呼叫（`stream: true`，core
一律設定）武裝，並使用 `cancelId`，以 session id 作為其預設值。輔助呼叫者依賴
這種分離——壓縮會取消 `llm.cancel.compaction.<sessionId>.<attemptId>`——因此
使用者的回合停止既不能終止摘要呼叫，也不會被其終止。

歷史會逐字重播給 provider，這就是為什麼轉接器在輸出時會修復它：被中斷的串流
（或有缺陷的寫入者）留下未終止的助理 `tool_calls` 承載，其字串和容器會被關閉，
而無法挽救的承載會變成 `{}`——否則嚴格的後端會拒絕整個請求。修復只讀取文字，
絕不執行任何內容。

附加到匯流排的 `nats sub '>'` 會即時顯示 harness 的思考過程。或者更好：**console
元件**（`./var/bin/console`，不在 manifest 中——請自行在第二個終端機啟動）訂閱
所有內容，並以可讀方式呈現線路流量：帶有 subject + tool + args 的呼叫、結果、
錯誤、事件、核准。有兩個限制值得了解：單純的 `reg.publish`/`reg.depart` 承載會
列印為空主體的 `event <subject>` 行（使用 `observe_subjects` 或 `catalog` 來查看
哪個元件啟動了），而每個 SDK 結果列印時工具名稱為空——請將其與上方的呼叫行
關聯起來。這就是你追蹤即時安裝或卡住工具呼叫的方式：

當匯流排死亡時，console 會在 nats 用戶端的重新連線預算內保持安靜（數十秒到約
4 分鐘），然後列印其 `console: bus connection lost` 行並每 2 秒重試，每次重新
讀取 `var/nats-url`——在新的隨機連接埠上重啟的 harness 會被自動拾取。

```bash
./var/bin/console    # in a separate terminal while the harness runs
```

它沒有選項：它呈現匯流排上的每個封套，每則訊息一行，呼叫引數和錯誤截斷為 300
個字元，結果和事件承載截斷為 500，助理文字截斷為 2000——僅在 tty 上著色。若需
有界、可篩選、持久的檢視，請使用 `observe`/`logfile`。

**cli 元件**（`./var/bin/cli`）從指令碼或管線驅動相同的匯流排——非互動式、對 CI
友善（成功時結束碼 0，失敗時 1，使用錯誤或 JSON 格式錯誤時 2）；它是指令碼介面，
tty 管理 shell 則是互動式介面：

```bash
./var/bin/cli catalog                        # components + their tools
./var/bin/cli wait <component> [secs]        # wait for registration
./var/bin/cli call <tool> '<json args>'      # dispatch, print the result
./var/bin/cli install <repo>[@<ref>]         # plugin_install + verify
```

`catalog` 會列印開頭的 `# harness: <root> @ <gitHash>` 行，指出是哪個複製的 core
回應，然後每個元件一行 `component: tool, tool`（無序）；當 core 沒有回應或
catalog 為空時，它會以結束碼 1 退出。`cli install` 會複製、透過 builder 建置、
生成每個元件，並等待每個服務名稱出現在 core 已接受的 catalog 中；互動式元件則
透過其建置來驗證。`wait <component> [secs]` 會輪詢 core 已接受的 catalog（預設
60 秒；`0` 執行單次讀取）。CLI catalog 和工具查詢也使用 core 的權威目錄，絕不
使用原始註冊廣播。外掛儲存庫的 CI 透過這一個指令執行 harness 本身來證明套件。
`file://` 儲存庫 URL 會從本機 git 儲存庫安裝（封閉測試、鏡像）。`call` 會先等待
最多 60 秒讓 core 接受工具，然後等待 `--timeout=<secs>`（預設 30 秒）以取得
回覆——這是 cli 自己的預算，絕不是工具的 `x-harness.timeoutMs`，因此慢速工具
需要明確延長（`cli --timeout=600 call build …`）。基於名稱的驗證無法區分現有的
已接受元件與同名的新啟動程序。

它是單純的匯流排用戶端：`cli call` 直接分派至 `svc.<component>.call`（只有
catalog 讀取會經過 core），因此其呼叫會繞過核准閘門、工作區和會話注入、工具的
`x-harness.timeoutMs` 以及隱藏/隨選篩選——`cli call del …` 和 `cli call chat …`
可以運作。將其視為操作者工具：給予它你給予啟動 harness 之 shell 的同等信任。

## Approvals

其 schema 帶有 `x-harness.approval: "always"` 的工具——目前為 `bash`、`build`
（`builder` 元件）、core 的 `spawn`、`kill` 和 `remove`、`edit`、`write`、
`undo_last_edit`、`fabric`、`agent_run`、`agent_spawn`、`agent_ask`、
`expert_follow`、`lsp_registry`、`mcp_add`、`mcp_edit`、`mcp_remove`、
`mcp_refresh`、`plugin_install`、`plugin_update`、`plugin_remove`、
`process_start`、`process_kill`、`skill_install`、`skill_remove`、`provider_add`、
`provider_update`、`provider_export`、`provider_import`、
`provider_use_environment`、`observe_send`、`observe_request`、`observe_dump`、
`observe_monitor`——在執行前需要人工把關；設定為 `approval: always` 的
MCP-bridge 伺服器的每個工具也以相同方式把關，而諸如 `provider_update`/
`provider_use_environment` 等隱藏項目在被直接呼叫時仍會把關，因此該清單並非
封閉的（包括 core 未註冊的 `conversation_delete` 介面）：

- **終端機 harness**（`make run`）：帶有工具名稱和引數的 `[approval]` 提示；
  回答 `y`/`n`（僅當 core 位於終端機上且未附加 UI 時，才回退到 tty 提示）。
- **Web UI / 互動式元件**：請求會路由到驅動該會話的特定元件——core 從呼叫
  封套自我宣告的 `caller` 推導出它，並發布至該元件的私有主體
  `svc.approval.<name>.request`。驅動程式會對其進行確認（`{id, ack: true}`）以
  確認正在詢問人工，顯示帶有工具名稱和引數的強制回應視窗，並回答 `{id, ok}`。
- **驅動程式消失 / 非互動式**：如果驅動程式在 1.5 秒內未確認
  （`ackTimeoutSecs`），請求會以 `fallback: true` 在 `ev.approval.request` 上
  重新廣播，以便任何互動式用戶端可以介入；若沒有註冊互動式用戶端，則會跳過
  重新廣播並立即拒絕該呼叫。直接（非會話）呼叫會立即廣播。
- **兩者皆非**（未附加 UI 的服務模式）：該呼叫會以明確的錯誤**被拒絕**——
  呼叫者會看到 `approval denied for tool '<name>'`（core 自己的工具：
  `approval denied for <name>`）作為正常的工具錯誤，回合繼續，且不會有任何
  內容被靜默重試——絕不會有靜默核准。
- 當裁決送達時，core 會發布 `ev.approval.resolved {id, ok}`，以便每個用戶端
  關閉任何過期的強制回應視窗。
- 沒有用戶端回應的工具核准會在 5 分鐘（`timeoutMs`，300 秒）後逾時並被拒絕
  （記錄會顯示 `timed out after Ns — denying`）；`/limit` 的繼續詢問有其自己
  較短的視窗（120 秒）。
- `NIF_AUTO_APPROVE=1` 會繞過閘門（無頭自動化）。
- core 自己的破壞性工具命名為 `spawn`、`kill`、`remove` 和
  `conversation_delete`；它們在 `handleCoreTool` 內按名稱把關，而非透過
  schema，因此 `x-harness.approval` 只出現在元件工具上。
- 閘門位於 core 的分派器中，因此它只保護 core 中介的呼叫者：模型，以及任何
  透過 `svc.core.call` 進來的內容。直接觸及元件的呼叫者會在未經詢問的情況下
  執行 `approval: "always"` 工具——`plugins` 安裝路徑會自行呼叫
  `svc.builder.call`（其自身的 `plugin_install` 呼叫才是攜帶核准的），而
  `./var/bin/cli`、`dialog` 或發布至 `svc.<component>.call` 的測試永遠不會
  進入該閘門。將這類呼叫者視為啟動 harness 之 shell 的信任等級。

程式形狀的呼叫（`fabric`，或帶有 `code` 的 `agent_run`/`agent_spawn`）是依
*內容*核准，而非依工具名稱：core 將原始碼加上選定的 `tools` 和 `maxCalls`
雜湊成摘要，將完整原始碼寫入 `var/approval-sources/<digest>.nim`（模式 0600），
並在提示中顯示該路徑，因此核准者能閱讀所有內容，而非截斷的摘錄
（`tests/t_approval_manifest.nim`）。

### Conversation controls: `/approvals`, `/limit` and `/compact`

這三個控制項屬於你（人工），永遠不屬於模型，且套用於單一會話。全部透過
session 呼叫設定（Web UI 將它們公開為 `/approvals`、`/limit` 和 `/compact`；
任何匯流排用戶端都可以直接呼叫 `session`）。`approvals` 和 `limits` 設定會與
會話一起持久化，因此恢復的會話會保留它們；`/compact` 是動作，不是設定。

- **`/approvals auto`**——此會話停止詢問：每個受把關的工具都會被授予，且 core
  會在其記錄中大聲說明（`core: approval auto-granted for <tool> (this
  conversation is in approval mode: auto)`），因為靜默授予正是閘門存在所要
  防止的。該設定會持久化在會話標頭（`approvals`）中，因此工作階段執行器中
  恢復的會話會記錄相同的行。`/approvals ask`（或帶有空引數的 `/approvals`）
  會還原正常的閘門。對於你已決定端到端信任的會話使用它；逐工具的「不再詢問」
  記錄仍可用於較窄的信任。用戶端的自動核准動作會寫入持久記錄（儲存類型
  `approval`，id `<sessionId>:<key>`——由用戶端寫入，而非 core）；對於程式
  形狀的呼叫，鍵為 `<tool>:<digest>`，因此一概而論的「永遠核准 fabric」永遠
  不會涵蓋新寫入的原始碼。當這類記錄符合時，閘門永遠不會閃現對話方塊。
- **`/limit rounds=N tokens=N seconds=N`**——回合的軟預算：LLM 回合、累計
  token 和牆鐘秒數。秒數會在每次工具分派前檢查（一次 `bash` 呼叫可能比整個
  回合還久）；回合和 token 會在下一個 LLM 回合前檢查。當其中一項達到時，回合
  不會死亡：core 會透過相同的核准通道詢問你**「keep going?」**（UI 會顯示
  一個 Continue/Stop 提示並指出該限制），而*是*會將該限制再延長一步。*否*、
  無回應或無可觸及的用戶端會以獨特的 `limit-<dimension>` 記錄結束回合，該
  記錄指出限制及提高它的指令。`/limit clear` 會移除全部三項。
- **`/compact`**——*立即*執行壓縮器，而非等待自動壓力階梯：core 向已設定的
  壓縮元件要求在允許的切點上建立檢查點，以原子方式安裝它，並發出慣用的
  `ev.session.<id>.context {reason: "reset:compact"}`。不會執行 LLM 回合，也
  不會附加任何使用者訊息。提交會將測量的提示大小歸零（此投影尚未經過
  provider），因此手動路徑也會發布狀態訊框——`usedTokens` 是本機估計，
  `estimated: true`，加上視窗——否則情境量表會持續顯示壓縮前的數字，直到
  下一個回合測量它為止。下一個請求的測量用量會取代該估計。輔助摘要會繼承
  會話已解析的 provider/model；它不會靜默跟隨之後的全域 provider 切換。
  回覆會報告 `compacted: true` 及 `beforeTokens`、`afterTokens` 和
  `generation`，或報告 `compacted: false` 及精確的拒絕/失敗原因（例如
  `no permitted cut exists yet`、`input-budget-exceeded`、
  `summary-output-truncated`、無效的候選詳細資料，或無法使用的壓縮器）。
  拒絕永遠不會靜默回退到有損修剪。

重要的區別：這些限制是*你的*，因此它們可以協商；工作範圍的預算
（`maxRounds`/`maxCalls`/`maxTokens`，`agent` 元件會將其凍結到子代理的會話中，
以及 `NIF_MAX_TURN_ROUNDS`）則保持硬性——子代理不得能靠著說服來取得更多預算。
`NIF_AUTO_CONTINUE=1` 會對每個繼續詢問回答是（無頭自動化，與
`NIF_AUTO_APPROVE=1` 精神相同）。

在回合執行時到達的 session 呼叫會立即以 `busy` 被拒絕（「the conversation is
mid-turn — retry when the turn finishes」），而非等待：回合永遠不會嵌套，而
選擇等待的用戶端只會讓自己的逾時到期（這就是讓 `/export` 在長時間回合期間
看似故障的原因）。

## Context window

Core 會監看一段會話使用了模型 context window 的多少，並以*極簡*方式因應——不做摘要，除了模型回報的數字外不做任何 token 計算：

- 有效的 window 會在每一回合前由隱藏的 `llm_resolve {model?}` 解析，因此新選取模型的限制會在推論前送達 context 守衛。各 provider 的 `context` 與 `NIF_OPENAI_CONTEXT` 會覆寫 models catalog；若 `models` 被移除，則以一個小型內建表與保守的 128K 作為後備。結果包含不含機密的 provider、model、catalog、context 與 output 來源資訊，以及供互動式用戶端使用的 provider `protocol`、`authType` 與 `hasKey`；它仍需要一個可解析的 provider，因此若無已儲存的憑證也無環境憑證，它會失敗而非回報 window。參見 [Model catalog](#model-catalog-models)。

- **output** window 會與 context window 一併解析，並以 `output`/`outputSource` 回傳：catalog 的 `model.limit.output`，否則為刻意設定的 32768 預設值——若無明確上限，provider 會套用其自身的伺服器端上限，並在串流中途截斷冗長的回答。每次呼叫的 `maxTokens` 只會調降已解析的值（expert judge 的微小裁決），而 Codex 通道則完全忽略它。

- `session {sessionId, content?, provider?, model?, thinking?, title?, cwd?, profile?, discovery?, tools?, maxRounds?, maxCalls?, maxTokens?}` 接受一個會話範圍的 provider 與模型覆寫。`provider` 指名一個已儲存的 provider 暱稱（空值會清除它，回到 harness 全域預設）；僅指定 model 的呼叫會在同一次標頭寫入中解析並釘住其所屬的 provider，因此 provider 與 model 總是一起出現——model 不會在事後因為另一個 UI 切換了全域預設而被送往不支援它的 provider。無法解析的明確 `provider` 是一個指名它的錯誤，而不是靜默回退（見 WIRE.md「Provider/model pins are one selection」）。僅指定 model 的呼叫會在不進行推論的情況下持續保存並解析該選取；帶有空值的存在則會清除它。`profile` 指名一個已儲存的工具 profile，僅在會話的第一次呼叫時解析進直接工具集（`NIF_PROFILE` 提供預設值）；未知的 profile 會使該呼叫失敗，而續接會忽略該引數。`thinking` 是推理強度，為 `""`、`low`、`medium`、`high`、`max` 之一；`""` 是 provider 預設值（UI 顯示為「auto」），且是唯一能清除先前選擇的值。它會以 `reasoning_effort` 轉送給 provider——且僅在非空時，因此不支援該欄位的 provider 永遠不會看到它；`llm` 轉接器會將該值對應到各協定自身的形式（Codex `reasoning {effort, summary}`、Anthropic `thinking` 加上 `output_config.effort`）——並攜帶於會話標頭上。
  `discovery {…}` 是明確的用戶端探索：它執行 `discover`，將 schemas 記錄於持久 discovery summary 中，並將它們附加為一則使用者訊息——不進行 LLM 回合，也不晉升進直接工具集。
  Core 會將該選擇儲存於會話標頭，並在一個回合中的所有工具回合間釘住已解析的模型。
- 各會話的控制項會在第一次呼叫時凍結並持續保存於標頭中：`tools`（子項可分派的工具允許清單；最多接受 32 個名稱，且可接受的引數不會宣告於 `session` 工具 schema 中）、`maxRounds`
  （每回合的 LLM 回合數，1–`NIF_MAX_TURN_ROUNDS`，收窄硬性上限）、
  `maxCalls`（每回合的工具分派總數，1-500——每次分派嘗試都計數，無論成功或錯誤），以及 `maxTokens`（每回合累計的 provider 回報 token 數，在每個新回合前檢查）。
  預算耗盡會以 budget-exhausted 錯誤結束該回合——subagent 驅動程式（`agent_run`/`agent_spawn`）會將其呈現為失敗，而非文字回覆。
- `cwd` 釘住會話的**工作區**：`NIF_ROOT` 內一個既存的目錄（相對路徑會對根目錄解析），建立後不可變，並持續保存於標頭中，使續接的 runner 以相同方式解析 context 與路徑。Session runner 會在分派時改寫路徑形狀的工具引數：bash 以 `cwd` 設為工作區執行，edit/grep/read 在該處解析相對路徑，git 工具則以工作區 repo 為範圍。當工作區與根目錄不同時，system prompt 元件會附加一則工作區通知。預設工作區即 `NIF_ROOT` 本身。
- 每次 chat 呼叫後，core 會記錄 prompt token，並使用 `usage.total_tokens`（或 prompt + completion 後備）作為當前最佳佔用量。Provider、model、context、佔用量與覆寫也會鏡射進會話標頭，因此計量器無需載入整份逐字稿即可在重啟後存續。
- Core 會發出 `ev.session.<id>.status`，帶有已解析的 provider/model/context 與當前 `usedTokens`；用戶端直接呈現 `usedTokens / context`。
  當 provider 回報快取的輸入（`prompt_tokens_details.cached_tokens`）時，status 事件也會攜帶該會話的累計快取拆分為 `cache {prompt, read, hitRate}`（prompt 與快取 token 的加總，比率以百分比表示）；會話標頭以 `cachePrompt`、`cacheRead` 與 `cacheHitRate` 保留相同數字。由於 prompt 前綴已凍結，第一次請求後多數 prompt token 應已被快取，因此偏低的比率是值得留意的訊號（web UI 在每則訊息顯示 `⚡ <cached>/<prompt> cached`，並在 `/info` 顯示累計拆分；TUI 在其標頭顯示 `cache NN%` 標籤，並在 `/status` 顯示相同拆分）。
- 已持續保存的訊息帶有永遠不會送達 LLM 的稽核中介資料：每則訊息上的 `createdAt`、各處的 `turnId`，以及 assistant、tool 與 error 記錄上的 `startedAt` / `durationMs`（當 LLM 呼叫本身失敗時會持續保存一筆 `error` 記錄，而重播會略過 error 角色）。
- 准入會在**每一次** provider 請求前執行，包括每個工具迴圈回合。在已回報的使用量存在之前，它會以保守的 chars/4 估算為整份請求（訊息加上凍結的工具 schemas）定價。保留的餘裕是 catalog 中模型宣告的 output 上限（`limit.output`，例如 DeepSeek 的 384000）——provider 在准入時會將請求的 `max_tokens` 計入其 window，因此固定的 16K 保留量曾讓一個 736,803-token 的 prompt 溢出 1,048,576 的 provider 限制，而該 prompt 單獨是放得下的。`NIF_CTX_RESERVE` 會覆寫推導出的保留量。Core 會在到達有效線的 75% 時警告一次
  （`ev.session.<id>.context {reason: "warn:threshold"}`）；到達該線時——絕不晚於 window 的 90%——core 會執行一個有界的階梯：確定性的工具結果剪除 → 已設定的 compactor → 最舊完整回合修剪 → 明確的 `context-recovery-required`。在傳輸線上，`llm` 元件另會將請求的 output 夾限至序列化 prompt（訊息加上工具 schemas）所留下的餘裕，因此任一層的估算漂移都無法將一個放得下的 prompt 推過 provider 的限制。它絕不會在知情下送出超出 window 的請求。
- 觸發器以**provider 的尺度，而非估算的尺度**衡量：每一次成功的回應都會重新測量一個校準偏移（回報的 `prompt_tokens` 減去同一請求的本地估算），而准入、警告與修剪會以估算 + 偏移為候選定價。原始的 chars/4 代理可能落後較密集的 tokenizer 達數萬個 token——曾觀察到一個 524K-window 的會話中，「90%」線在約 99% 時無聲觸發，而一個 core 稱為 86% 的請求在 400 時被拒絕。該偏移以模型為範圍（模型變更時清除，從下一次回應重新學習），續接時從已儲存的使用量播種，夾限於 `[0, window]`，且永不持續保存——它會在第一次回應時重新測量。
- 隨附的 `compaction_propose` 可替換：設定
  `NIF_COMPACTION_TOOL=<tool>` 以選用另一個 contract-v1 實作，或將其設為空以停用摘要，同時保留確定性守衛。該值是**工具名稱**，不是元件名稱：runner 會在 catalog 中解析它，並分派給註冊它的任一元件，因此替換品可位於任何元件中。空值或未註冊的值會略過自動階梯中的該階，並使 `/compact` 回答 `compacted:
  false` 與 `reason: "no compaction component available
  (NIF_COMPACTION_TOOL=<value>)"`。`NIF_COMPACTION_TIMEOUT_MS`、`NIF_COMPACTION_MAX_LLM_CALLS` 與
  `NIF_COMPACTION_MAX_SUMMARY_TOKENS` 會限制每次嘗試。此接縫是一個有版本的契約：候選工具會以 `{version: 1, sessionId,
  attemptId, trigger, snapshot: {ref, generation, canonicalHigh, digest},
  budget: {…}}` 被呼叫，並回答 `{version: 1, status: "declined", attemptId,
  reason}`（帶有三個穩定原因之一：`no-useful-cut`、
  `input-budget-exceeded`、`indivisible`），或 `{version: 1, status:
  "candidate", attemptId, baseGeneration, snapshotDigest, cutBefore, covered,
  checkpoint, provenance: {model, llmCalls}}`，其中 `checkpoint` 恰好攜帶 `objective`、`constraints`、`decisions`、`completedWork`、
  `currentBlocker`、`nextSteps` 與選用的 `files`。其他任何內容都會被視為無效而拒絕，並落到修剪——如同高於所授予 `NIF_COMPACTION_MAX_LLM_CALLS` 的 `provenance.llmCalls`，以及一個發現請求的 `attemptId`、`digest` 或 `generation` 與其所讀取的 snapshot 不一致的元件會以 `stale-snapshot` 拒絕該呼叫。Runner 會寫入一個暫存的分頁 `compaction_input` snapshot，驗證候選的 generation/digest/cut/schema/size，對照 snapshot 重新雜湊被涵蓋的節點，並自行測量嚴格縮減（渲染後 checkpoint 的估算 token 必須低於被涵蓋跨度的），然後以樂觀的 `expectRev` 提交一份
  `context_projection` 文件。Snapshot 分頁為
  512000 位元組，因此一則巨大的訊息無法使匯流排訊息過大；checkpoint 有界（objective 與清單項目 ≤ 4000 字元，每個清單 ≤ 32 個項目，≤ 64 個檔案，編碼後 ≤ 65536 位元組），並由 runner 擁有的 `checkpoint-v1` 範本渲染，因此由一個 compactor 儲存的 checkpoint 在另一個之下會以相同方式重新載入。該元件
  永不寫入會話或 projection 記錄。
- 一次成功的 projection 會發出 `reason: "reset:compact"`；無模型的剪除會發出 `reset:prune`；有損後備會發出 `reset:trim`。`reset:tools` 仍保留給實際的黏性工具 schema 晉升。這些是唯一刻意的 prompt 前綴重建，並使快取未命中可歸因。compaction 階會回報**每一個**非 reset 退出，絕不靜默：
  `compact:unavailable`（未設定或未註冊 compactor）、`compact:failed`（分派錯誤/逾時、上一個 projection 缺失或過期，或樂觀提交遺失）、`compact:declined`（帶 `detail` = 穩定的拒絕原因，或 runner 的 `no permitted cut exists yet` / `no committable cut exists yet`）、`compact:invalid`（schema、界限、宣稱呼叫預算、嚴格縮減或邊界解析失敗）與 `compact:stale`（被涵蓋的跨度或 projection 在嘗試期間改變）。它們每一個都攜帶人類可讀的 `detail`；它們都不重建 prompt 前綴。成功的 `reset:compact` 事件
  攜帶 `generation`、`covered`、`beforeTokens` 與 `afterTokens`。閾值警告（`warn:threshold`）攜帶 `trimAt`——以 token 計的有效門檻線——因此 UI 可以顯示與 core 列印的相同百分比，而不是自行編造。
- 只有當邊界能解析到標準歷史時，它才會被提供給 compactor。起始於省略通知的涵蓋跨度（有損裁剪留下的 projection）會將其 `covered.from` 解析為該 checkpoint 實際吸收的第一個標準項目；完全沒有標準涵蓋的跨度絕不會被提供。因此，在 compaction 之前就裁剪過的對話仍然可以提交 checkpoint——以前不能，而且拒絕是靜默的，所以階梯一代又一代地裁剪。
- 標準的 `message` 文件不可變且僅可附加。剪除與 compaction 只改變 provider projection；重啟的 runner 會驗證並重新載入持久 checkpoint 加上保留的標準尾端，而
  `context_recall` 會解析 canonical/spill/current-checkpoint refs；一個
  `checkpoint` ref 會回傳該 projection 的結構化 checkpoint 加上其
  `generation`（而非分頁文字），忽略 `mode`/`offset`/`limit`，且當它指名一個已被取代的 generation 時會被拒絕——該狀態已被吸收進當前 checkpoint，那才是該讀取的——而其
  `mode: search` 會 grep 該會話的整份標準 `message` 歷史——
  每一則訊息，包括被修剪或 compaction 丟棄的跨度，其中沒有通知會指名個別 refs（search 只讀取 `message` 文件；spill 主體與
  checkpoints 永不搜尋，其 refs 會解析它們）。遺失或
  損毀的 projection refs 會明確失敗，而非無聲重播一個
  過大的跨度。
- `context_recall {ref?, mode?, query?, session?, role?, offset?, limit?}` 是那些通知背後的解析器：`ref` 是一個 `{source, id}` 物件或其陣列（`source` 為 `canonical`、`spill` 或 `checkpoint`），`mode: full`
  （預設）以 `offset`/`limit` 分頁一份文件，受每份文件 256 KB 上限限制，`mode: match` 會 grep 一份文件的行——僅受 `limit` 行數限制，無位元組上限，因此一個符合某個巨大單行結果的查詢會完整回傳該行——而
  `mode: search` 會 grep 該會話中提及 `query` 的訊息
  （`role` 會篩選它們；`session` 挑選要搜尋的會話——一個以會話租用的呼叫只能指名它自己的會話，因此 runner 呼叫無法讀取另一個會話的歷史，而直接匯流排呼叫者
  保持不受限的存取），並回傳有界的一行命中，其 `id`
  之後可作為 `canonical`
  ref 讀回。預設值：2000 行、50 個符合、20 個命中；該工具為隨選且
  讀取效應，且它為 `runner` 豁免，因此 subagents 永遠能觸及它。
- provider 回報的 `context-overflow` 恰好獲得一次有收據背書的復原嘗試。相同的 prune → compactor → trim 順序會重新測量；
  第二次溢出即為終止，絕不是無界的重試迴圈。當
  容量未知且拒絕未攜帶可解析的 window 時，該
  嘗試會盲目縮減（無損剪除，然後修剪至最新請求），
  且只有在候選確實縮小時才會送出重試——一個
  不可縮減的候選會終止，而非重送被拒絕的內容。轉接器會將 provider 溢出的措辭（包括某些主機回傳的裸 `"Context limit exceeded"` 主體）正規化為
  穩定的 `context-overflow` 前綴；runner 的分類器會將
  原始措辭作為後備。
- 有損修剪是**持久的**：它會在會話標頭中記錄它所切穿的標準 seqNo（`trimThrough`），而一般的
  續接會遵循它，因此重啟會重建修剪後的 projection，而非重新膨脹完整的修剪前 context，同時計量器會還原
  修剪後的使用量。被丟棄的回合仍留在標準歷史中供
  `context_recall` 使用，且省略通知是持久的：續接的 runner
  會從 `trimThrough` 重建修剪後的 projection 並重新插入該
  通知（範圍誠實——它指名第一個保留 seq 以下的標準跨度，而非執行中確切的 `coveredFrom`/`coveredTo` 對），因此
  重啟會保留一個可見的指標指向該 projection 所丟棄的內容。`mode:
  search` 是回到修剪歷史的方式——該通知不攜帶
  recall ref，因為整回合的丟棄涵蓋許多訊息。

- 剪除步驟是位元組精確且無模型的：超過 8192 位元組的工具結果會
  被改寫為其前 4096 位元組、一個 `[tool result middle pruned: N bytes
  omitted — recall the original with context_recall {"ref": {"source": "spill",
  "id": "<convId>:<seq>"}}]` 標記，以及其最後 1024 位元組——絕不兩次，
  且絕不在結果不會縮小時。該標記的 `source` 恰好在結果為 spill 背書且晉升的文件重新驗證時為 `spill`，否則為 `canonical`，而其 `id` 是該通知所引用的標準 seqNo，因此它可以直接傳回 `context_recall`。這三個
  數字是常數，不是設定。`context_recall` 本身是隨選的，並非隱藏：`discover` 會列出它，`invoke` 接受它，且裸名稱
  仍會分派，但一個以 `tools` 允許清單凍結的會話會像任何清單外的工具一樣拒絕它——這是剪除或 spill
  通知的指示無法被遵循的唯一情況。

## Self-extension and component lifecycle

代理會在執行時、會話中途新增能力：

1. 寫入一個元件原始碼（Nim：`import niffler/sdk`，具型別的工具
   模式；Go：`import sdk "niffler.dev/sdk"`；TypeScript：`sdk/ts`
   套件——參見 system prompt）。TypeScript 建置需要 PATH 上有 `node` 與 `npm`
   （缺少其一會以 `node and npm are required on PATH for
   ts components` 拒絕），會在對 `<root>/sdk/ts` 的 `file:`
   依賴周圍產生 `package.json`/`tsconfig.json`，而其 `var/bin/<name>` 是一個 node 包裝器，
   以絕對路徑 `require` `var/build/<name>/dist/main.js`——將
   該「binary」複製到別處，或刪除 `var/build/`，會使該元件損壞，且
   沒有錯誤訊息解釋原因
2. `build {lang, name, source, files?, defines?}`（`builder` 元件）
   會將其編譯進 `var/bin/`（`files` 新增更多 Go 原始碼，`defines`
   傳遞編譯器 defines）。檢查其結果，而非假設 binary
   存在：成功時為 `{ok, lang, name, binary, log}`，失敗時為 `{ok: false, lang,
   error}`，其中 `error` 是編譯器自身的輸出尾端（2000
   位元組）。不報告結束碼，因此一個在其內部預算
   （Nim、Go 與 `npm install` 300 秒，`tsc` 120 秒）被終止的建置
   讀起來與一個帶有其已產生任何輸出的編譯錯誤完全相同
3. `spawn {name, binary, replicas?}`（core）會啟動它；它會自行註冊；
   新的會話會直接暴露其工具（當非隨選時），既有的
   則透過 `discover` + `invoke` 觸及它們（參見 [Progressive tool discovery](#progressive-tool-discovery)）。
   `spawn` 只有在該註冊落入 catalog 後才回報 ok：一個
   被拒絕的註冊（catalog 的原因）或一個超過
   `NIF_SPAWN_WAIT_MS` 的無聲元件會使該呼叫失敗，帶有原因與子項日誌的有界尾端，並
   回滾該嘗試——replicas 停止，無任何持續保存——因此該名稱可自由供立即修正後重新 spawn。一個已註冊但其 store 記錄無法寫入
   （store 停機）的元件也會失敗，帶有 `registered: true`：它現在執行，並在
   下次開機後消失，這不是單純的成功
4. `kill {name}` 會暫時停止每個 replica（下次開機時還原）；
   `remove {name}` 會停止該群組並刪除其持續保存的記錄。Runner
   以相同方式被終止（`kill {name: "session-<id>"}`），但會在
   下次會話呼叫時回來，而非下次開機時。重建不會觸及
   執行中的行程——舊 binary 會繼續執行——因此採用新程式碼
   是 `kill` 然後 `spawn`；在那之前，`spawn` 會回答 `component already
   supervised: <name>`

一個穩定下來的 fabric 程式走相同路線：`fabricprog` 是
草稿本，`builder.build` + `core.spawn` 是畢業（參見
[FABRIC_GUIDE.md](FABRIC_GUIDE.md)）。

`replicas` 是選用的（1–16，預設 1）且會持續保存。僅用於
無狀態或外部協調的元件：所有 replicas 共用相同的
`svc.<name>.call` NATS 佇列群組，因此並行請求會每個行程分配一個。絕不複製單寫入者的 `store`，或像 `edit`
這樣其變更/復原狀態為行程本地的元件。預設 Nim SDK pump 保持
序列。其初始 NATS 連線會在匯流排綁定期間重試最多 60 秒，然後
失敗進入 supervisor 的正常退避；關機會中斷
該等待。當 replicas 不適合時，元件可以明確擁有原生並行性：
對長生命期/共享狀態的 Nim worker 偏好 `std/threads` + `std/locks`，
對隔離的工作使用 `taskpools`，且絕不使用 `asyncdispatch`。在 Go 中，
一般的 `Tool` 處理程式保持互斥；一個受稽核的處理程式可以使用
`ToolConcurrent`（預設在途上限為 16，可透過
`ConcurrentLimit` 設定）。並行處理程式必須同步共享狀態，且
不得在其自身元件上同步呼叫序列化的工具。分派由每個元件的傳遞迴圈調度：NATS 回呼只負責排入佇列，因此長處理程式（串流 chat）永遠不會阻塞無關呼叫的傳遞；序列化處理程式只在沒有並行處理程式執行時才開始，而不是駐留一個寫入鎖——否則排在其後的讀取者也會被阻塞。這個
伺服器端選擇獨立於面向 runner 的 `x-harness.parallel`
提示：一個宣告 `parallel: true` 的工具可以與同一則 assistant
訊息中其他標記為 parallel 的工具並行分派（`grep` 與 `read` 會；
`files` 雖為唯讀，則不會，因此一個被 `invoke` 的 `files` 會序列化）。

**重啟政策**：每個受監督的子項都帶有一個——`never` 或
`on-failure`（預設；重啟的子項會在 1 秒後嘗試，每次連續崩潰加倍，上限為 8 秒）。manifest 會為每個元件設定它
（`manifest.yaml`），`spawn` 一律使用 `on-failure`，而 session runner
一律為 `never`。

**形狀的持久性**：spawned 元件會記錄於 store
（kind `component`）並在正常開機時還原。一個其名稱也
宣告於 `manifest.yaml` 的已儲存記錄會在還原時略過——隨附的定義
勝出，無聲地——因此替換一個隨附元件意味著編輯 manifest；一個
同名下的 `kill` + `spawn` 僅在當前開機期間成立。`--minimal` 會讓那些
記錄不受觸及，但不還原它們。`core` 本身、匯流排、
catalog 與 supervisor 不可移除——該不對稱性就是
架構（ARCHITECTURE.md）。

## Component ecosystem (`plugins`)

`plugins` 元件是生態系的門面——社群元件套件就是根目錄帶有 `niffler.json` manifest 的普通 GitHub repo（一個 repo = 一個套件 = N 個元件）。Manifest v1 維持精簡的
`{name, components: [{name, lang, main, sources?, env?, defines?, interactive?}]}`
形式。Manifest v2 使用 `{manifestVersion: 2, components: [{name, lang,
project, build: {steps: [[argv...]], artifact: {path, runner}}}]}`：套件自行擁有 `package.json`/lockfile、`go.mod`/`go.sum` 或 Nimble 檔案；Niffler 只提供 SDK 佔位符與 builder 接縫。`lang` 是給 Nim、Go 或 TypeScript SDK 的中繼資料；recipe 可以組合外部套件工具（例如 Go/Wails 用戶端使用 npm 與 wails）。builder
會拒絕不支援的指令與 shell 包裝步驟，而 project/artifact
路徑必須留在 clone 內，且
宣告零個元件的 manifest 會被拒絕。標上 GitHub
主題 `niffler-component` 的 repo 無需任何 registry 即可被探索：

| Tool | What it does |
|---|---|
| `plugin_search {query?}` | GitHub 主題搜尋；回傳 repo、description、stars，以及勝出的 `query` 與每次嘗試的診斷——GitHub 會對詞彙做 AND，因此零命中的查詢會以更少的詞重試 |
| `plugin_installed` | 此 harness 上已安裝的套件 |
| `plugin_install {repo, version?}` | clone `var/plugins/<pkg>@<ref>/`，透過 builder 建置每個元件（v1 用 `build`，v2 用 `build_package`），然後 `spawn` 每個服務元件（需核准）。安裝已有紀錄的套件是錯誤，而非重新安裝——請用 `plugin_update`，或先 `plugin_remove`；clone 是淺層的（`--depth 1`），且 v1 Go 套件會帶一個未追蹤的 `go.work` 供手動建置 |
| `plugin_update {package}` | 更新至最新 release tag：移除、以新 ref 重新安裝；沒有 release（追蹤分支）的套件會就地拉取（對既有 clone 執行 `git pull --ff-only`），並在拉取移動 HEAD 或已安裝的 artifact 過期/遺失時重新建置 |
| `plugin_remove {package}` | 對每個受監督元件執行 `core.remove`、刪除 clone、移除紀錄 |

- Install/update/remove 全都帶有 `x-harness.approval: "always"`——它們
  會執行第三方程式碼，且每一次個別的 spawn/remove 都會再次由 core 核准。除非你信任
  發佈者，否則絕不要以 `NIF_AUTO_APPROVE=1` 執行它們。
- 預設 ref 是最新 release tag，否則為預設分支。
  `version` 可明確指定 tag 或分支。
- 元件一律透過 `builder` 從原始碼建置——與 agent 撰寫的元件走同一條路徑。
  執行中的 Niffler 已提供工具鏈（Nim/Go 與 NATS SDK），因此不需要 NATS C 函式庫；每個
  平台都以自己的工具鏈編譯。Go 進入點可宣告
  `"sources": ["component/helper.go", ...]`；這些必須是非符號連結的 `.go`
  檔案，且**與 `main` 位於同一目錄**（plugins manifest 讀取器會拒絕
  子目錄中的路徑，且只有 basename 會傳到 builder），最多
  64 個檔案、總計 2 MB，builder 會將它們與 `main` 編譯為同一個
  套件。Nim 或 TS 進入點上的 `sources` 鍵會在讀取 manifest 時被拒絕。
- Manifest-v2 套件在自己的生態系檔案中宣告相依性：
  TypeScript 使用 `package.json`/`package-lock.json`，Go 使用 `go.mod`/`go.sum`，
  Nim 使用 `.nimble`/lockfile。recipe 從宣告的 project
  目錄執行，因此 `npm ci`/`npm run build`、`go mod download`/`go build`、
  `nimble install`/`nim c`，或先 `npm ci` 再 `wails build`，全都使用
  套件正常的相依性語意。Wails 桌面用戶端是帶有 `executable` artifact 的 Go
  元件，且可標記為 `interactive`。
  `${NIF_SDK_ROOT}`、`${NIF_SDK_GO}`、`${NIF_SDK_TS}`、`${NIF_PROJECT}` 與
  `${NIF_OUTPUT}` 是 builder 唯一的替換項。步驟是 argv 陣列，
  而非 shell 字串，且 builder 會拒絕 traversal、符號連結輸入、
  過大的 project、不安全的 runner 與未宣告的 artifact。
- 帶有 `"interactive": true` 的元件 manifest 項目會建置到
  `var/bin`，但不會傳給 `core.spawn`。它是終端機用戶端（例如
  TUI），由使用者手動啟動，因此不受監督，也不會在開機時
  重啟。在移除或更新其套件前，請手動停止任何執行中的用戶端。
- Manifest 項目可帶 `defines`（`-d:` 風格前置旗標的陣列）與
  `env`（`NAME=value` 字串的陣列）。兩者都會被傳遞——`defines`
  傳給 builder（僅 Nim：Go 或 TS 建置會接受並默默忽略它們），`env`
  傳給 spawn——因此套件可以自帶設定，無需編輯 manifest。
- 安裝紀錄存放於儲存（kind `plugin`，id = 套件名稱）；
  它們會像所有元件紀錄一樣被 `--recover` 清除——全新開機會在重新安裝時
  從紀錄的 repo/ref 重新 clone。
- GitHub API 以未驗證方式使用（60 req/h/IP）。
- 發佈：加上 `niffler-component` 主題並標記 release
  （`v1.0.0`）。範例
  [`gokr/niffler-weather`](https://github.com/gokr/niffler-weather) 中的 release workflow
  會 dogfood：它啟動一個 harness 並透過
  `plugin_install` 安裝套件，因此每個 tag 都證明該套件能乾淨安裝。
- 套件可透過註冊帶有 `x-models-source: {version: 1, priority: ...}` 的隱藏工具，
  來擴充或修正模型中繼資料。`models` 元件
  會自動探索它，並在該元件存在期間套用其 JSON Merge Patch。參見 [Source plugins](#source-plugins)。
- 樹內有三種參考形態：`gokr/niffler-weather` 套件
  （Nim）、MCP 橋接（一個被 spawn 的 Go 元件），以及
  `components/dialog/dialog.sh`——一個完全沒有 SDK 的純 bash 元件。

## Skills

`skills` 元件為 agent 提供可重複使用的工作流程指引——開放的
[Agent Skills](https://agentskills.io) 格式（帶 YAML
frontmatter 的 SKILL.md 檔案），與 Claude Code、opencode 和 Cursor 使用的相同慣例。
Niffler 讀取的鍵為 `name`、`description`、`version`、`license`、
`tags` 與 `allowed-tools`（後兩者為清單）；`allowed-tools` 是
模型讀取的中繼資料，絕非強制限制。讀取/載入是透過匯流排的唯讀操作，唯一的寫入是
兩個受管理目錄中需經核准的
`skill_install`/`skill_remove` 配對；沒有任何工具會將 skill 加入 prompt——
載入是透過工具結果進行的漸進式揭露。

全部八個工具都是**隨需**（`x-harness.onDemand`）：沒有任何一個位於
會話凍結的直接工具集中，因此第一次取用某個工具是一次
`discover` + `invoke` 跳躍（參見 [Progressive tool
discovery](#progressive-tool-discovery)）。載入 skill 會將其文字附加
至歷史——這裡沒有任何東西會改寫凍結的 prompt 前綴，因此一次
`skill_load` 的代價是快取讀取，而非快取未命中。

探索涵蓋 repo 中隨附的 bundled skill，以及標準
agent 目錄（每個 skill 名稱以第一個命中者勝出——project 勝過 bundled
勝過 home 勝過 config）：

| Source | Directories |
|---|---|
| project | `$NIF_ROOT/.agents/skills`, `$NIF_ROOT/.claude/skills`, `$NIF_ROOT/.opencode/skills` |
| bundled | `<repo>/skills`——此 binary 被編譯所在的 checkout（一個建置時路徑）；`$NIF_ROOT/skills` 是搬遷部署的後備，且 `NIF_SKILLS_BUNDLED_DIR` 會覆寫兩者——永不可移除 |
| home | `~/.agents/skills`, `~/.claude/skills`, `~/.opencode/skills`, `~/.niffler/skills` |
| config | `~/.config/opencode/skills`（`npx skills add -g -a opencode` 安裝的位置） |

在單一來源內，目錄會依列出的順序嘗試，因此
`~/.agents/skills/nats` 會優先於 `~/.claude/skills/nats` 被提供。探索是
**每次呼叫都重新走訪**——沒有快取的 registry、沒有儲存紀錄、沒有
refresh 操作——因此一次
`skill_install` 或另一個 agent 的 `npx skills add` 會立即可見。
走訪不會深入**符號連結目錄**：只透過符號連結
到達掃描目錄的 skill 不會被探索，且
`skill_audit` 也不會列出它；**符號連結的 SKILL.md** 檔案
同樣不會被產出，因此 SKILL.md 是指向他處真實檔案的連結的 skill
同樣不可見（像
`~/.claude/skills → ~/.agents/skills` 這樣的符號連結農場因此不可見——當
連結目標本來就會被掃描時無害，不會時則悄然無聲）。

Bundled skill（`todo-markdown`——將 todo 狀態保存在 repo 的 TODO.md，
而非工具狀態；`niffler-tools`——哪個工具適合哪項工作；
`niffler-fabric`——建構 fabric 程式；`niffler-harness`——
操作執行中的 harness 本身）讓 Niffler 開箱即用；
將同名 skill 放入 project 或 home 目錄即可遮蔽其中一個。

當**沒有**任何 bundled 樹可達時——一個只隨附 `var/bin`
而無 repo checkout 的部署，其中 `<repo>/skills` 與
`$NIF_ROOT/skills` 皆不存在——探索會退回**編譯進 binary** 的 bundled SKILL.md
檔案。這些項目回報來源 `bundled`
與 dir `(baked)`；它們不帶任何資源（`skill_resources` 為空——
沒有任何 bundled skill 隨附資源），且永不可移除。磁碟一律
以名稱勝出，因此 checkout 不受此後備影響。

| Tool | What it does |
|---|---|
| `skill_list {query?, source?}` | 可用的 skill（name、description、version、license、tags、allowedTools、source、dir——`license`/`allowedTools` 是無作用的 metadata）；以子字串或 source 篩選；編譯進的後備項目回報 dir `(baked)` |
| `skill_search {query, owner?}` | 線上搜尋 skills.sh registry（`npx skills find` 的後端）：name、repo source、install count、slug 與 url（每次呼叫最多 20 筆命中；少於 2 個字元的查詢會在任何網路呼叫前被拒絕，失敗的呼叫會回傳 HTTP 錯誤文字）；`source`+`name` 配對可直接餵給 `skill_install` |
| `skill_load {name}` | 將 skill 的 markdown 主體（frontmatter 以欄位形式回傳）+ 其資源清單載入會話（載入機制）；超過 200 000 bytes 的主體會被截斷並標記 `truncated: true` |
| `skill_resources {name}` | skill 的 `references/`、`scripts/`、`assets/` 檔案，深入一層——`references/sub/x.md` 中的檔案，或符號連結的檔案，既不會被列出也無法讀取 |
| `skill_resource {name, path}` | 隨需讀取單一資源 |
| `skill_audit` | 磁碟上每個 SKILL.md 的唯讀、未合併清單——外加僅由編譯進的後備提供的名稱（dir `(baked)`）：標示每個名稱的作用中勝出者與每個被遮蔽/無效的副本（無效 = 無法讀取的 SKILL.md、無法解析的 frontmatter，或即使退回目錄名稱後仍無名稱——省略 `name:` 的 SKILL.md 會以其目錄名稱被接受；探索結果會在 `skill_list` 中合併，因此遮蔽只在此處可見） |
| `skill_install {repo, skill?, global?}` | clone 一個 git repo，將選定的 SKILL.md 樹複製到 `~/.niffler/skills`（預設）或 `$NIF_ROOT/.opencode/skills` |
| `skill_remove {name}` | 僅從 Niffler 管理的目錄刪除 skill |

- `skill_search` 是對 `https://skills.sh/api/search`
  的唯讀 HTTP 呼叫（未驗證）；它不受核准管制。每次呼叫最多回傳 20
  筆命中，且 `owner` 會縮小同一查詢——它不是獨立的
  命名空間。安裝流程為：搜尋 →
  `skill_install {repo, skill}` → 核准對話框 → 完成。

- 以 `npx skills add <owner>/<repo>`（skills.sh
  生態系 CLI）安裝的 skill 會落在上述標準目錄中，無需
  重新安裝即可被探索；`skill_install` 的存在是為了讓 Niffler 無需 Node 也能運作，透過純
  git。它只複製 SKILL.md 樹——不執行任何程式碼——並接受
  `owner/name`、github.com URL 與 `file://` 本機 repo（封閉測試）。
- 含有多個 skill 的 repo（例如 `vercel-labs/agent-skills`）需要
  `skill` 參數；缺少時 `skill_install` 會列出候選項。
  該參數會比對 skill 的名稱或其目錄 basename。
- `skill_install` 需要 `PATH` 上有 `git`：它會從
  `https://github.com/` 以 `--depth 1` clone 到
  `$NIF_ROOT/var/skills-tmp/<name>`（之後再移除）——較舊的 release 只能透過
  將 `repo` 指向鏡像來取得——並複製整個 skill 目錄，
  包含資源。它會拒絕目的地已存在的名稱
  （請先 `skill_remove`）；結果會回報 `source: home|project`。
- `skill_remove` 會拒絕 `~/.niffler/skills` 與
  `$NIF_ROOT/.opencode/skills` 之外的任何項目——其他 agent 安裝到共享
  目錄的 skill 應以它們自己的工具移除。
- Install 與 remove 帶有 `x-harness.approval: "always"`（它們會寫入
  `var/` 之外）。

## Provider registry (`provider`)

已設定的 LLM 後端是儲存紀錄，而非設定檔。`provider`
元件將它們保存在 kind `provider` 之下（id = 暱稱，外加
`active` 標記文件），並將它們暴露給 agent 與 `llm`：

這些工具沒有一個位於會話凍結的直接集合中：`provider_add`、
`provider_remove`、`provider_list`、`provider_switch`、`provider_models`、
`provider_export` 與 `provider_import` 是 `x-harness.onDemand`（可透過
`discover` + `invoke` 觸及），而 `provider_update`、`provider_status`、
`provider_active`、`provider_get`、`provider_use_environment` 與三個
OAuth 工具是 `x-harness.hidden`（僅限用戶端——`invoke` 會拒絕它們）。

| Tool | What it does |
|---|---|
| `provider_add {nickname, apiKey, protocol?, baseUrl?, model?, catalog?, context?, plugin?, stripPrefix?, active?}` | 新增或覆寫 API-key provider（以暱稱 upsert；`protocol`：預設 `openai-chat` 或 `anthropic`）；第一個 provider——API-key 或 OAuth——會自動成為作用中，除非 `active: false`；`stripPrefix` 會為以標準 id 路由的閘道，傳送不帶 `vendor/` 前綴的具命名空間模型 id（例如 `alibaba/glm-5.2` 的 `glm-5.2`）；回應會經遮蔽 |
| `provider_update {nickname, apiKey?, protocol?, baseUrl?, model?, catalog?, context?, plugin?, stripPrefix?}` | 供部分更新用的隱藏用戶端 API；省略的 API key 會被保留 |
| `provider_oauth_start {protocol, method?, nickname?, model?, active?}` | 隱藏，開始訂閱登入：`protocol` 為 `openai-codex`（ChatGPT Plus/Pro）或 `anthropic`（Claude Pro/Max）；`method` 為 `browser`（本機回呼）或 `device`（無頭，僅 OpenAI）。回傳 `{flowId, url, userCode?, callbackAvailable, expiresAt}` |
| `provider_oauth_complete {flowId, code?}` | 隱藏，輪詢/完成登入；在回呼（或貼上的 `code`）到達前回傳 `{pending, retryAfterMs?}`，然後儲存 provider 並以遮蔽形式回報 |
| `provider_oauth_cancel {flowId}` | 隱藏，取消待處理的登入並關閉其回呼監聽器 |
| `provider_list` | 所有已儲存的 provider（已遮蔽——無 key/token），以及哪一個是作用中；每個項目帶有 `authType`（`api_key`/`oauth`）、`protocol` 與 `expiresAt` |
| `provider_status` | 隱藏，經遮蔽的有效 provider，包含環境後備與 `hasKey` |
| `provider_active` | 隱藏，內部讀取有效 provider 的完整設定，含憑證 |
| `provider_get {nickname}` | 隱藏，內部完整設定讀取，用於在單一回合中釘選明確的已儲存 provider |
| `provider_models {nickname?\|baseUrl?, apiKey?, refresh?}` | provider 的 `/models` 端點目前提供的模型 id——以暱稱指定已儲存的 provider，或明確的 endpoint+key（連線表單，在憑證儲存之前）；兩種形態互為替代（若兩者皆給，`nickname` 勝出），且必須提供其一。每個 endpoint 磁碟快取 5 分鐘（探測失敗時提供過期快取）；錯誤會回傳給呼叫者，讓用戶端可退回 catalog |
| `provider_switch {nickname}` | 讓另一個已儲存的 provider 成為作用中；下一次 chat 呼叫（與 `llm_resolve`）會立即使用它，無需重啟 |
| `provider_use_environment` | 隱藏用戶端 API，清除已儲存的標記並回到 `NIF_OPENAI_*` |
| `provider_remove {nickname}` | 刪除 provider；若它原本是作用中，則由依字母序最前的其餘 provider 接手，否則恢復 `NIF_OPENAI_*` 後備 |
| `provider_export` / `provider_import` | JSON 備份/遷移往返，含憑證；import 會合併、驗證紀錄，並可還原作用中標記 |

暴露旗標，讓每列的說明無需被解析：`provider_oauth_*`、
`provider_status`、`provider_active`、`provider_get` 與
`provider_use_environment` 各列是**隱藏**用戶端 API（由 UI 或操作者
呼叫；模型永遠看不到它們），而 `provider_add`、`provider_update`、
`provider_list`、`provider_switch`、`provider_export` 與 `provider_import` 是
**隨需**——模型透過 `discover` + `invoke` 觸及它們。四個搬移憑證的工具帶有
`x-harness.approval: "always"`（見下），且
`provider_models` 在 20 秒逾時下執行。

省略的欄位採用協定預設值：`openai-codex` 推斷 ChatGPT 後端
URL，`anthropic` 推斷 Anthropic 的（在 `openai-chat` 下，`deepseek` 或
`openai` 暱稱會隱含自己的 base URL），模型預設為
`deepseek-chat`（`openai-chat`）、`gpt-5.4`（`openai-codex`）或
`claude-sonnet-4-6`（`anthropic`），且兩個 OAuth 協定會推斷其
models.dev catalog id（`openai`/`anthropic`）。

### Wire protocols

每個 provider 帶有 `llm` 據以路由的 `protocol`：

- `openai-chat`——OpenAI 相容的 Chat Completions 端點（預設；
  DeepSeek、OpenRouter、本機 vLLM……）。
- `openai-codex`——ChatGPT 的 Codex Responses 端點
  （`https://chatgpt.com/backend-api/codex/responses`），帶 ChatGPT OAuth
  標頭（`chatgpt-account-id`、`OpenAI-Beta: responses=experimental`）；
  訊息會被轉譯為 Responses API 輸入格式，且 SSE 事件
  串流（text/reasoning delta、function call）會被映射回
  共用的結果形態。
- `anthropic`——Anthropic Messages 端點；OAuth 登入會傳送 Claude
  Code 身分標頭與 beta，system prompt 以 Claude Code
  前言開頭，且工具呼叫/結果會被轉譯為 `tool_use`/`tool_result`
  區塊（連續的工具結果會合併為一則 user 訊息）；其用量會
  為 core 的計數器正規化——`prompt_tokens` 是輸入 + 快取讀取 +
  快取寫入，而只有快取**讀取**計為快取 token（快取
  寫入以寫入費率計費）。在全部三個協定中，`usage`
  物件僅在 provider 回報非零 token 時伴隨結果出現。

API-key provider 只能使用 `openai-chat` 或 `anthropic`：`openai-codex`
需要 ChatGPT 訂閱登入（`provider_oauth_start`），且
`provider_add` 會拒絕該組合。

### Output caps and `finish_reason`

輸出上限依協定拼寫，且拼錯的上限會默默失敗。
Niffler 的預設拼寫是 `max_completion_tokens`；DeepSeek 只認
`max_tokens`，因此以預設方式送出的上限會被忽略，而伺服器自身的
預設值（依模型為 8K/64K/128K）會生效——對 DeepSeek
端點請送 `max_tokens`。Anthropic 通道一律以
`max_tokens` 接收解析後的視窗；Codex 通道則完全不被告知上限。串流如何結束會
在 `finish_reason` 中回報：`length` 表示輸出上限截短了回覆
（`llm` 會記錄一則截斷警告），`tool_calls` 表示模型停下來呼叫
工具，而 Anthropic 的 `max_tokens` 停止會映射為 `length`（其 `tool_use` 停止
映射為 `tool_calls`）；Codex 的 `max_output_tokens` 結束與其
`response.incomplete` 事件同樣映射為 `length`，而無法辨識的
原因會原樣通過以供記錄。兩個 OpenAI 相容的錯誤
結束，`aborted` 與 `insufficient_system_resource`，會以 HTTP 200 抵達，
並被呈現為可重試的串流錯誤，而非回覆。一個從不
回報 `finish_reason` 的轉接器會失去這兩個訊號——沒有截斷警告，且一個在上限處被截斷的空
completion 會被當作普通空回覆重試，而非以 `the provider cut the reply at the output cap before any
content` 結束回合；`llm-openai` 範例不回報任何一個。

### Subscription OAuth (ChatGPT Plus/Pro, Claude Pro/Max)

`provider` 元件實作與 Pi 及 opencode 相同的 PKCE 登入流程（固定的 localhost 回呼埠、手動重新導向/代碼備援，以及供無介面機器使用的 OpenAI 裝置代碼流程）。已啟動的流程會在 15 分鐘後過期；`provider_oauth_start` 會傳回其 `expiresAt`（epoch 毫秒），因此被放棄的登入永遠無法在之後完成：

1. `provider_oauth_start` 傳回授權 URL；互動式用戶端會在系統瀏覽器中開啟它。OpenAI 另外提供 `device` 登入（在 `auth.openai.com/codex/device` 輸入的短代碼）。
2. `provider_oauth_complete` 會輪詢直到授權完成，接著交換代碼並儲存 provider —— `authType: "oauth"`，附帶存取權杖、重新整理權杖、到期時間，以及（對 ChatGPT 而言）從 JWT 擷取的帳號 id。
3. 每次憑證讀取（`provider_active`、`provider_get`、狀態解析）都會在距到期 5 分鐘內時透明地重新整理權杖，並保存輪替後的憑證。`llm` 元件永遠不會看到重新整理權杖。

環境調校項：`NIF_OAUTH_CALLBACK_HOST`（預設 `127.0.0.1`）會移動本機回呼監聽器（埠維持固定為 1455/53692，與參考用戶端相同）。匯出內容包含有效的重新整理權杖 —— 請將 `provider_export` 的輸出視為機密。

備援後端會以暱稱 `default`（`source: environment`）呈現自己，其中 `NIF_OPENAI_BASE_URL` 預設為 `https://api.openai.com/v1`，`NIF_OPENAI_MODEL` 預設為 `deepseek-chat`；`provider_use_environment` 會清除作用中標記，它不會刪除已儲存的 provider。

互動式用戶端以斜線命令暴露相同的操作：`/provider <nickname>`（別名 `/providers`）切換全域後端，`/provider environment`（別名 `/provider env`）回到這裡，而 `/provider strip [off]` 切換作用中 provider 的廠商前綴剝除；UI 的 provider 管理員將相同的工具（`provider_add`/`provider_update`/`provider_remove` 以及 OAuth 啟動/完成/取消流程）包裝在核准提示之後。

- `provider_add`/`provider_update`/`provider_import`/`provider_export` 帶有 `x-harness.approval: "always"` —— 它們會移動憑證或變更連線設定。互動式用戶端在使用者明確動作後直接呼叫隱藏的 update/status 工具，且絕不得呈現/記錄憑證承載內容。
- `llm` 在每次聊天呼叫時從作用中的已儲存 provider 解析其預設後端，因此 `provider_switch` 會立即生效。當 `provider` 元件不存在或沒有作用中的項目時，`llm` 會如以往退回 `NIF_OPENAI_*` 與 `NIF_LLM_PROVIDERS` 表。對 `chat` 或 `llm_resolve` 明確傳入 `provider` 引數時，會先解析已儲存的暱稱，再解析 `NIF_LLM_PROVIDERS`，因此會話可以在其回合中釘選非作用中的已儲存 provider，而不切換全域預設值。
- 已儲存 provider 的明確 `context`（權杖數）優先於模型目錄；其 `catalog` id 為 context 查詢命名 models.dev provider，而 `plugin` 是資訊性中介資料，命名擁有此 provider 額外工具的元件 —— `provider` 既不啟動也不驗證它，因此被命名的元件必須另行生成，且只能對 `ev.provider.switch` 做出反應。每次切換時，元件會發佈 `ev.provider.switch {nickname, previous, source, at}`，讓這類外掛可以啟用或隱藏其工具。每次登錄變更也會發佈不含機密的 `ev.provider.changed {op, nickname, active, source, at}` —— `op` 是 `add`、`update`、`switch`、`remove`、`import`、`login` 或 `refresh` 之一 —— 供互動式用戶端使其 provider/模型檢視失效。
- `active` 標記是一個單純的儲存文件（`{nickname, updatedAt}`）—— 以 `expectRev` 0 寫入 —— 而懸空或空白的標記會在下次讀取時自動刪除，因此 `provider_remove`/`provider_use_environment` 不需要手動修復；`store` 工具仍在那裡供你手動手術，如果你想要的話。
- 切換改變的是 harness 全域預設，而不是被釘選的對話：provider 與 model 成對地釘選在對話標頭中（見上文對 `session` 呼叫的說明），因此被釘選的對話仍在其自身的 provider 下解析，切換永遠不會把它的 model 送往不支援該 model 的 provider。沒有釘選的對話則跟隨全域預設。當被釘選的組合仍然沒有目錄匹配時，解析會退回保守的預設視窗，而狀態幀會攜帶一個 `warning`，指名該組合以及實際取得的視窗——正是這種漂移曾讓一份健康的紀錄被測量為 128k 後備視窗的 262% 並裁剪自身。

## Hooks

`hooks` 元件（預設關閉 —— 這是自動啟動旗標，不是建置旗標：`make build` 會像每個元件一樣編譯該二進位檔，因此啟用它需要 `NIF_HOOKS_*` 加上 `spawn {name: "hooks", binary: "<root>/var/bin/hooks"}`）會在選定的匯流排事件觸發時執行操作者的 shell 命令 —— 這是 CodeWhale 的 hooks 中僅觀察的子集（docs/research/CODEWHALE.md）。一個 hook 就是一個單純的行程：事件**承載內容**會以 pretty JSON 經管道送到命令的 stdin —— 信封會被剝除，而非信封的訊息會以原始位元組通過，因此 hook 會在頂層讀取承載內容的欄位（`jq -r .msg`，絕不是 `jq -r .payload.msg`）—— 寫入暫存檔（`getTempDir()/niffler-hook-<pid>-<n>.json`，預設權限：請像對待擷取目錄一樣對待它）並 `cat` 進 hook，絕不插值到命令列中 —— 失敗與逾時（預設 10 秒，最大 60 秒）會被記錄且絕不致命，而承載內容上限為 256 KB，並附加截斷標記。這裡刻意沒有操控/否決：核准決策存在於核心的派送閘門中。它完全不註冊任何工具 —— 介面就是環境與匯流排 —— 且在沒有相符的 `NIF_HOOKS_<SUBJECT>` 設定時，它會記錄 `watching nothing, staying up` 並持續執行。

設定是基於環境變數，於開機時讀取（`.env` 變更會套用至重新生成的元件；在核心 shell 中匯出的變數則需要重新啟動 harness）：

```bash
NIF_HOOKS_EVENTS="ev.session.*.turn,ev.log.error"   # subjects to watch
NIF_HOOKS_EV_SESSION_TURN='notify-send Niffler "turn finished"'
NIF_HOOKS_EV_LOG_ERROR='jq -r .payload.msg | mail -s Niffler you@example.com'
NIF_HOOKS_TIMEOUT_MS=10000
```

萬用字元遵循 NATS：`*` 恰好符合一個主體權杖，而尾端的 `>` 符合其餘部分，因此 `ev.session.*.turn` 會對每個對話已完成的回合觸發，而 `ev.log.>` 會對每個日誌事件觸發（會話 id 隨主體與承載內容傳遞）。重疊的規格是安全的：符合其中兩者的訊息仍只會執行第一個相符的命令**一次** —— 元件會依每個送達的訊息去重（一個以信封 id 與命令為鍵的 256 項環狀緩衝區），因此清單不必互斥。

主體 → 環境變數名稱：點與萬用字元會變成 `_`、轉為大寫，並將 `*.` 與 `>.` 摺疊，使標準名稱得以保留（`ev.session.*.turn` → `NIF_HOOKS_EV_SESSION_TURN`）；結束規格的萬用字元會貢獻自己的底線，因此 `ev.log.>` 與 `ev.log.*` 都是 `NIF_HOOKS_EV_LOG__`。實作範例 —— 桌面通知、音效警示、電子郵件、webhook、錯誤追蹤 —— 位於 `components/hooks/README.md`。值得觀察的事件是 `ev.session.<id>.turn`（回合邊界）、`ev.session.<id>.done`（帶有 `reply`）、`ev.session.<id>.status`（每個 LLM 回合）、`ev.session.<id>.context`（warn/trim/reset）以及 `ev.log.<component>`；其承載內容欄位列於 [The bus in one screen](#the-bus-in-one-screen) 之下。比對是以逗號分隔清單上的首個相符者勝出，而在開機時其 `NIF_HOOKS_<SUBJECT>` 未設定的主體會被忽略 —— 元件只會對它將執行的 hooks 記錄 `watching …`。

一個**失敗**的 hook 的合併輸出會回顯到元件的 stderr，並落入 `var/logs/hooks.log`（監督程式會將子行程輸出重新導向到那裡）；以 0 結束的 hook 其輸出會被丟棄。兩條路徑都不會寫入 logfile 的 JSONL，後者只保存匯流排流量。

`make test-hooks`（`tests/t_hooks.nim`）是冒煙測試：它會以 `NIF_HOOKS_EV_SESSION_TURN` 啟動元件、發佈一個 `ev.session.<id>.turn`，並檢查解碼後的承載內容是否到達 hook 的 stdin。

## Fetch

`fetch` 元件是網頁存取工具（舊 niffler `fetch` 工具的移植）。一個隨需工具 —— 模型透過 `discover` + `invoke` 觸及它；它永遠不是對話凍結直接集合的一部分：

| Tool | What it does |
|---|---|
| `fetch {url, method?, headers?, body?, timeout?, maxSize?, convertToText?}` | 對 http(s) URL 執行 GET/POST/PUT/DELETE/HEAD/OPTIONS/PATCH；HTML → 透過 Trafilatura 或純 Nim 備援轉為乾淨文字；跟隨重新導向；強制上限（`timeout` 預設 30 秒，最大 120 秒） |

- `convertToText`（預設 true）會從 HTML 擷取可讀文字 —— JSON 承載內容一律逐字傳回。轉換僅對 `text/html` 回應執行（XHTML 會在 `Accept` 中宣告，但會以原始形式傳回）；從未轉換的呼叫會回報 `extractionMethod: "none"`。
- 擷取是一道階梯：`trafilatura`（在 `$NIF_FETCH_DIR` 下的暫存目錄中給予已下載的 HTML，限制為 30 秒）→ 內建的 `htmlparser` 走訪 → 原始主體（`extractionMethod: "raw-fallback"`）。缺少可執行檔、非零結束、逾時或空輸出都會靜默地退回。將 `NIF_TRAFILATURA` 設為可執行檔路徑/名稱以覆寫偵測，或設為 `off`/`0`/`false`/`none` 以停用它。
- 回應上限為 `maxSize`（預設 10 MiB，最小 1024 位元組，最大 50 MiB）；處理後超過 200 KB 的內容會寫入 `$NIF_FETCH_DIR`（預設 `$NIF_ROOT/var/fetch`）下唯一的 `fetch_<rand>.txt`，而工具結果會變成 `Content saved to file (over 200000 bytes after processing): <path>`，因此代理會以自己的檔案工具讀取大型頁面，而不是撐爆對話。沒有任何東西會修剪那些檔案 —— 該目錄會持續成長直到操作者清除它，而它同時也存放 trafilatura 的暫存工作目錄。
- 錯誤（非 2xx、逾時、過大回應、無效 URL/方法）會以 `ok: false` 連同狀態與主體片段傳回：HTTP 錯誤帶有 `extra.status` 以及剝除後主體最多前 500 位元組，而超過 `maxSize` 的回應就是這樣的錯誤，絕不是溢出。成功結果帶有 `finalUrl`（重新導向後）、`status`、`contentType`、`contentLength`、`convertedToText`、`extractionMethod`、`savedToFile` 與 `filePath`。
- 請求在送出前會先驗證，且每個重新導向跳點都會重新驗證：僅限 http(s)、URL 最多 2048 個字元、不得有 URL 憑證，且每個解析出的位址都會檢查 —— loopback、private、link-local、CGNAT、multicast、`localhost`/`.local`/`.internal`，以及空白或失敗的 DNS 答覆都會被拒絕（失敗即關閉：`"hostname resolves to a private address: <host>"`、`"cannot validate hostname <host>: <msg>"`）。`NIF_FETCH_ALLOW_PRIVATE`（`1`，或 `true`/`yes`）會為受信任的本機服務繞過該檢查。
- 重新導向：最多 5 個跳點，每個都會重新驗證；301/302/303 會變成 GET，並捨棄主體與 Content-Length/Content-Type/Transfer-Encoding，307/308 則保留方法與主體；缺少 `Location` 或非 http(s) 目標即為錯誤。呼叫者的 `headers` 會覆寫預設值（`niffler-fetch/0.1` UA、類 HTML 的 `Accept`、`Accept-Language`）。
- 沒有核准閘門（如同 `plugin_search`），但該工具未宣告任何 `x-harness.effect`，因此 fabric 批次主機會將 `fetch` 排程為寫入並獨佔執行它。

## Language servers (`lsp`)

狀態：**已實作**（Nim 元件；確定性 fixture 測試；niffler-tui 用戶端新增 `/lsp` 登錄選擇器）。

在任何 stdio 語言伺服器之上的一個通用接縫。該元件不認識任何語言：哪個伺服器處理哪個副檔名是**資料** —— 一個內建合理預設值的登錄。新增語言是設定項目，絕不是程式碼（AGENTS.md 不變量：語言無關核心）。`repomap` 元件是目前例外：地圖語言需要其文法被納入 `components/repomap/csrc/` 之下、在 `ts.nim` 中有一個 `{.compile.}` 項目、一個 `queries/<lang>-tags.scm`，以及其在 `tags.nim` 中的副檔名 —— 該層級清單是此接縫目前的限制，不是政策。

### The tools

| Tool | What it does |
|---|---|
| `lsp {operation, path, query?, line?, character?, workspaceRoot?}` | 對檔案的語言伺服器執行一次查詢：`diagnostics`（無需執行測試的編譯器/lint 錯誤）、`documentSymbol`（檔案大綱：每個符號附帶種類、名稱與從 1 開始的位置 —— 不需要 line/character）、`workspaceSymbol`（全 repo 符號搜尋 —— 一個模糊 `query` 字串；伺服器會在暖機後建立其索引，因此第一次呼叫可能需要重試）、`goToDefinition`、`findReferences`、`goToImplementation`、`hover` —— 或 `warmup`：以目錄作為 `path`（或 `workspaceRoot`），普查其語言並預先啟動其伺服器 |
| `lsp_servers {}` | 列出已設定的伺服器（唯讀、免核准），附帶來源：`builtin` 預設或 `user` 登錄項目 |
| `lsp_registry {action: add\|remove, name, command, extensions?, initializationOptions?, requires?, cheap?}` | 變更使用者登錄（受核准閘門的寫入）。`add` 接受 `{name (lowercase letters/digits/hyphens), command, extensions: {".ext": "languageId"}}`，會覆寫同名的內建項目，並以 `E_LSP_CONFLICT` 拒絕已對應至另一個伺服器的副檔名（請先移除該對應）；`remove` 只刪除使用者項目 |

模型傳送從 1 開始的 line/character（UTF-16，符合 LSP 的 code-unit 慣例）；`findReferences` 一律包含宣告；結果有上限（100 個位置 / 約 16 000 個字元），並附帶截斷中介資料；結構化
`[E_LSP_*]` 錯誤（`E_LSP_UNAVAILABLE`、`E_LSP_UNSUPPORTED`、`E_LSP_TIMEOUT`、`E_LSP_SCOPE`、`E_LSP_PROTOCOL`、`E_LSP_REGISTRY`、`E_LSP_CONFLICT`、`E_NOT_FOUND`、`E_NOT_TEXT`、`E_BAD_SHAPE`）讓呼叫者依代碼而非文字來路由 ——
逾時與協定錯誤會附加伺服器的最後一行 stderr，該行會指出實際的失敗（缺少二進位檔、崩潰、索引中）。

**範圍是界限，不是相等。** 對話工作區內的檔案會在工作區根目錄下被索引（其已暖機的伺服器會被重用）；在其*之外*的檔案 —— 同層 checkout、git worktree、代理正在工作的任何其他目錄 —— 會在其自身由標記衍生的根目錄下被索引，且回覆會帶有命名它的 `workspaceRoot`，因為否則答案中的相對路徑會有歧義。`E_LSP_SCOPE` 僅保留給兩種會把無界樹交給伺服器的情況：路徑中含有 `..` 元件，以及檔案的標記走訪到達檔案系統根目錄或 `$HOME`（訊息會要求明確的 `workspaceRoot`）。直接拒絕工作區外的檔案曾被嘗試過，且實際上是有害的：edit 工具的診斷推送會將該拒絕吞掉為「未設定伺服器」，因此代理在另一個 checkout 中工作時既得不到診斷，也得不到它沒有的訊號。

**edit 工具對已知語言的自動推送絕不靜默。** 每次成功編輯後，它會非同步地排入診斷 —— 該檢查在 lsp 元件的閒置接縫中執行，而判定會經由對話的 `.diag` 通道傳遞 —— 且編輯結果會命名該通道，因此「已檢查且乾淨」永遠不會看起來像「什麼都沒發生」。當檢查無法被排入時（檔案在對話工作區之外，或無法觸及 lsp 元件），編輯結果會改為如此說明，並附上原因。靜默僅保留給其副檔名沒有任何登錄項目聲稱的檔案：`.md` 檔案不干任何語言伺服器的事。

這三個工具都是**隨需**（`discover`/`invoke` —— 見 [Progressive tool discovery](#progressive-tool-discovery)），讓凍結的工具集保持精簡；工具描述是模型的使用時機指南。`lsp` 工具是唯讀且免核准；`lsp_registry` 會寫入登錄檔並受核准閘門管制。

### Model usage

典型回合：

- 在編輯不熟悉的程式碼之前：對符號執行 `goToDefinition`/`hover`，
  而不是從 grep 的匹配結果猜測。
- 在編輯編譯式語言之後：對被觸及的檔案執行 `diagnostics`——
  一次呼叫就取得編譯器的判定，而不必跑一輪完整測試。
- 當文字匹配有歧義時：`findReferences` 以語意方式解析該符號。

查詢會短暫開啟文件（以當前位元組 `didOpen` → 請求 → `didClose`），因此每次查詢看到的都是磁碟上此刻的檔案——包括 agent 自己剛寫入的編輯——而開啟的位元組也會以 `didSave` 回送，因為以 nimsuggest 為基礎的 Nim 伺服器只在儲存時發佈診斷（對 pyright、clangd 和 bash-language-server 這類 open-push 伺服器而言是無操作）。每個 (伺服器, 工作區) 保留一個伺服器行程並在多次查詢間重複使用；逾時或協定錯誤會拆掉該實例，讓下一次查詢從頭開始，且最多保留八個存活實例（LRU 淘汰）。每次查詢有 60 秒的預算，`initialize` 握手有 30 秒，都在工具的 90 秒包絡內；診斷在第一次推送後等待 1.5 秒才定案。相對的 `path` 會對會話工作區解析；若沒有明確的 `workspaceRoot`，伺服器根目錄會從該檔案語言最近的模組標記推導（`go.mod`/`go.work`、`Cargo.toml`、`tsconfig.json`/`package.json`、`pyproject.toml`、`*.nimble`/`config.nims`、`compile_commands.json`/`CMakeLists.txt`），然後是 `.git`，然後是工作區——向上走訪絕不會爬升到工作區之上，且標記是按副檔名建立的，因此純粹以登錄項加入的語言仍保有 `.git`/工作區的後備。只有 `..` 元件或會觸及檔案系統根目錄或 `$HOME` 的標記走訪會被拒絕（`E_LSP_SCOPE`，要求明確的 `workspaceRoot`）。

當會話工作區被宣告時（`ev.workspace.opened`），Core 會自動觸發一次**預熱**：元件執行一次有界的副檔名普查（在 5 000 個檔案或 2 秒預算時停止；隱藏檔案與垃圾目錄如 `node_modules`、`vendor`、`dist`、`build` 和 `target` 會被跳過），並為最普遍的語言預先啟動伺服器，讓第一次真正的查詢不必付出伺服器啟動成本。接著它發佈 `ev.lsp.warm {workspace, warmed, skipped}`，讓 UI 能顯示哪些伺服器已啟動、哪些被跳過。`warmup` 操作會明確重跑同一條路徑。

未配置的語言會降級，絕不會中斷：沒有伺服器（或缺少二進位檔）的副檔名會回傳 `E_LSP_UNAVAILABLE`，訊息中附帶修正方式——「add one with the lsp_registry tool (or edit <registry path>)」。模型會自行退回使用 grep/read。

### Registry: adding a language

三條路徑，全都寫入同一個檔案：

1. **TUI 選擇器**——在 niffler-tui 中執行 `/lsp`：瀏覽已配置的伺服器，`a` 新增（名稱、命令、副檔名——例如 `elixir-ls`、`elixir-ls`、`.ex, .exs`），ctrl+s 儲存（人工核准提示，因為它會寫入配置）；`e` 編輯（內建項會以覆寫形式開啟），`d` 移除使用者項目。
2. **請 agent 處理**——「register elixir-ls for Elixir files」→ 模型自己呼叫 `lsp_registry add`（同樣的核准關卡）。
3. **直接編輯檔案**——`$XDG_CONFIG_HOME/niffler-lsp/servers.json`：

```json
{
  "elixir-ls": {
    "command": ["elixir-ls"],
    "extensions": {".ex": "elixir", ".exs": "elixir"}
  }
}
```

每個項目：`command`（argv 陣列，或以空白分割的純字串）加上 `extensions` 映射（前導點副檔名 → LSP 語言 id）。選用的 `initializationOptions` 會傳遞給伺服器的 `initialize`。另外兩個選用鍵承載了過去寫在程式碼裡的內容：`requires`（必須能解析的執行時二進位檔，例如 jdtls 的 `["java"]`——執行時缺失的伺服器會回報自身，而不是生成後死亡）和 `cheap`（不索引任何東西、因此不佔用重量級預熱名額的伺服器；bash-language-server 是內建範例）。
內建預設——gopls、nimtortoise、typescript-language-server、pyright、rust-analyzer、clangd、bash-language-server、jdtls、intelephense、solargraph、csharp-ls——只要二進位檔在 `PATH` 上或位於後備目錄（`~/go/bin`、`~/.nimble/bin`、`~/.local/bin`、`~/.dotnet/tools`、`~/bin`）即可運作；`make install-lsp` 會以冪等方式安裝它們（Go、Nim 和 TS 是強制的——Niffler 由它們建構——其餘是 y/n 提示，`make install-lsp ALL=1`（`--all`）用於無人值守安裝，非 TTY 執行會跳過選用語言；不會用 `sudo` 安裝任何東西——只在 `$HOME` 之下——且缺失的執行時（JDK、.NET SDK、rustup）會連同確切命令一併回報，而不是自動安裝；同一個腳本也會安裝下方的使用者本地 JDK。每個語言的失敗都是非致命的：lsp 工具只會以 `E_LSP_UNAVAILABLE` 跳過它；每個語言的失敗都是非致命的：lsp 工具只會以 `E_LSP_UNAVAILABLE` 跳過它；`NIF_LSP_BIN` 覆寫安裝目錄，預設 `~/.local/bin`，它同時也是預設的後備 bin 目錄）。Java 是唯一連*執行時*也會安裝的語言：當 `PATH` 上沒有 JDK 17+ 時，會在 `~/.local/share/niffler-lsp/jdk` 下安裝使用者本地的 JDK 21（免 sudo，如同伺服器下載）——過去沒有 JRE 的 jdtls 包裝器會回報「ok」然後在查詢中途死亡。
以同名項目新增即可覆寫其中一個。登錄檔在每次呼叫時都會重新讀取，因此編輯立即生效；格式錯誤的檔案或項目會以 stderr 上的警告跳過（可在 `var/logs/lsp.log` 中看到），而不是讓查詢失敗。

將 `NIF_LSP_REGISTRY` 設為絕對路徑即可搬移使用者登錄檔（測試、多 harness 設置）。

**預熱預算。** Core 在會話啟動時發佈 `ev.workspace.opened`；元件普查工作區（有界走訪）並預先啟動伺服器，讓第一次真正的查詢不必付出冷啟動成本。重量級伺服器——會索引整個工作區的那些（gopls、rust-analyzer、jdtls、clangd、pyright、intelephense、solargraph）——上限為 `NIF_LSP_WARM_MAX`（預設 2）個名額；*cheap* 伺服器不索引任何東西，有自己的預算（`NIF_LSP_WARM_CHEAP`，預設 1，且僅在 2 個以上匹配檔案時），且絕不會取代重量級名額——在一個滿是 `.sh` 檔案的 repo 上，bash-language-server 否則會從任務實際撰寫所用的語言手中搶走兩個名額之一。`NIF_LSP_WARM_TOTAL`（預設 4）為每個工作區預先啟動的行程設上限。`requires` 執行時缺失的名額會回報在 `skipped` 中（「jdtls (needs 'java')」），而不是被啟動。

## Repository inspection (`git`)

狀態：**已實作**（Nim 元件；`tests/t_git.nim`）。

git 工作流程的唯讀一半，作為一等工具；寫入的一半（add/commit/push/checkout/restore）留在 `bash` 中，受核准關卡管制。每個子命令都以固定 argv 執行（`--no-optional-locks -c color.ui=false -c core.quotepath=false --no-pager`），絕不透過 shell，並以 `-C <repo>` 限定範圍——旗標、ref 和路徑都逐位元組傳遞。

| Tool | What it does |
|---|---|
| `git_status {repo?, path?}` | 當前分支，加上每個已變更檔案一行 porcelain 輸出；未追蹤的檔案出現在這裡，絕不出現在 `git_diff` |
| `git_diff {repo?, path?, unified?=3, stat?=false}` | 自 HEAD 以來的一切變更，已暫存**和**未暫存（`unified` 夾在 0..50；`stat: true` 是每檔一行的摘要） |
| `git_log {repo?, path?, max_count?=20, author?}` | 近期歷史，每個 commit 一行（`max_count` 夾在 1..200；`author` 是子字串） |
| `git_show {repo?, rev, path?}` | 完整顯示一個 commit：中介資料、訊息、完整 diff（`rev` 必填） |
| `git_blame {repo?, path, start_line?=1, max_lines?=200}` | 逐行歸屬；未提交的行顯示 `Not Committed Yet` |
| `review_receipt {op?="write", findings?, model?}` | 本地審查收據的寫入/檢查配對（見下） |

全部六個都是**隨需**（`discover`/`invoke`），且五個讀取工具帶有 `parallel: true` 和 45 秒包絡。空的或相對的 `repo` 在 core 注入呼叫時（會話回合）會對會話工作區解析；直接匯流排呼叫則對元件的 cwd（harness 根目錄）解析。`path` 絕不被改寫——它以 `-- <path>` 傳遞並對 `repo` 解析。

**失敗與拒絕語意。** 參數拒絕絕不會啟動 git：它們以退出碼 2 回傳，並帶有 `(exit 2 — refused)` 前綴（不存在或含 `..` 的 `repo`；絕對或含 `..` 的 `path`；看起來像選項、含空白或過大的 `rev`；以 `-` 開頭或過大的 `author`）。真正的執行回傳 git 的退出碼與 git 自己的輸出；`124` 會加上 `[timed out]` 前綴，而帶有「not a git repository」的 `128` 會加上 `[no git repository at the target directory]` 前綴。空結果會得到友善標記（`[no changes since HEAD]`、`[no commits matched]`）；其餘一切都是原始 git stderr，因此 **detached HEAD** 就只是 git 的 `## HEAD (no branch)`，而損壞的索引就是 git 的 fatal 文字加上退出碼 128——兩者都不特別處理。輸出有兩重界限：保留 40 000 位元組的頭+尾（帶有 `truncated N of M bytes` 標記），以及每個工具的行數上限——`git_status` 200 行、`git_diff` 10 000（使用 `stat` 時 500）、`git_show` 10 000、`git_log` 和 `git_blame` 為其計數加一——每個都附帶「narrow the scope」提示。

**審查收據。** `review_receipt` 是這裡唯一的寫入側工具，也是唯一沒有核准關卡的 git 工具：它只會寫入 `var/review-receipts/` 下的檔案。`op: "write"` 將工作樹 diff 的 SHA-256 指紋（加上選用的 `findings` 和 `model`）記錄為 `rr-<unix>-<fp8>.json`（`schema_id: "niffler.review-receipt/v1"`、`id`、`created_at`、`diff_fingerprint`、`note`）；`op: "check"` 將當前 diff 與最新收據比較——相符時退出碼 0 加上收據 id，diff 已變動時退出碼 1 並帶有 `receipt_fingerprint` 和 `current_fingerprint`，而沒有收據、全都無法解析或 diff 為空時退出碼 1 並帶有 `detail`。它絕不呼叫模型。

**git 二進位檔。** `git` 必須能在 `PATH` 上解析，而命中元件自己的 `var/bin/git` 的 `PATH` 會被跳過（那會遞迴）；無法解析的 git 回傳退出碼 127 並附帶安裝提示。

## Background processes (`processes`)

狀態：**已實作**（Nim 元件；`tests/t_processes.nim`）。

bash 依設計是同步的——伺服器、監看器和測試迴圈需要不同的契約：啟動一次、輪詢增量輸出、明確終止。

| Tool | What it does |
|---|---|
| `process_start {command, label?, workdir?}` | 分離生成命令（自己的行程群組、stdin 來自 /dev/null、stdout/stderr 附加到 `var/processes/` 下的 spool 檔案）並立即回傳其 id。受核准關卡管制。透過 `bash` 工具的 `run_in_background` 進行的背景啟動只在 `bash` 呼叫本身核准一次——內部的 `process_start` 直接走 NATS，絕不經過 core 的核准關卡，而透過 core 發出的直接 `process_start`（模型，或任何經由 `svc.core.call` 觸及的工具）則受管制——自行定址 `svc.processes.call` 的匯流排客戶端（`cli`、腳本）完全不受管制 |
| `process_poll {id, waitMs?, filter?, tail?}` | 排出自上次輪詢以來附加的輸出——增量，絕不重新注入舊位元組；`waitMs` 阻塞直到有新輸出或退出（上限 25 秒）；`filter` 是對新行的正規表達式（排出游標仍會前進越過全部）；任何非空的 `tail` 會重新讀取原始輸出的最後約 64 KB。讀取效應 |
| `process_kill {id}` | 終止整個行程群組——SIGTERM、300 毫秒寬限，然後 SIGKILL。受核准關卡管制 |
| `process_list {}` | 顯示登錄檔——執行中與最近完成的項目及其退出碼。讀取效應 |

細節：

- 子行程以附加模式寫入 spool 檔案（絕不是可能死鎖的管道）；元件從每個串流的游標讀取，因此作業系統會吸收輸出突發。超過上限（32 MiB，`NIF_PROCESSES_SPOOL_CAP`）的 spool 會在下次輪詢時截斷至其尾部——保留最後 2 MiB，或在上限更小時保留上限的一半，且該次截斷輪詢會附加 `[spool truncated to its tail — the cap was reached]`；一次輪詢每個串流最多回傳 `NIF_PROCESSES_POLL_CHUNK` 個新位元組（預設 64 KiB）。
- 每個工具帶有自己的派送預算 `x-harness.timeoutMs`——`process_start` 20 秒、`process_poll` 30 秒、`process_kill` 15 秒、`process_list` 10 秒——與 `process_poll` 內部的 `waitMs` 上限分開。
- 上限：32 個並行行程。完成的項目絕不被淘汰：此元件生命週期內的每個行程都留在登錄檔中——只有*執行中*的會寫入 `registry.json`——因此 `process_list` 會持續將已完成的子行程回報為 `exited(code N)` 或 `killed(signal N)`，直到元件退出。
- **完成的行程會通知它的會話。** 當你透過 `bash` 工具的 `run_in_background` 旗標啟動一個行程時，bash 會把擁有它的會話交給登錄檔；當該子行程退出時，`processes` 會向其中發佈一則退出通知（與 subagent 結算通知使用同一條通道），因此接下來的回合會以 `[background process p3 (dev-server) exited(code 0)] ran 412s, 8123 bytes of output — read it with \`process_poll\` …` 開頭。它是個指標：輸出留在 spool 中，命令文字絕不傳遞。

  這就是為什麼背景工作不再被忽視：元件在週期性 tick（SDK 的 `onIdle`）上收割其子行程，而不只在有人輪詢時——這也意味著 `process_list` 會及時顯示 `exited(code N)`，而不是在被詢問前一直顯示 `running`。只有 `bash run_in_background` 會交出擁有它的會話（它是唯一傳遞 `session` 的呼叫者），因此以任何其他方式觸及的 `process_start`——模型自己的 `discover` + `invoke`、`cli`、腳本——都會在沒有擁有者會話的情況下啟動；會話執行器已退役的行程也不會被通知任何人。請輪詢那些。
- 工具錯誤帶有穩定代碼：`E_BAD_SHAPE`（空的 `command`、缺失的 `workdir`、無效的 `filter` 正規表達式）、`E_NOT_FOUND`（未知 id——`process_list` 會顯示登錄檔）和 `E_LIMIT`（32 個存活行程，或無法 fork 的子行程）。
- `process_list` 項目帶有 `started_at`（epoch 秒），因此客戶端可以顯示某個東西已執行多久——`bg 1 (7m)` 徽章是 `niffler-tui` 外掛的狀態列，不是 core 的。
- `workdir` 預設為會話工作區：core 會為空值或 `.` 值替換它，並對工作區（`x-harness.workspace`）解析相對路徑，而不存在的路徑會以 `E_BAD_SHAPE` 失敗。純匯流排呼叫（`cli call process_start`）會跳過該替換，因此子行程繼承元件自己的 cwd（`$NIF_ROOT`）。
- 崩潰安全：子行程是行程群組領導者，因此被 SIGKILL 的元件會讓它們繼續執行——`registry.json`（pid + /proc starttime，可擊敗 pid 重用）驅動一次開機清掃，在開始服務前殺掉前一次生命留下的孤兒。它們會在 `processes` 元件停止時死亡；若它反而被殺掉，下一次啟動會清掃剩下的。

全部四個工具都是隨需（`discover`/`invoke`）。bash 工具的 `run_in_background` 旗標是此元件之上的薄生產者：呼叫立即回傳 id——*工作*沒有逾時，但啟動它的 `bash` 呼叫仍受界限（其派送預算，以及其後 15 秒的 `process_start` 請求）——且逐字稿行指向 `process_poll`/`process_kill`。若元件未執行，bash 會回答 `[E_BACKGROUND]` 並建議同步執行該命令。

## External MCP servers (`mcp`)

狀態：**已實作**（manager + bridge + discovery 整合；UI 介面只是同一組工具之上的薄客戶端）。

Niffler 扮演 MCP **客戶端/主機**：每個設定好的外部 MCP 伺服器（Model Context Protocol）都會變成一個受監督的 bridge 行程，而伺服器的工具則成為一般的目錄工具——可被探索、可被呼叫，並與任何元件工具一樣受核准閘門管制。bridge 建構於官方 Go SDK（`github.com/modelcontextprotocol/go-sdk`）之上。

### Shape

```
store kind "mcp" (one record per server)
        │ owned by the mcp manager (components/mcp)
        ▼
spawn {name: "mcp-<server>", binary: var/bin/mcp-bridge, args: ["--server", <server>]}
        │ one supervised process per server (survives reboots via the
        │ component record; supervisor restarts it on failure)
        ▼
bridge announces mcp_<server>_<tool> schemas  ──►  catalog ──► discover/invoke
        │
        └── lazy MCP session ──► stdio subprocess / streamable-http / sse
```

bridge 只會以這種方式啟動（或由帶 `--probe` 的探測啟動）；其路徑為 `NIF_MCP_BRIDGE_BIN`，預設 `<root>/var/bin/mcp-bridge`，而 manager 會在子行程崩潰或漂移後重新 spawn。bridge 的 argv 不帶任何設定：它在啟動時重新讀取 `--server` 所指名的 `mcp` 記錄（因此該記錄始終是唯一真相來源），若該記錄已停用便立即結束。當記錄無法讀取，或其儲存的名稱與 `--server` 不符時，它會以 1 結束（此時 supervisor 會退避並重試），而 `--probe` 同樣需要 `--server <name>`——探測的設定是從 stdin 進來的。

- **命名**：工具會加上前綴 `mcp_<server>_<tool>`（niffler 小寫慣例，在目錄中全域唯一）；描述帶有 `[mcp:<server>]` 的來源前綴。伺服器名稱必須符合 `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`（≤32 字元，`bridge` 保留）；工具名稱會被清洗為相同的字母表並限制在 64 字元。manager 會拒絕那些產生的工具名稱與其他伺服器或目錄工具衝突的伺服器。
  每個 bridge 也會註冊一個隱藏輔助工具 `mcp_<server>_bridge_status
  {op: status|refresh}`（對 LLM 不可見），`mcp_servers` 會呼叫它以取得即時狀態，`mcp_refresh` 則用它來重新連線；`status` 帶有 `connected`、工具與 prompt 計數、`retiring`、`activeCalls`、`lastError`、`startedAt`、`lastUsed` 與 `idleMs`。
- **曝露**：預設為隨需（`x-harness.onDemand`）——schema 透過 `discover {component: "mcp-<server>"}` 進入會話，呼叫則經由 `invoke`，因此 MCP 伺服器永遠不會膨脹凍結的直接工具集。`"expose": "direct"` 會讓某個伺服器的工具加入每個新會話的快照——除非該伺服器發佈的工具數超過 `NIF_MCP_DIRECT_THRESHOLD`（預設 10），此時 bridge 會將整個伺服器延後為隨需。此閾值由 bridge 行程在宣告其工具時讀取，因此對該子行程的生命週期而言是固定的（要變更就重新 spawn bridge）。
- **延遲會話**：新增伺服器時會以一次真實連線（initialize + tools/list）驗證，並將工具清單快取於記錄中；MCP 子行程/HTTP 會話本身會在第一次工具呼叫時啟動，並在 `idleMs` 後閒置逾時（預設 5 分鐘；上限 24 小時）。每次呼叫會取得每次呼叫逾時（`timeoutMs`，預設 120 秒，上限 24 小時）。啟動 harness 永遠不必付出 `npx`/`uvx` 的啟動成本。
- **取消**：MCP 工具會宣告 `x-harness.sessionId`——會話執行器會將即時會話 id 注入為 `__session.session`，而被取消回合的 `cancel.mcp-<server>` 事件（docs/WIRE.md）會立即中止進行中的 MCP 呼叫。直接呼叫者（CLI 腳本）通常會取得 `""`，而未歸屬的呼叫永遠不可取消——只有其 `timeoutMs` 能限制它。在直接匯流排路徑上沒有任何東西會驗證此欄位，因此自行提供 `__session` 的呼叫者會指定其呼叫所比對的 id，而任何帶有該 id 的 `cancel.mcp-<server>` 都會取消它。
- **以參照取得機密**：`env` 值、`headers` 值、`args` 與 `url` 可包含 `${NAME}` 參照，會在 bridge 連線或 spawn 伺服器時從 harness 環境解析——儲存會保留佔位符，列表只回顯鍵名，而缺少變數會讓連線以清楚的錯誤失敗，而不是送出空憑證。單獨的 `$` 保持字面。
- **沙箱化**：stdio 伺服器在守護行程（`mcp-bridge
  --stdio-guard <cmd>`）下執行，該守護行程擁有伺服器的行程群組並監看生命線管道——若 bridge 死亡（包含 SIGKILL），守護行程會先 SIGTERM 再 SIGKILL 整個群組；核心的 `PDEATHSIG` 則為守護行程本身把關，因此 MCP 伺服器永遠不可能活得比其 harness 更久。stdio 伺服器會繼承固定的環境允許清單——`PATH`、`HOME`、`USER`、`LOGNAME`、`TMPDIR`/`TMP`/`TEMP`、`LANG`/`LC_ALL`、`SYSTEMROOT`、`SSL_CERT_FILE`/`SSL_CERT_DIR`、`XDG_CACHE_HOME`/`XDG_CONFIG_HOME`、`UV_CACHE_DIR`、`NPM_CONFIG_CACHE`——再加上記錄的 `env` 所增添的任何項目。`SHELL` 與 `TERM` *不會*被傳遞，而 harness 環境中的 `NIF_*` 變數與機密也永遠不會到達它們。HTTP/SSE 伺服器只會看到已設定的 `Authorization` 標頭，且僅當它們指向伺服器自身的來源時——憑證永遠不會被重放至跨來源的重新導向目標（該重新導向會被拒絕）。
- **結果大小**：MCP 結果 ≤64 KiB 會內聯回傳；較大的結果會溢出至 `$NIF_ROOT/var/mcp-results/result-*.json`，而工具會改為取得機器可讀的指標——`{text: <the first 16 KiB of the text
  plus a line naming the file>, spill: {path, bytes}, truncated: true}`
  （可用 `read`、`grep` 或 `bash` 讀取），因此大結果永遠不會撐爆上下文視窗。非文字內容部分與結構化內容會被 JSON 序列化進 `text`，而不是被丟棄。
- **漂移**：在每個全新會話（以及伺服器推送的
  `notifications/tools/list_changed`）時，bridge 會重新列出伺服器的工具；當契約變動時，它會持久化新的清單（盡力而為，rev 重試）並以 3 結束，讓 supervisor 重新啟動它並宣告當前真相。
  結束會等待進行中的呼叫完成，因此漂移永遠不會截斷呼叫。目錄與執行永遠不會長時間不一致。若該重新整理無法被持久化，bridge 會以*退役中*狀態失敗關閉，而不是陷入崩潰迴圈：`mcp_servers` 會顯示錯誤，而該伺服器需要 `mcp_refresh`（在進行中的呼叫完成後）或 `mcp_edit` 才能復原。
- **隔離**：每個伺服器一個行程；卡住或崩潰的伺服器無法拖垮其他伺服器（supervisor 的失敗退避會重新啟動它）。伺服器的工具在移除後，於既有會話中仍保留其凍結的 schema——此時呼叫會經由一般路由失敗。

### The record

每個伺服器一份儲存文件（kind `mcp`，id = 清洗後的伺服器名稱；`mcp_servers` 會列出它們，並將 env/header 的**值遮蔽**）：

```json
{
  "name": "filesystem",
  "type": "stdio",
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
  "env": {"API_KEY": "..."},
  "cwd": "",
  "enabled": true,
  "approval": "always",
  "expose": "ondemand",
  "effect": "write",
  "timeoutMs": 120000,
  "idleMs": 300000,
  "concurrency": "parallel",
  "tools": [{"name": "read_file", "description": "...", "inputSchema": {}}],
  "prompts": [{"name": "review", "description": "...", "arguments": [{"name": "code", "required": true}]}]
}
```

`type` 選擇傳輸方式：`stdio`（預設；`command`+`args`+選用的
`env`/`cwd`）、`http`（可串流 HTTP；`url`+選用的 `headers`）或 `sse`
（`url`+`headers`）。`approval: "always"` 會以人工核准提示、逐次呼叫的方式，對伺服器自身的每一個工具把關——`mcp_<server>_<tool>`、其資源工具與其 prompt 工具；`effect: "read"` 會將唯讀工具標記為可供 fabric 排程；`concurrency: "serial"` 適用於無法處理重疊呼叫的伺服器（預設為 `parallel`，經由 SDK 有界的 `ToolConcurrent`）。記錄的
`timeoutMs` 不只是執行時預算：bridge 會在註冊時將它寫入每個工具的
`x-harness.timeoutMs`，因此對該 bridge 行程的生命週期而言是固定的。
manager 擁有除了快取以外的每一個欄位：當伺服器漂移時，bridge 會改寫 `tools`
**與** `prompts`。

### Tools

全部位於 `mcp` 元件上，全部隨需。`mcp_add`、`mcp_edit` 與
`mcp_remove` 受核准閘門管制（它們所發出的 `core.spawn`/`core.remove` 亦然）；`mcp_refresh`、`mcp_servers` 與 `mcp_search` 則否——重新整理只會重新列出已核准的伺服器。

| Tool | Purpose |
|---|---|
| `mcp_servers` | 列出記錄 + 即時 bridge 狀態（已註冊工具、會話狀態、最後錯誤）。停滯的 bridge 永遠不會阻擋列表（1 秒狀態逾時，8 個並行）；若目錄無法觸及，該列會回報 `live: false` 而不是失敗 |
| `mcp_add` | 以一次真實連線驗證（經由探測模式的 bridge——設定從 stdin 進來，不經匯流排），將記錄與快取的工具清單一併儲存，並 spawn bridge。驗證逾時：30 秒，或若 `timeoutMs` 更高則採之（`NIF_MCP_PROBE_TIMEOUT_MS` 可覆寫）——`npx`/`uvx` 伺服器的首次執行會下載套件。`enabled: false` 會儲存擱置的設定，而不連線或 spawn（之後以 `mcp_edit {enabled: true}` 啟用）。若 bridge 未在 15 秒內註冊，記錄仍會被儲存，且呼叫會回傳 `ok` 外加一個指名 `var/logs/mcp-<server>.log` 的 `warning` |
| `mcp_edit` | 合併提供的欄位、重新驗證、重新 spawn（或在停用時停止） |
| `mcp_remove` | 對 bridge 執行 `core.remove`（不會在開機時復活）+ 刪除記錄 |
| `mcp_refresh` | 強制 bridge 捨棄其會話、立即重新連線並重新列出 |
| `mcp_search` | 以關鍵字查詢官方 MCP Registry 的伺服器（唯讀）；為可安裝的 npm/PyPI 項目回傳可直接使用的 `mcp_add` 引數 |

伺服器自身的工具只有在它的 bridge 已 spawn 之後才會出現在目錄中——就在 `mcp_add` 之後，或在開機時從還原的元件記錄而來。

因此，新增 MCP 伺服器在設計上會要求兩次核准：一次是 `mcp_add`
本身，一次是它所觸發的 `core.spawn`——這是對改變 harness 形狀的人工閘門（docs/ARCHITECTURE.md）。`mcp_edit` 同樣要求兩次（編輯，然後重新 spawn），而 `mcp_remove` 也要求兩次（移除，然後 `core.remove`）。

### Prompts, resources, registry

- **Prompt 會變成斜線命令。** 每個伺服器 prompt 都會註冊為一個
  隱藏目錄工具 `mcp_<server>_prompt_<promptname>`（對 LLM 不可見，`x-harness.hidden`），外加一個斜線命令 `mcp-<server>-<promptname>`，
  其具名參數會對應 prompt 的引數（每個伺服器 ≤32 個 prompt，每個 ≤16 個引數）；第二個隱藏泛用工具
  `mcp_<server>_prompt` 則為客戶端依名稱渲染任何 prompt。渲染 prompt 是一般的匯流排呼叫；
  結果會以 `userMessage` 攜帶渲染後文字，而 UI 會將它作為一則 **user** 訊息附加到會話（斜線結果慣例，
  `ui/frontend/src/lib/slashResult.ts`）——prompt 輸出永遠不會以 system/assistant 內容注入逐字稿。bridge 會在漂移時像工具一樣重新註冊它們（包含伺服器推送的 `notifications/prompt_list_changed`）。
- **資源**會以一個並行工具 `mcp_<server>_resources`
  浮現（`x-harness.effect: "read"`）：`{op: "list"}`、`{op: "templates"}`（URI
  範本）或 `{op: "read", uri: ...}`。
  文字結果遵循與工具結果相同的 64 KiB 內聯上限（較大者溢出至 `var/mcp-results`）；二進位 blob 會以 base64 連同 MCP
  mimeType 回傳。
- **Registry**：`mcp_search <query>` 會查詢官方 MCP Registry
  （`registry.modelcontextprotocol.io`；以 `NIF_MCP_REGISTRY_URL` 覆寫）
  並回傳 name/title/description/version，外加為 npm/PyPI 封裝項目建議的 `mcp_add`
  設定——版本從 registry 鎖定
  （`npx -y <id>@<v>` / `uvx <id>==<v>`）。項目只有在需要零設定時才會標記為 `installable`；套件
  id 中的範本變數或宣告的必要 env/headers 會以 `requirements`
  浮現（「configuration required: ...」），而不是半填的設定。失敗會逐字回報
  （`registry unreachable: …`、`registry returned status N`、`bad registry
  payload`）；瀏覽永遠不會變更任何東西——在回傳的引數被傳給 `mcp_add` 之前，什麼都不會安裝。
- **漂移也涵蓋 prompt**：`checkDriftLocked`（全新會話）與兩個
  list-changed 通知都會重新列出工具*與* prompt；記錄的快取
  會被重新整理，而 bridge 會以 3 結束，讓 supervisor 重新啟動。

### Verification

`tests/t_mcp.nim`（在 `make test` 中）：將一個無相依性的 fixture MCP
伺服器（`tests/fixtures/mcp_server.nim`，以換行分隔的 JSON-RPC over
stdio）與一個 mock registry（`tests/fixtures/mock_registry.nim`，僅用標準函式庫的
HTTP）編譯進一個私有沙箱，並演練整個契約——add（含
機密遮蔽）、bridge 註冊、discover 提示 + 完整 schema、延遲
invoke、工具錯誤傳播、進行中取消（`cancel.mcp-<server>`
中止進行中的呼叫）、資源 list/read、prompt 斜線命令 +
渲染、對 mock 的 registry 搜尋、伺服器推送的漂移（持久化 +
重新啟動 + 重新探索）、edit/respawn、供開機還原的 spawn 引數持久化，
以及移除。兩個回歸測試釘住行程衛生修正：被 SIGKILL 的守護行程必須不留下任何孤兒 MCP 伺服器（核心 `PDEATHSIG`），而
失敗的 add 必須不留下任何記錄。Go 單元測試（`make gotest`）涵蓋
SDK 的凍結註冊閘門（`Announce` 在延遲註冊時 panic；
就緒後呼叫會以 `not-ready` 失敗）、名稱/契約驗證、registry
形狀解析、傳輸憑證/重新導向規則，以及取消管線。

## Progressive tool discovery

狀態：**已實作**。

Niffler 維護一份完整的全域目錄，同時對每個會話只暴露一組小型、不可變的元件集。額外的結構描述會透過 `discover` 進入僅可附加的訊息歷史；對這些元件的呼叫則經由固定的 `invoke` 閘道。這能在不削弱核心核准或逾時政策的前提下減少提示詞膨脹。

### Model

#### Existence is global; exposure is per conversation

當元件在匯流排上存活時，它就存在。`reg.publish` 會將其所有工具插入 core 的目錄；`reg.depart` 或 supervisor 清理則會移除它們。`var/bin` 下的二進位檔在 manifest 自動啟動、`core.spawn` 或外掛安裝啟動它之前都是靜止的。

暴露範圍是另一回事：

| Level | Schema metadata | Direct LLM schema | Discovery | Invocation |
|---|---|---|---|---|
| direct | 缺少 `x-harness.onDemand` | 包含在新的會話快照中 | 提示 + 結構描述查詢 | 直接或 `invoke` |
| on demand | `x-harness.onDemand: true` | 省略 | 提示 + 結構描述查詢 | `invoke`（當會話沒有工具允許清單時，以裸名稱呼叫也會進行分派） |
| hidden | `x-harness.hidden: true` | 省略 | 省略，包括明確查詢 | 僅限 components/core |

若兩個旗標同時存在，hidden 優先。一個同時帶有 `x-harness.runner: true` 的 hidden 工具，會豁免於子代理的凍結工具允許清單——這是可替換的 runner 機制（compactor）如何觸及一個在其存在之前工具集就已凍結的子代理。這兩個旗標必須同時具備：一個帶有 `runner` 但沒有 `hidden` 的 on-demand 工具**不會**豁免，並且會像任何其他不在其 `tools` 清單中的工具一樣，在允許清單會話中被拒絕。暴露範圍不是 ACL：
完整目錄在路由上仍具權威性。面向 LLM 的
`invoke` 閘道會拒絕 hidden 目標，而元件仍可直接透過 NATS 請求 hidden 工具。

#### Full catalog and projections

- `catalog {op: "snapshot"}` 傳回完整的元件註冊與
  結構描述。會話 runner 會從中為其本機目錄建立種子。
- `catalog {op: "components"}` 傳回 CLI 所使用的完整
  元件對工具名稱對應。
- `catalog {op: "list"}` 傳回*新*會話目前依名稱排序的直接投影。
  它不是既有會話的工具集。
- 分派、核准、`x-harness.timeoutMs` 以及元件對元件的呼叫
  一律查詢完整目錄。

### Core tools

`discover` 與 `invoke` 在每個新會話中都是直接的核心工具。`profile` 是一個 on-demand 核心工具，用於管理具名工具設定檔；`session.profile` 會在會話首次建立時選取一個。Web UI 或 TUI 中的 `/profile` 會設定 `/new` 所使用的用戶端預設值。
`session_info`（onDemand）會摘要一個會話（標頭欄位、
各角色的訊息計數、累計完成權杖數）；`prompt_preview`
（onDemand）會顯示組合請求的來源——系統提示詞來自何處、有多少專案脈絡檔案餵入它、凍結的直接工具名稱
與目前為止已發現的結構描述、訊息／權杖計數——而不傳送
任何內容。`doctor`（onDemand）是一份一次性、機器可讀的健康報告：
儲存可達性、llm 註冊、作用中的提供者、systemprompt
是否存在、目錄大小、會話計數，外加一輪自我測試扇出——
每個註冊標準 `selftest` 工具（docs/WIRE.md）的元件
都會被要求自我檢查，其各項檢查結果會收集於
報告中（沒有此工具的元件會列為未實作）。使用
`deep: true` 時，探測會實際上線——lsp 元件會針對拋棄式 fixture 啟動每個已設定的語言伺服器（乾淨檔案 → 0 個診斷、hover 有回應、損壞檔案 → 錯誤），repomap 檢查會對一個拋棄式
工作區建立映射，並斷言兩個附加閘門都會觸發，儲存則會在其引擎上執行完整的
put/get/rev/list/del 往返。快速模式維持低成本
（僅二進位解析）；可作為 CI 存活閘門或第一個
診斷步驟。UI 將其暴露為 `/doctor`。報告也會在 `text` 中帶有一份
渲染後的 Markdown 表格（即 `/doctor` 顯示的內容），而 `ask: true`
會加入一個 `userMessage`（docs/WIRE.md 慣例），讓用戶端以使用者回合提交
一個解讀請求。

#### Explicit client commands

聊天用戶端會暴露相同的目錄狀態，而不需要 LLM 回合：

- `/components [all|direct|discovered|undiscovered]` 列出存活元件，並依每個工具在目前會話中的暴露範圍進行篩選。`direct` 表示結構描述位於請求的 tools 陣列中；`discovered` 表示它已在歷史中為人所知，且可透過 `invoke` 呼叫；`undiscovered` 表示它已上線但尚未暴露給此會話。
- `/discover COMPONENT` 或 `/discover tool=NAME` 會執行明確的探索請求，並將傳回的結構描述記錄到會話的持久探索摘要中。它不會將工具提升到直接陣列；當需要直接暴露結構描述時，請在 `/new` 使用設定檔，或使用帶有 `sticky: true` 的 `invoke`。
- `/profile NAME` 會為新會話選取具名設定檔；`/profile default` 會清除選取。變更它永遠不會改寫既有會話的凍結暴露範圍。

Web Components 面板提供相同的 all/direct/discovered/undiscovered 篩選器以及文字搜尋。Hidden 工具仍屬內部，永遠不會被 `/discover` 列出。

#### Hints

```json
{"query": "web"}
```

`query` 是選用的，會以不區分大小寫的方式比對元件名稱、工具名稱與描述。多字查詢是合取：每個以空白分隔的字都必須出現在元件名稱或工具
名稱／描述中——像 "mechanical fan-out" 這樣的關鍵詞片語即使沒有任何描述逐字包含它，也會相符。空查詢會傳回匯流排
目錄，僅含工具名稱；`component` 與 `tools` 呼叫會傳回完整
描述與結構描述。結果是確定性的：元件與工具會
依名稱排序，描述是經空白正規化、上限為
200 字元的單行提示，且會排除諸如 pid 與註冊時間等易變欄位。

```json
{
  "components": [
    {
      "name": "fetch",
      "version": "0.1.0",
      "direct": [],
      "onDemand": [
        {"name": "fetch", "description": "Fetch a web page or API endpoint..."}
      ]
    }
  ],
  "count": 1
}
```

`discover {component: "fetch"}` 會傳回該元件的直接與 on-demand
提示。沒有非 hidden 工具的元件會被省略。

#### Schemas

只請求下一步所需的工具，一次最多 16 個：

```json
{"component": "fetch", "tools": ["fetch"]}
```

結果包含正規化後的完整結構描述，依工具名稱排序：

```json
{
  "component": "fetch",
  "tools": [
    {"name": "fetch", "schema": {"type": "object", "properties": {}}}
  ]
}
```

未知與 hidden 工具請求具有相同的錯誤形狀，因此探索
不是 hidden 工具存在性的預言機。

沒有 `component` 的 `tools` 會搜尋每個存活元件——呼叫者通常
知道工具名稱但不知道其擁有者。每個傳回的結構描述接著會帶有
擁有它的 `component`，而沒有可探索工具的名稱會列在
`notFound` 中（空結構描述集是會指出所請求工具的錯誤）。

#### Invocation

透過固定閘道呼叫已發現的結構描述：

```json
{
  "tool": "fetch",
  "arguments": {"url": "https://example.com"}
}
```

`invoke` 會遞迴進入正常的 `dispatchToolCall` 路徑。因此目標
工具的核准對話框、逾時、元件路由與錯誤的行為
與直接呼叫完全相同。它也可以觸及一個在會話開始時不存在、新註冊的非 hidden
工具。

### Session state and caching

提供者提示詞快取包含頂層工具定義。將已發現的
具體結構描述加入後續的 `tools` 陣列會改變前綴並使累積的快取失效。僅以工具結果形式傳回結構描述是僅可附加的，
但模型仍需要一個已宣告的函式來呼叫它；這就是
`invoke` 固定且通用的原因。

在第一回合，會話 runner 會：

1. 計算 `Catalog.promptTools()`；
2. 將確切且有序的結構描述儲存在儲存種類 `session`、id
   `<sessionId>:tools` 之下；
3. 在每個 LLM 回合以及 runner 重新啟動後使用該快照。

文件形狀為：

```json
{
  "version": 1,
  "direct": [
    {"component": "bash", "name": "bash", "schema": {}}
  ],
  "discovered": [
    {"component": "fetch", "name": "fetch"}
  ],
  "initializedAt": 0,
  "updatedAt": 0
}
```

`direct` 帶有結構描述，因為它是可安全恢復的提供者快照。
`discovered` 是供檢查與 UI 狀態使用的持久摘要；結構描述
本身則存在於已持久化的工具結果訊息中。只有成功的
完整結構描述 `discover` 呼叫會更新它。提示搜尋與失敗的查詢則不會。

元件註冊的變動永遠不會改變既有會話的直接
陣列。較晚出現的元件會透過 `discover` 找到，並透過
`invoke` 呼叫。如果一個直接元件離開，其凍結的結構描述會留在該
會話中以維持快取穩定性；呼叫會透過正常路由失敗，
而目前的探索會反映它已不存在。

### Shipped policy

在完整的隨附 manifest 下，有 7 個工具是直接的（設定檔或 `invoke
{sticky: true}` 可為單一會話擴大該集合）：

- Core：`discover`、`invoke`。
- 例行工作：`bash`、`grep`，以及檔案工具
  `read`/`edit`/`write`（`edit` 元件）。

長尾則是 on demand：

- 搜尋與檢查：`files`（排序清單）、git
  工具、`undo_last_edit`、`context_recall`（指出某個通知所命名之被取代
  內容的目標）、`repo_map`（模型明確要求的加權工作區映射），以及 `observe_*` 診斷加上
  logfile 的 `logfile_search`/`logfile_paths`。
- 狀態與內省：儲存 `get`/`list`、`session_info`，以及
  技能進入點 `skill_list`/`skill_load`（工作流程指南只會在
  適合任務時載入）。
- 協調：`fabric`、`agent_*` 與 `expert_*` 工具，以及實驗性的建議對
  `jev_*` / `von_status`（僅在詞法探索匹配較弱時載入 — 見[建議式探索](#advisory-discovery-jev-and-the-von-launcher)）。
- 核心生命週期／狀態／目錄、builder、外掛與 fetch。
- 模型與提供者管理。
- 技能資源、線上搜尋、安裝與移除。

內部工具仍為 hidden：核心 `session`/`session_prepare`、儲存
`del`、LLM `chat`/`llm_resolve`、systemprompt 提示詞、compaction 接縫的
`compaction_propose`，以及
帶有憑證的提供者工具（`provider_update`、
`provider_use_environment`、`provider_status`、`provider_active`、
`provider_get`、`provider_oauth_start`、`provider_oauth_complete`、
`provider_oauth_cancel`）。儲存 `put` 是 on demand（它帶有
`x-harness.sessionId`，用於凍結工具集快照）。

缺少 `onDemand` 中介資料時仍為直接，以維持第三方相容性。在會話開始後才生成的元件仍不會變更該會話的
凍結直接陣列；discover/invoke 是新能力的握手。

### UI

Live Components 面板會將全域 `core.status` 資料與作用中
會話的暴露範圍文件結合。工具標籤使用文字加顏色：

- `direct`：位於不可變的提供者工具陣列中；
- `seen`：其結構描述已在此會話中成功探索；
- `demand`：已上線且非 hidden，但未在此會話中暴露；
- `internal`：對 LLM 隱藏。

元件存活狀態仍是獨立的狀態點。面板會在選取會話、目錄變更、discovery/done 事件、重新連線以及週期性
輪詢時重新載入。刪除會話也會刪除其暴露範圍文件。

### Verification

`tests/t_discover.nim` 是端對端契約。它證明確定性的
投影與探索、完整目錄保留、hidden 不揭露、
透過 invoke 保留核准與逾時、實際的會話 runner LLM
承載、跨較晚註冊的不可變行為、訊息歷史中的結構描述持久化，
以及持久的 UI 暴露範圍中介資料。

單獨執行請用 `make test-discover`；它也是 `make test` 的一部分。

---

## Model catalog (`models`)

`models` 元件是 Niffler 可替換的 provider/model 中介資料平面。它不屬於核心，也不是通用的推論轉接器。它回答有哪些 provider 與 model 存在、如何定址、支援什麼，以及其限制與價格。`llm` 元件仍負責實際的 wire protocol、驗證流程、請求轉換與串流。

此設計借鏡 Pi 與 OpenCode 中實用的共同形狀：

- models.dev 是廣泛的策劃基準。
- 一個小型內嵌種子讓首次離線開機仍可用：刻意極小 —— 僅隨附 `deepseek` provider 與 `deepseek-chat`、`deepseek-reasoner`，讓已設定的預設值在離線時持續運作。其餘一切會在基準被抓取，或由來源／覆寫提供後出現。
- 最後一次驗證過的下载會以原子方式寫入，並在失敗時保留。
- 修正與 provider 探索是確定性的層，而非對下载檔案的編輯。
- 使用者提供的 model id 會嚴格解析；有歧義的裸 id 絕不會依目錄順序被選中。

### Merge order

有效目錄依此順序重建：

1. `NIF_MODELS_PATH`、快取的 models.dev 目錄，或內嵌種子。
2. 已註冊的 `x-models-source` 外掛，依 `priority` 升冪，再依 `component/tool` 排序。因此較大的 priority 勝出。
3. `NIF_MODELS_OVERRIDE`，永遠最後。

外掛與本機層是 JSON Merge Patch（RFC 7396）：物件合併，陣列與純量值取代，`null` 刪除鍵。完整的 models.dev 形狀會被保留，包括 Niffler 尚未使用的欄位 —— 因此一個 patch 可以新增整個 provider、在既有 provider 下新增 model，或變更任何欄位。省略 `id`/`name` 的 provider 或 model 會由其 map 鍵填入，非物件項目會在正規化期間被丟棄。

此元件會在啟動時、每當元件目錄變更（註冊或離開）時，以及接著依 `NIF_MODELS_REFRESH_INTERVAL`（預設一小時；`0` 停用週期性 tick）重新整理。當 models.dev 的快取未滿五分鐘時會跳過下载。HTTP 抓取有界限（16 MiB，每次請求 12 秒），最多重試三次，退避 200/400 ms，用戶端錯誤時快速失敗，會驗證（沒有可用 model 項目的目錄會被拒絕，因此格式錯誤的回應無法取代 last-known-good 快取），並以原子方式
重新命名至 `var/models/api.json`。每個已註冊的外掛來源也有一份 last-known-good patch，名為 `<component>--<tool>.json`，位於 `var/models/sources/` 之下（`A-Za-z0-9-_.` 以外的任何字元會變成 `_`）；當來源暫時失敗時會使用該 patch，但僅在來源元件仍保持註冊期間 —— 移除元件會一步移除其註冊、狀態與快取 patch，因此已離開的來源無法繼續影響目錄。本機覆寫在檔案於重寫中途無法讀取時會保留其先前的 patch。失敗的重新整理會自動重試（30 秒或設定的間隔，取較早者），因此沒有 `reg.depart` 的當機協調不會被擱置到下一次每小時 tick。`ev.sys.drain` 會取消重新整理工作並關閉此元件。

### Tools

| Tool | Purpose |
|---|---|
| `models_providers` | provider 連線中介資料與已設定狀態，絕不含機密值 |
| `models_list` | 帶有 capabilities、modalities、limits 與 costs 的篩選 model 搜尋 |
| `models_get` | 供其他元件使用的精確 provider/model 描述元 |
| `models_resolve` | 嚴格的 `provider/model` 或全域唯一裸 id 解析 |
| `models_refresh` | 將 models.dev 與每個作用中的擴充來源排入重新整理佇列：它會立即回傳*當前* provenance 報告以及 `queued` 與 `force`，工作以非同步方式進行（註冊爆量會在 150 ms 內合併），因此請再次讀取 `models_sources` —— 或等待 `ev.models.updated` —— 以查看結果；`force: true` 會繞過快取 TTL |
| `models_sources` | provenance、freshness、stale fallback 與錯誤診斷 |

全部六個工具都是 `onDemand`：它們不存在於會話凍結的直接工具集中，因此 model 需透過 `discover` + `invoke` 才能觸及它們。元件與 `cli call` 會直接以名稱定址它們。這裡沒有任何項目是 `hidden`，因此 `/discover tool=models_sources` 會列出它們。

`models_resolve` 絕不猜測：存在於多個 provider 下的裸 id 會回傳 `found: false` 與 `matches`，未知參照會回傳 `found: false` 與最多十個 `suggestions`；前綴不是已知 provider id 的 `provider/model` 字串會以字面裸 id 查詢，因此打錯的 provider 看起來就像缺少的 model。成功時答案會帶有選定的 `provider`、`model`、`reference`、`configured` 與目錄 `updatedAt`。

`models_list {status: "active"}` 也會符合 status 欄位不存在的 model（models.dev 對一般 model 會省略該欄位）。列表結果在會超過匯流排酬載限制時會被裁剪，而過大的單一描述元會報錯，而非在 wire 上逾時。描述元中介資料會遞迴遮蔽：類機密鍵（api keys、tokens、passwords、credentials、authorization headers、private keys、cookies）絕不會到達呼叫者，無論在 provider 或 model 層級。引數形狀：`models_list` 接受 `status`、`provider`、`query` 與 `limit`（預設 50，最大 500）；`models_get` 需要 `provider` + `model`；`models_providers`/`models_sources` 不接受引數。列表式結果為 `{models|providers, count, total}`，並在會超過匯流排酬載限制時以 `truncated: true` 裁剪，而過大的單一 `models_get` 描述元會報錯，而非在 wire 上逾時。

即時來源：models.dev 是中介資料權威（limits、pricing），但 provider 實際提供的 id 來自 provider 本身。存在兩個互補介面 —— `provider` 元件的 `provider_models` 工具會以已儲存或明確的憑證隨需探測端點（connect form），而 `llm` 元件的隱藏 `llm_models_source` 工具會註冊為 `x-models-source` 外掛（priority 150），其 patch 會新增每個 provider 被觀察到提供的 id。其背後的探測是每個目錄 provider + base-URL 鍵每 10 分鐘一次背景 `GET {baseUrl}/models`（8 秒逾時；id 僅存在於記憶體中，因此重新啟動會忘記它們，直到下一次聊天，且該工具在探測成功前會回答 `no live model data yet`；Codex 通道被排除，因為 ChatGPT 後端未暴露此類路由），因此整個目錄會收斂到端點實際列出的內容。兩者都是盡力而為：失敗絕不影響聊天或目錄基準。

`llm` 會向 `models_get` 詢問所選 model 的 context window。明確的 provider `context` 與 `NIF_OPENAI_CONTEXT` 仍優先，且若 `models` 被移除，既有的小型 fallback 仍可用。Provider 端點依主機名稱分類，而非 URL 子字串。互動式用戶端應呼叫隱藏、免憑證的 `llm_resolve {model?}`，而非複製此優先順序：它會報告有效的全域 provider、選用的會話 model 覆寫、目錄、context，以及每個值的 provenance。

### Source plugins

model 來源是透過 `plugins` 安裝的普通元件。一個隱藏工具帶有此註冊擴充：

```json
{
  "x-models-source": {"version": 1, "priority": 200},
  "x-harness": {"hidden": true}
}
```

契約：`x-harness.hidden` 旗標是慣例，`x-models-source` 擴充才是註冊該工具者；`version` 必須正好是 1，否則該工具會被跳過；`priority` 預設為 100，相同 priority 依 `component/tool` 排序。`models` 會從 `reg.publish` 與核心的完整目錄快照探索被標記的工具，因此元件開機順序無關緊要。它會以 `{"version": 1}` 與 30 秒期限呼叫該工具；沒有 `patch` 物件的結果算作失敗，會保留 last-known-good patch。結果是 JSON Merge Patch（RFC 7396）：

```json
{
  "patch": {
    "openai": {
      "models": {
        "model-with-wrong-limit": {"limit": {"context": 200000}},
        "retired-model": null
      }
    }
  }
}
```

一個完整的實作範例來源元件 —— 標記、工具、套件配置與驗證 —— 位於 [MODEL_SOURCES.md](MODEL_SOURCES.md)。

將來源放在一般的 `niffler.json` 套件中。安裝、更新、移除、行程隔離與持久化已由既有的 `plugins` 與核心生命週期處理。移除來源元件會立即從有效目錄移除其 patch。核心不會新增任何 model 專屬的擴充機制。

### Configuration

設定變數（`NIF_MODELS_*`）列於上方的總表 [Environment variables](#environment-variables)。

修正或新增中介資料最便宜的方式是 JSON Merge Patch 檔案：

```json
{ "deepseek": { "models": { "deepseek-chat": { "limit": { "context": 131072 } } } } }
```

由 `NIF_MODELS_OVERRIDE=/abs/path/override.json` 指向（僅限環境變數，因此變更它意味著 `core.kill` + `core.spawn`）。它會在每次重建時重新讀取，在所有外掛 patch 之後合併，且 `null` 會刪除鍵。在重寫中途無法讀取的檔案會保留先前的 patch，並由 `models_sources` 回報為 `stale`。上述外掛路徑仍是耐久、可分享的選項。

此元件只會回報 provider 使用哪些憑證環境變數名稱，以及是否已設定其一，於呼叫時計算並附加至 provider 與 model 結果。*已設定* 意指：provider 的 `env` 名稱之一已設定，或該 id 以暱稱出現在 `NIF_LLM_PROVIDERS` 中，或 —— 對隨附的 `deepseek` 項目 —— `NIF_OPENAI_API_KEY` 已設定。它絕不回傳憑證值。Provider 專屬的
OAuth、環境憑證、headers、請求轉換與原生 API 行為屬於推論轉接器元件，這些元件可獨立於此目錄隨附或安裝為外掛。

#### Verification

`make test-models` 會以本機 fixture 目錄啟動私有 harness，並證明註冊、嚴格解析，以及已建置來源外掛的 patch 會在 spawn 時出現、在移除時消失。對作用中的 harness，`./var/bin/cli call models_sources '{}'` 會印出 provenance，而
`./var/bin/cli call models_get '{"provider":"deepseek","model":"deepseek-chat"}'`
會印出一個描述元。

---

## System prompt (`systemprompt`)

狀態：由 `systemprompt` 元件**已實作**。

### Boundary

system prompt 不是 LLM 呼叫的工具 —— 它是每個會話開始時所處的常設指令集。它存在於元件中，而非核心：核心只保留最小的結構性 fallback，而會話執行器每個會話會從 `svc.systemprompt.call` 抓取真正的 constitution 一次。替換 constitution 是正常的 Niffler 操作：撰寫一個在同一 subject 上回應的元件 —— subject 由元件名稱衍生，因此它必須註冊為 `systemprompt` —— `build` 它，`kill` 舊的（`core.spawn` 會拒絕已被監督的名稱），然後 `spawn` 你的。不過，此替換只維持到下一次開機：在 `manifest.yaml` 中宣告的元件會先被還原，而同名的已儲存記錄會被跳過，因此永久替換意味著編輯 `manifest.yaml`。agent 可以對自己做這件事。

### How it works

- **每個會話凍結。** 解析後的 prompt 會在第一次回合時持久化於會話標頭（`systemPrompt` 欄位），並在任何 runner 行程中的每次恢復時逐字重用。prompt 前綴保持穩定，因此 provider 會重用它；在會話中途死亡或變更的元件絕不會重寫執行中會話的指令。
- **Fallback。** 元件不存在、緩慢（500 ms 探測，接著當目錄顯示它已註冊時有 8 秒預算），或損壞 → 核心內建的極簡 prompt。核心絕不為了開機而硬依賴元件。
- **上限。** 答案會在 200 KB 截斷（雙方）—— 元件本身會在 200 000 位元組停止（標記 `[systemprompt: truncated at 200000 bytes]`；核心會加上自己的），並最多收集 16 個 context 檔案。兩個數字都是編譯期常數，沒有環境變數旋鈕：不同的上限意味著重建元件。
- **Agent 預先抓取。** `agent` 元件會在其子代理的第一回合前為它們請求 prompt，並透過會話呼叫的 `systemPrompt` 欄位傳遞（盡力而為 —— runner 自身的 fallback 會涵蓋缺少的元件）。
- **Prompt slots（擴充接縫）。** 元件與外掛透過隱藏工具 `prompt_hint {slot, content, source?, key?, mode?}` 貢獻片段：具名 slot（`tool_usage`、`efficient_tools`、`after_instructions`）會以確定性順序（依 `source`，再依 `key`）渲染為 `<prompt_slot name="…">` 區塊；`mode: aggregate`（預設）保留每個貢獻，而 `mode: singleton` 只保留該 slot 最後註冊的一個，而沒有貢獻的 slot 不會渲染任何內容。註冊是元件本機狀態，且只影響在其*之後*組成的 prompt —— 凍結的會話絕不會被重寫。`prompt_hint` 也是 `x-harness.hidden`，因此它與 `systemprompt` 都不會出現在 LLM 工具集中。

### The default component's prompt assembly

1. `components/systemprompt/baseprompt.txt` —— 產品 prompt
   （變更範圍紀律、工具選擇指引、文件指標），
   在編譯期透過 `staticRead` 逐字內建於二進位檔中 —— 沒有
   替換，也沒有模板。編輯它意味著
   重建 + 重新 spawn；沒有執行時檔案依賴。
   產品 prompt 也是教導 model 被替換內容
   救濟途徑的地方：被修剪的工具結果、溢出的指令輸出與壓縮
   檢查點可透過 `context_recall` 取回，方法是逐字傳入通知中引用的 ref —— 削弱那句話，每個修剪、溢出與
   壓縮通知就不再被遵循。
2. 儲存庫的本機 context 檔案，Pi 風格，在產品 prompt 之後以
   `<project_context>`/`<project_instructions path="...">` 標籤包住：
   - 每個目錄，先命中者勝：`AGENTS.override.md`、`AGENTS.md`、
     `AGENTS.MD`、`CLAUDE.md`、`CLAUDE.MD`（每個目錄一個檔案 ——
     `AGENTS.md` 會遮蔽旁邊的 `CLAUDE.md`；符號連結會被跟隨；
     `AGENTS.local.md` 是額外加入，絕不作為候選：它絕不
     遮蔽主要檔案，且會為走訪的每個目錄收集，而非僅
     延遲收集）；
   - 從會話的 cwd **向上走到 harness 根目錄
     （含）**的祖先走訪，根目錄優先，依檔案身分（device:inode ——
     符號連結農場無法將同一檔案注入兩次）去重；較接近 cwd 的檔案
     較晚出現，因此最具體的指令是 model 最後讀到的內容。位於 harness 根目錄**之外**的工作區只走訪自己的
     目錄，因此 `$HOME` 中無關的 `AGENTS.md` 絕不會洩漏進
     prompt；
   - worktree 遮蔽規則：當 harness 根目錄是主儲存庫下的 `git worktree` 時，主儲存庫根目錄的 context 檔案會被跳過 ——
     否則祖先走訪會將同一邏輯儲存庫範圍套用兩次；
   - 延遲載入：進入 harness 根目錄*之下*目錄的 `read` 會為路徑上的目錄附加任何新發現的 `AGENTS.override.md`/`AGENTS.md`/
     `AGENTS.MD`/`CLAUDE.md`/`CLAUDE.MD`（+ `AGENTS.local.md`），每個以 `<lazy_project_instructions
     path="…">` 包住，每個會話一次 —— monorepo 子樹會留在
     凍結的頭部之外，直到 model 實際進入它。
3. 每個會話的 `<workspace>` 尾端，僅在會話的 cwd **不是** harness 根目錄時附加：它會指出工作
   目錄（相對路徑從它解析）與 harness 根目錄，因此
   從根目錄之外的工作區，`docs/`、`components/` 與 `sdk/` 會以絕對路徑解析。上述凍結的頭部無論如何都保持無路徑 ——
   根目錄是每個會話的事實，對同一台機器上的每個會話都相同，因此 provider 快取前綴仍會對齊。

該工具是 `x-harness.hidden` —— 它絕不會出現在 LLM 工具集中；它是
基礎設施，僅核心與元件可觸及。

## Observation and logs

狀態：由 `observe` 與 `logfile` 元件**已實作**。

### Boundary

觀察匯流排，而非元件內部。這兩個元件都是建構於 SDK 之上的普通 NATS 公民；核心從不匯入它們。唯一的核心整合是選用的 nats-server HTTP 監控：當核心擁有匯流排時，它會配置第二個回送埠，並在伺服器上線後寫入 `var/nats-monitor-url`。

觀察是一項行政能力。匯流排擷取可能包含工具引數、模型輸出、核准，以及來自每個會話的資料。Niffler 目前的信任模型是單一受信任使用者/管理員；請勿將 observe 服務或擷取目錄暴露給不受信任的匯流排用戶端。它也無法被複製：環、探針與元件普查都是行程本地的，因此複本會將單一檢視拆分為數個，並正好放大那樣的暴露——基於這個理由，manifest 讓 `replicas` 保持未設定。

**不是稽核軌跡。** 這些元件都不是決策的持久記錄：`observe` 保留一個有界的記憶體內環，會隨元件一同消亡，`logfile` 是盡力而為（至多一次，預設為 `ev.log.>`），`console` 列印後即遺忘，而 `hooks` 不記錄任何內容。核准閘門唯一持久的產物是用戶端寫入的授權記錄（儲存種類 `approval`）以及核心寫入 `var/approval-sources/<digest>.nim` 的程式原始碼——不存在請求/裁決歷史。

### `observe`: bounded live inspection

`observe` 有一個原始的 `>` 訂閱。它保留原始 JSON 節點，包括未知的信封欄位與裸註冊承載。它的同類 `console` 會解碼每一則訊息：信封會呈現為 `call`/`result`/`error`/`event`，而裸承載（`reg.publish` / `reg.depart` 註冊）會呈現為 `event <subject>` 後接物件本身，而結果行會帶上它所回應的工具（縮短的信封 id；歸屬來自已呈現呼叫的 id→tool 對應——SDK 的回覆信封不帶工具名稱）。格式錯誤的 JSON 在為有效 UTF-8 時會保留為 `{raw, decodeError}`；任意位元組則改用無損的 `rawBase64`。過大的訊息會以有界的 base64 預覽表示，而不是讓單一訊息耗盡行程。

全域環同時受訊息數與近似線路位元組數限制——預設為 2 000 則訊息與約 16 MiB（`NIF_OBSERVE_RING`，夾限於 1..10000；`NIF_OBSERVE_RING_BYTES`，64 KiB..100 MiB），單一保留訊息上限為 64 KiB（`NIF_OBSERVE_ENTRY_BYTES`，1 KiB..1 MiB——較大者會以 base64 預覽保留）。每個目標探針有獨立的計數與位元組界限——至多 2 000 個項目與 2 MiB（`cap`，夾限於 1..2000；`NIF_OBSERVE_PROBE_BYTES`，64 KiB..16 MiB）——而探針數量也上限為 32（`NIF_OBSERVE_MAX_PROBES`，1..256），因此第 33 個 `observe_listen`/`observe_trace` 會失敗，直到移除其中一個。已停止的探針在 `observe_remove` 釋放其記憶體之前仍可查詢。

| 工具 | 用途 |
|---|---|
| `observe_subjects` | 當核心可達時列出權威的元件/服務檢視（`session-<id>` 元件對應至 `svc.session.<id>.call`）、固定的已知事件集（`reg.publish`、`reg.depart`、`ev.sys.drain`、`ev.catalog.updated`、`ev.llm.token`、`ev.session.>`、三個 `ev.approval.*` 主體、`svc.approval.>.request`、`ev.log.>`、`ev.models.updated`、`llm.cancel.>`），以及最常被觀察到的具體主體（前 100 名，排除 `_INBOX.*`）；核心檢視是盡力而為的 250 ms `catalog` 請求，而 `*Truncated`/`dropped*` 計數器會說明答案何時不完整 |
| `observe_listen` | 為權杖正確的 NATS 模式（`*` 與結尾 `>`）加上選用 regex 啟動有界擷取；`cap` 預設為 500 並夾限於 1..2000，而傳回的 `probeId` 為 `pr-<id>`（`observe_trace` 亦同） |
| `observe_trace` | 擷取對單一元件的呼叫，並依信封 id 關聯結果/錯誤 inbox 回覆——它監看 `svc.<component>.call` 與具範圍的 `svc.<component>.<id>.call` 形式，`toolRegex` 依工具名稱篩選，`cap` 預設為 500（最大 2000），而每個關聯的回覆會帶有來自單調時鐘的 `elapsedMs` |
| `observe_probes` | 檢視探針狀態、保留位元組、上限與待處理追蹤 |
| `observe_stop` | 凍結探針，同時保留其項目 |
| `observe_remove` | 刪除探針並釋放其記憶體 |
| `observe_events` | 查詢探針或全域環，最新優先，附時間/種類/元件/主體/regex 篩選；`kind` 為 `call|result|event|error`，`component` 符合 `svc.<component>.*`、`ev.log.<component>` 或信封自身的 `component` 欄位，`subject` 為確切的具體主體，而 `limit` 夾限於 1..500 |
| `observe_logs` | 查詢記憶體中最近的 `ev.log.*` 事件——僅限環，若需持久歷史請使用 `logfile_search`；項目帶有 `component`、`level`、`msg`，以及發出者的 `at` 作為 `emittedAt`，並在存在時帶有 `ctx`，而 `limit` 夾限於 1..500 |
| `observe_dump` | 經核准閘門的單一探針匯出，位於 `NIF_OBSERVE_CAPTURE_DIR` 之下（檔案為 `<captureDir>/<probeId>.jsonl`，每個擷取項目一個 JSON 物件，位於以僅限使用者建立的目錄中——0700，檔案 0600——符號連結目標會被拒絕，較舊的擷取會依最舊優先修剪至位元組配額與 256 檔案上限；當即使修剪也無法容納傾印時，工具會以 `capture directory quota is exhausted` 失敗）；不接受任意輸出路徑 |
| `observe_monitor` | 讀取 nats-server 連線/訂閱計數與訂閱最多的模式；經核准閘門——它借用操作者的監控端點 |
| `observe_send` | 將事件發佈至具體的 `ev.*` 或 `llm.cancel.*` 主體；經核准閘門 |
| `observe_request` | 對具體的 `svc.*.call` 進行診斷請求/回覆；經核准閘門。請求等待夾限於 100–30000 ms（`timeoutMs`），而工具呼叫本身帶有 `x-harness.timeoutMs: 35000` |

`observe_send` 無法傳送 call/result/error 信封或註冊。`observe_send`、`observe_request`、`observe_monitor` 以及會變更檔案系統的 `observe_dump` 帶有 `x-harness.approval: always`，因此 LLM 路徑必須通過核心的人工閘門。直接與 `svc.observe.call` 對話的用戶端已是受信任的匯流排同儕，並繞過核心政策，正如它可以直接呼叫任何其他服務主體一樣。產生的擷取會依最舊優先修剪至位元組配額與 256 檔案上限。

追蹤請求會在 60 秒後從待處理關聯表過期。探針主體、標籤與正規表示式有固定的輸入限制；過大的探針項目會被丟棄並計數，而不是保留在位元組預算之外。工具回應會在線路約 64 KiB 內嵌結果慣例之前停止，並回報 `truncated`（或大型診斷回覆的值位元組中繼資料），而不是傳回無界資料。

### `logfile`: rotating JSONL persistence

`logfile` 是盡力而為的行程本地持久化，不是稽核日誌。核心 NATS 為至多一次：在啟動前或重新啟動期間發出的記錄會遺失。保證重播需要明確的 JetStream 設計。

預設輸入為 `ev.log.>`。每個符合 `[a-z0-9-]{1,64}` 的元件名稱一個檔案，位於 `NIF_LOGFILE_DIR` 之下（預設為 `$NIF_ROOT/var/logs`；絕對值會如實使用，相對值會對照 harness 根目錄解析）：

```text
var/logs/bash.jsonl
var/logs/bash.jsonl.1
...
```

`NIF_LOGFILE_SUBJECTS` 可以選取其他主體。非日誌流量，包括全匯流排 `>`，會進入單一 `bus.jsonl`；因此動態 inbox 主體不會產生無界的檔案描述元或檔名。元件日誌檔的數量有上限，而過量/偽造的元件主體也會退回 `bus.jsonl`。多個已設定的模式會被視為一個本地篩選的聯集，因此重疊的模式會將每個相符的發佈恰好持久化一次。清單會在開機時驗證：格式錯誤或超過 512 位元組的模式、超過 64 個唯一模式，或空結果，都會使元件以非零值結束。使用多個模式時，tap 為 `>`，比對在本機進行；單一模式則以其本身訂閱。

每一行記錄 sink 時間與原始線路資料：

```json
{"receivedAt": 1780000000.25, "subject": "ev.log.bash", "message": {"v": 1, "id": "...", "kind": "event", "payload": {"level": "info", "msg": "..."}}}
```

格式錯誤的 UTF-8 輸入使用無損的 `rawBase64`；文字性格式錯誤的輸入使用 `raw` 與 `decodeError`。sink 會開啟、附加、沖刷並關閉每一筆記錄。輪替會在重新命名已關閉檔案之前比較 `current size + record size`，因此精確邊界的寫入不會留下過期的檔案控制代碼。大於已設定檔案大小的單一記錄會保留為作用中檔案，並在下一筆記錄之前輪替。`NIF_LOGFILE_KEEP=0` 不保留任何輪替世代。輪替世代命名為 `<file>.1` … `<file>.<KEEP>`，而每次開機都會刪除編號高於目前 `NIF_LOGFILE_KEEP` 的任何世代——調降此旋鈕會在下次啟動時銷毀歷史。開機時磁碟上已有的 `.jsonl` 檔案也會計入 `NIF_LOGFILE_MAX_FILES`。

`logfile_search` 只從保留的檔案讀取有界的尾端，依 `receivedAt` 最新優先排序相符記錄，並回報 `truncated`、`scannedBytes`、格式錯誤行數與讀取錯誤。結果也有編碼後的回應位元組預算。結構化日誌記錄會暴露 `component`、`level`、`msg`、`ctx` 與選用的發出者時間；原始匯流排記錄會暴露保留的訊息。搜尋從不信任發出者提供的時間戳作為 `since`/`until` 視窗。目錄列舉受 `NIF_LOGFILE_DIRECTORY_ENTRIES` 限制，並在存在更多檔案時回報 `directoryTruncated`；搜尋仍會檢查有界的子集。

兩個讀取工具都是 `onDemand`，且不宣告任何 `x-harness.effect`，因此 fabric 批次主機會將即使是讀取也排程為寫入。`logfile_search` 接受 `{component?, level? (debug|info|warn|error), regex? (≤1024 bytes), since?, until? (epoch seconds, `since ≤ until`), limit? (default 100, cap 500)}`；無效引數會以 *成功* 結果內的 `{"error": …}` 傳回，而不是以錯誤信封傳回，且在 schema 上沒有 `timeoutMs` 時，呼叫會依核心的 120 秒預設期限執行。

`logfile_paths` 回報最多 500 個保留檔案，以及 `writeErrors`、`lastError`、`lastErrorAt`、`maxBytes`、`keep`、`subjects` 與元件檔案計數。檔案系統失敗也會輸出至 stderr。**日誌目錄**在平台允許時以僅限使用者建立（0700，檔案 0600），而日誌路徑上的作用中符號連結會被拒絕。

### SDK APIs

三個 SDK 都暴露相同的觀察/日誌與原始信封 API：

```nim
type TapHandler* = proc(c: Component, subject: string, data: string)
proc tap*(c: Component, pattern: string, handler: TapHandler): Component
proc log*(c: Component, level, msg: string, ctx: JsonNode = nil)
proc publishEnvelope*(c: Component, subject: string, env: Envelope)
proc requestEnvelope*(c: Component, subject: string, env: Envelope,
                      timeoutMs: int = 5000): Envelope
```

```go
func (c *Component) Tap(pattern string, h TapHandler) *Component
func (c *Component) Log(level, msg string, ctx any) error
func (c *Component) PublishEnvelope(subject string, env Envelope) error
func (c *Component) RequestEnvelope(subject string, env Envelope, timeout time.Duration) (Envelope, error)
```

```ts
comp.tap(pattern, handler)
comp.log(level, msg, ctx?)
comp.publishEnvelope(subject, envelope)
await comp.requestEnvelope(subject, envelope, timeoutMs?)
```

每個 SDK 都讓 NATS 執行主體比對，並只分派綁定至傳遞該訊息的訂閱的處理常式。這避免了先前的交叉乘積，即一次呼叫可能透過 call、event 與 tap 路徑多次傳遞。Nim 保持無回呼且無執行緒；Go 使用其現有的互斥鎖，而 TypeScript 使用其 promise 鏈。關機時，Go 會先排空訂閱（至其有界的關閉寬限期），然後停止每個元件的傳遞迴圈並等待每個仍在執行的處理常式完成，以保留欠給呼叫方的回覆——已接受但從未開始的呼叫會被拒絕，而不是被靜默丟棄；而 TypeScript 會等待已排入佇列的處理常式，且不會使明確關閉自身元件的處理常式死鎖。

#### 匯流排中斷後重新接入

NATS 用戶端會透明地重連至相同 URL，但匯流排在其重連預算之後仍不可達——或 harness 在新連接埠上重啟——過去會讓元件**存活卻失聰**：訂閱不再傳遞，未送出 `reg.depart`，目錄仍公告著無人能觸及的工具，恢復只能靠殺掉行程。Nim 與 Go SDK 現在會監視連線健康（每 2 秒一次 `Flush` 探測），一旦連線不健康持續 `NIF_RECONNECT_GRACE_S`（預設 180 秒，刻意高於用戶端自身的耐心），便**重新接入**：重新解析匯流排 URL、帶退避地重新撥號、重建每個訂閱（call、event 與 tap）並重新發佈 `reg.publish`——無需重啟行程。

延遲公告的元件（Go SDK 的 `DeferAnnounce`，例如 `mcp-bridge`）必須在全新連線上重新發佈自己的契約，因為它可能在不健康期間已經漂移；以 `onReattached`（Go 為 `OnReattached`）註冊它。一般元件無需鉤子——重新接入已重新公告它們凍結的契約。TypeScript SDK 目前尚不重新接入。

```nim
proc onReattached*(c: Component, handler: ReattachedHandler): Component
```

```go
func (c *Component) OnReattached(h func(*Component)) *Component
```

#### Idle work (`onIdle`)

三個 SDK 都暴露相同的 *閒置接縫*——一個用於沒有請求能承載之工作的回呼（收割背景子行程、健康探針、快取重新整理）。`components/processes` 用它來在無人輪詢的情況下察覺背景子行程的結束，這正是使其結束通知成為可能的原因。

```nim
proc onIdle*(c: Component, intervalMs: int, handler: IdleHandler): Component
```

```go
func (c *Component) OnIdle(interval time.Duration, handler func(*Component)) *Component
```

```ts
comp.onIdle(intervalMs, handler)
```

API 是對映的；*執行模型* 是各執行時自身的，因此契約依 SDK 分別陳述：

| SDK | 執行於 | 互斥 |
|---|---|---|
| Nim | pump 迴圈，在每次傳遞之間 | 絕不在處理常式執行時——該迴圈是序列化的 |
| Go | 其自身的 ticker goroutine | 取得序列處理常式鎖；`ToolConcurrent` 處理常式只持有讀取鎖，因此它可能與那些重疊 |
| TS | promise 鏈，如同每個處理常式 | 絕不與另一個處理常式交錯 |

三者共通：在 connect/run 之前註冊，每個元件一個處理常式（第二次註冊會取代第一個），間隔下限為 10ms，計時器隨連線啟動並在關閉時停止，而恐慌的閒置處理常式會被記錄，絕不致命。當你只需要「每 N 秒」時，優先使用它而非元件執行緒。

Nim 的任意信封請求輔助程式在等待時只會繼續泵送原始 tap 訂閱。工具與事件處理常式保持非巢狀，而觀察者可以在 `observe_request` 期間為目標請求與回覆加上時間戳。追蹤持續時間與過期使用單調時鐘；顯示的 `at` 值仍為牆鐘 epoch 秒。

結構化日誌會以 `{component, level, msg, ctx?, at}` 在確切主體 `ev.log.<component>` 上發佈事件。等級為 `debug`、`info`、`warn` 與 `error`。`NIF_LOG_LEVEL` 預設為 `info`，並在每個 SDK 中於發佈前抑制較低等級。無效的發出等級會失敗；無效的閾值會退回 `info`。

### Monitoring

當核心生成 nats-server 時，它使用不同的回送用戶端與 HTTP 埠，然後寫入（二進位檔為存在時來自 `components/nats` 的已建置元件 `var/bin/nats-server`，否則為 PATH 中的 `nats-server`）：

```text
var/nats-url
var/nats-monitor-url
```

監控探索檔案只在用戶端連線成功後寫入。NATS 自行配置埠：核心傳遞 `--ports_file_dir <tmp>`，並從它寫入的 `*.ports` 檔案讀回用戶端與監控埠（有界的 4 秒等待），因此並行的 harness 無法贏得綁定-關閉-啟動的競爭。核心在 home 埠空閒時傳遞它，並在啟動隔離匯流排時傳遞 `-1`（隨機埠）。重複使用或遠端的匯流排沒有可探索的 HTTP 端點；請明確設定 `NIF_OBSERVE_MONITOR_URL`。`NIF_NATS_SPAWN=1` 會強制在隨機埠上使用隔離的核心擁有匯流排（主要用於測試與診斷）——絕不是 4222；環境中明確的 `NIF_NATS_URL` 優先。

一個請求承載整個對話，因此隨附的匯流排以 `max_payload: 8388608` 啟動（8 MiB——約 2M 權杖的 JSON；超過此值 nats-server 只會警告）：隨附的 `var/bin/nats-server` 將它作為額外旗標，而 PATH 中的 `nats-server` 則改在產生的設定檔中取得它。當核心附加至非它生成的匯流排時，它會讀取伺服器的真實上限，並在開機時於低於 8 MiB 時警告——這樣的匯流排會在發佈時拒絕大型回覆，而呼叫者會等待完其完整逾時，這看起來像元件懸置而非匯流排限制。

`observe_monitor` 為每個請求使用全新的 HTTP 用戶端讀取 `/subsz` 與 `/connz`。它會回報訂閱詳細資料是否被截斷；`mostSubscribed` 意指訂閱者密度，而非訊息輸送量。

所有 `NIF_OBSERVE_*`、`NIF_LOGFILE_*` 與 `NIF_LOG_LEVEL` 變數都列於上方的總表 [Environment variables](#environment-variables) 中。

所有界限都會在啟動時驗證；無效設定會以非零值結束，而不是默默替換為預設值。

### Verification

`tests/t_observe.nim` 涵蓋恰好一次的 tap、萬用字元邊界、註冊擷取、上限/位元組逐出、診斷請求期間的單調追蹤關聯、格式錯誤呼叫回覆、逾時行為、內嵌 NUL 與無效 UTF-8 原始資料、回應界限、核准中繼資料、配額修剪的安全傾印、監控探索與無效設定。

`tests/t_logfile.nim` 涵蓋 SDK 日誌篩選、最新優先查詢、時間/regex 篩選、編碼回應與實際磁碟讀取界限、恰好一次的重疊主體模式、已關閉檔案輪替、零保留、內嵌 NUL 全匯流排保留、有界路徑列表、sink 健康與無效設定。兩個測試都使用隔離的暫存輸出目錄，並且是 `make test` 的一部分。

## Fabric and subagents

`fabric` 元件加入了可程式化的工具呼叫：模型撰寫一支 Nim 程式，由程式本身驅動 Niffler 工具，而只有程式的 `finish()` 值會進入會話。`agent` 元件則把會話變成子代理。完整設計與威脅模型：
[research/FABRIC.md](research/FABRIC.md)（形塑此設計的外部審查：
[research/FABRIC_FEEDBACK.md](research/FABRIC_FEEDBACK.md)）。含提示措辭與實作範例的使用者指南：
[FABRIC_GUIDE.md](FABRIC_GUIDE.md)。

| Tool | What it does |
|---|---|
| `fabric {code | name, tools?, strings?, timeoutMs?, maxCalls?}` | 執行一支由 LLM 撰寫的 Nim 程式：`var/bin/fabric-exec` 會將它編譯成一個私有行程（沒有內嵌 VM；相同的程式會快取於 `var/fabric-cache`，自我上限為 64 筆 / 128 MB，淘汰最久未存放者）。`code` 是內嵌的程式原始碼；`name` 則改為執行來自模型策劃的 `fabricprog` 函式庫中的已存放程式。搭配 `tools` 時，選定的 schema 會被固定，並產生經編譯期檢查的 `tools.<name>(...)` 包裝函式；允許清單中的 `callTool` 仍為後備方案。只有 `finish(value)` 會進入會話。已核准的原生程式碼屬於 bash 等級的信任，而非沙箱。預算：`maxCalls` 預設為 200（上限 1000），`timeoutMs` 預設為 240 秒（硬上限 300 秒，亦會被夾限至呼叫端剩餘的會話期限）；每個巢狀呼叫都繼承該次執行的剩餘時間，而過大的 `finish()` 值會溢出至 `var/fabric-artifacts/<run>.json`（[FABRIC_GUIDE.md](FABRIC_GUIDE.md)，「Budgets and limits」）。 |
| `fabric_help {topic?}` | 從元件內部讀取 Fabric 客體參考與實作範例原始碼；空的 `topic` 會回傳參考加上範例索引，指定 topic 則回傳該程式。僅供探索：當你即將撰寫程式時，透過 `discover` + `invoke` 觸及它，如此你永遠不必自行定位元件檔案。 |
| `agent_run {task, session?, close?, fork?, model?, modelTier?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | 在子代理會話中執行一項任務並回傳其最終回覆。沒有 `session` 時，它會啟動一個**全新的**子項（自有 runner、自有迴圈）：其 `model`/`modelTier`/`thinking`/`tools`/預算來自此次呼叫，並在其第一個回合凍結，正如延續會話的設定一樣。有 `session`（先前回傳的 `sessionId`）時，它會給該**既有子項另一個回合**——其會話、模型、思考、工具與預算都在其第一個回合凍結，因此呼叫端的 model/thinking/tools/budget 引數會被忽略，而結果會回報子項的 `effective` 控制項；該子項必須屬於此會話、不得已關閉，且不得處於回合進行中（那會以 `code: "busy"` 拒絕——請改用 `agent_spawn` 排入佇列）。全新執行可選的逐工作預算：`maxRounds`（每回合的工具輪數，1–`NIF_MAX_TURN_ROUNDS`）、`maxCalls`（工具分派總數，1-500）、`maxTokens`（累計 token）——耗盡會以預算耗盡失敗結束該回合。`model` 是精確的 id，而 `modelTier`（`weak`/`medium`/`strong`）會透過 `NIF_AGENT_MODEL_*` 解析，並被夾限至父項的層級——兩者互斥。`close: true` 會在此回合後退場該子項（不會刪除任何東西；之後的延續會拒絕）。 |
| `agent_spawn {task, session?, close?, fork?, model?, modelTier?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | 在背景啟動同類任務；立即回傳 `{jobId, sessionId}`。沒有 `session` 時，它會啟動一個全新子項；有 `session` 時，它會為既有子項**排入**另一個回合（與 `agent_run` 相同的凍結控制項規則，但處於回合進行中的子項無妨——該回合會接著執行；只有血緣上的父項可以延續）。`close: true` 會在排入佇列／背景的回合結束後退場該子項。`timeoutMs` 是工作預算：一旦超過，該工作會在其下次被觀察時被取消（agent_stop 語意）。 |
| `agent_status {jobId}` | 非阻塞的持久工作查詢（running/done/failed/stopped + 回覆或錯誤）。 |
| `agent_wait {jobId, timeoutMs?}` | 阻塞直到背景工作進入終態；較晚的等待會讀取持久記錄。 |
| `agent_stop {jobId}` | 真正取消執行中的工作：子項的 LLM 請求會被中止，其回合會迅速結束，而進行中的 bash 命令會被終止（整個行程樹）。終態記錄會標示「stopped」。 |
| `agent_steer {session_id, message}` | 將訊息注入執行中背景工作的回合（在 LLM 輪次之間汲取）。 |
| `agent_ask {session, question, timeoutMs?}` | 向子項提問並取得其回答。閒置的子項會直接回答——這是一般的延續（`timeoutMs` 界定等待，預設 300 秒）——而處於**回合進行中**的子項無法開始第二個回合，因此問題會以父項郵件排入佇列，並隨其下一個延續送達（結果會標示 `queued: true`、`deliveredVia: "next-turn"`）。與 `agent_run` 相同的血緣授權適用：未知、外來與已關閉的子項會拒絕。受核准閘控。 |
| `agent_list {scope?}` | 呼叫端的子代理名冊，衍生自持久血緣：每個子項一列，含其 `sessionId`、`jobId`、`task`，以及以駐留狀態為基礎的 `status`——`running`（正在工作）、`idle`（回合之間駐留）、`ready`（僅儲存；**可續行，尚未完成**）。`scope: "descendants"` 會走訪你下方的整棵樹，而預設的 `children` 是深度 1 的視圖；一旦 `NIF_AGENT_MAX_DEPTH` 提高到 1 以上，真正的巢狀就會存在。子項結束時你會被告知，所以這是用來定位，而非輪詢。 |
| `agent_notices {session?, peek?}` | 汲取此會話待處理的子代理**結束通知**——每個已完成、已停止或失敗的背景子項一筆。通知會自動送達（見下文）；這是用於在會話閒置時送達的通知，而 `peek` 只查看不消耗。 |

### Settlement notices

進入終態的背景子項會告知其**父會話**，而不只是 UI（`ev.agent.done` 僅供觀察）。該通知是一筆持久的 `agentnotice` 記錄，在任何送達嘗試之前寫入，且它是*指標*，而非回覆本身：

- 當父項的回合正在執行時，通知會立即被折入（steer 通道）為一則結構化標記的使用者訊息；would-stop 點也會汲取通知，因此回合無法在最後一步期間完成的子項之上收束（`NIF_AGENT_NOTICE_HOLD=0` 只停用該保留）；
- 否則父項會被**喚醒**：agent 元件會啟動一個回合，其唯一工作就是折入待處理的通知，因此結束無須人類詢問即可見。喚醒受 `NIF_AGENT_WAKES` 界定（預設 3 個連續喚醒回合；人類的下一則訊息會重設預算，`0` 停用喚醒）。被拒絕的喚醒不持久化任何東西，而父項的下一個回合會在回合開頭汲取每一筆待處理通知（pull 通道）——因此模型永遠不必輪詢；
- 無論哪種方式，通知都帶有具界的 `summary`、`replyBytes`（未截斷的長度）與 `fullReplyIn: "agent_status"`，因為完整回覆已持久於 `agentjob` 記錄中，只差一次呼叫。

通知是盡力而為：無法觸及的儲存或 agent 元件只會損失一則通知，絕不會損失一個回合。

### Continuation (sessions with memory)

兩個驅動程式都接受 `session`：先前回傳的 `sessionId` 會給該子項另一個回合，而非鑄造一個全新的。子項會保留其會話——只傳送新任務。授權是持久血緣關係（`sessionmeta.parent`），因此只有子項自己的父會話可以延續它，而每個失敗都會明確拒絕：未知會話、根會話、外來子項、已關閉子項與無法觸及的儲存都會回傳不同的錯誤，而非默默啟動一個全新子項。

兩個驅動程式恰好在其承諾不同之處有所差異：

- `agent_run {session}` 承諾**現在**就有結果，因此處於回合進行中的子項會被拒絕（`code: "busy"`，並指名 `agent_spawn`/`agent_wait`/`agent_status`）；
- `agent_spawn {session}` 承諾工作**會發生**，因此它會排入佇列——子項的 runner 會序列化回合，並接著執行排入佇列的那個。

延續是僅附加的歷史：後續任務會持久化為下一則使用者訊息（無前言、無系統提示），因此子項的快取前綴得以存續。每個回合都會推進子項的啟用帳冊（`sessionmeta.activations`，含 `firstActivationAt`），而背景延續會在其 `agentjob` 記錄上蓋上 `continued`/`activation`。`close: true` 會在回合後退場子項（`sessionmeta.closed`）——記錄與逐字稿存續；只有進一步的延續會拒絕。

### Delegation depth

`NIF_AGENT_MAX_DEPTH`（預設 **1**）界定委派可巢狀的深度，於分派時走訪 `sessionmeta.parent` 連結來評估。`0` 完全禁止委派。生成工具在上限處仍保持可見：被拒絕的啟動會回傳一個指名該限制與呼叫端深度的錯誤，因此模型得以得知原因。將其提高到 1 以上是刻意的行為——子項的同步 `agent_run` 會由 agent 元件以可重入方式服務（見 WIRE.md「Delegation depth」），而來自子項的 `agent_spawn` 完全不需要可重入性（背景工作從不持有幫浦）。

### Fork (a child that has read the discussion)

`fork: true | {"lastK": n} | {"maxChars": n}`——僅在**全新生成**時（fork 是誕生，不是延續；`fork` + `session` 會被拒絕）——在其第一個請求之前，以本會話的**已完成回合**播種子項的訊息日誌，因此子項是*讀過*討論，而非被告知討論。結果與 `session_info` 會帶有出處（`{source, uptoId, copied}`）。

- **切點是平衡的且從 0 起連續**：它只落在已完成回合的邊界上——絕不在工具輪次中途——而種子是能以有效供應者訊息清單重放的最長逐字稿前綴（每個 `tool_calls` 都有其工具記錄應答，沒有孤立的工具記錄）。尾端進行中的回合會被排除；崩潰在歷史中途留下的懸置會在此截斷 fork（失敗關閉勝過複製不平衡的前綴）。
- **預算在回合邊界切分**，而捨棄一切的選擇會失敗關閉——一個空的子項會看似成功卻是錯的。
- **不會複製的內容**：逐訊息的 `usage` 計量（子項的記帳是它自己的）、`summary`/`error` 角色記錄（summary 是對原始複製之記錄的衍生；error 記錄是父項的稽核）、工具集快照（`<session>:tools`），以及標頭的控制欄位——fork 是誕生：呼叫端的 `tools`/`maxRounds`/… 引數會從此次呼叫凍結子項的控制項，絕非父項的。
- **冷啟動**：子項的第一個請求會以未快取方式重放繼承的歷史；從第二個回合起才暖。那是*判斷*繼承的代價，且只有在序言否則必須敘述脈絡時才是正確的取捨。不需要判斷的大量傳輸，正是 `fabric` 的用途。

### Fabric (programmable tool calling)

- **治理，而非沙箱**：客體處於 bash 的信任等級——人類核准該程式一次（`x-harness.approval: always`）。每個巢狀呼叫都會穿越會話巢狀呼叫代理（`svc.session.<id>.tool`），重新進入單一分派閘門（核准、完整 schema 驗證、期限）。執行器子項不持有 NATS 連線、不持有憑證，也不繼承 `NIF_*` 環境：它只看得到 `PATH`、一個臨時 `HOME`/`TMPDIR` 與快取路徑。
- **核准清單**：程式核准會顯示來源摘要、`var/approval-sources/<digest>.nim` 下的完整程式（模式 0600）、選定的工具，以及宣告的預算。持久化的自動核准以 `fabric:<digest>` 為鍵——核准一支程式絕不會涵蓋另一支不同的程式。
- **防護**：代理會拒絕隱藏工具與內部／遞迴介面（`fabric`、`agent`、`chat`、`session`、`invoke`、`session_prepare`）；逐回合租約會使過期請求失效；在具型別模式中，每個呼叫都會對照固定的元件指紋檢查，因此執行中途被替換的元件會以 `catalog-changed` 失敗，而非呼叫一個已漂移的工具；`maxCalls` 界定呼叫數；
  `x-harness.noSpawn` 會在分派時拒絕來自子代理的子代理生成。
- **感知效應的批次處理**：`batch()` 在匯流排上同時最多保留 4 個呼叫。每個工具依 `x-harness.effect` 分類（任何未宣告者都算作寫入）；讀取可以一起填滿上限，寫入則是全域互斥，而非逐目標。
- **脈絡經濟**：中間結果永不進入會話；過大的 `finish()` 值會溢出至 `var/fabric-artifacts/<run>.json`（模式 0600），而工具結果會指向該路徑。
- **客體 API**：`import fabricguest` 提供結構化的 `call(tool, JsonNode) ->
  JsonNode`、`batch`、`finish(JsonNode)`、`log`/`logg`、`stringArg`/`inputs`（加上舊式的 `callTool`/`j*` 字串輔助函式）。`fabricmeta.nim` 會把固定的執行時 schema 轉成輸入具型別的包裝函式；除非工具宣告了純量 `outputSchema`，否則結果為 `JsonNode`。`fabric_help` 工具會從元件內部回傳參考與範例原始碼，無須定位檔案。實作範例：`components/fabric/examples/`。
- **何時用什麼**：逐步判斷的工作用直接迴圈；機械式、已知形狀的編排用 `fabric`；需要自有脈絡的探索性子任務用 `agent_run`；混合程式可以呼叫 `agent_run`。

## Expert advisory peer (`expert`)

`expert` 元件是一個非互動式的諮詢同儕（設計：
[research/EXPERT.md](research/EXPERT.md)——§2 知識前綴、§4 排程、
§5 判斷契約、§6 回合界線建議、§8 成本與可觀察性）。它會並行跟隨一個或多個工作
會話——以 `expert_follow {session_id}` 明確武裝
（受核准閘控、預設關閉，且隨需啟用：以 `discover` +
`invoke` 武裝它，或從 shell 以 `./var/bin/cli call expert_follow
'{"session_id": "conv-…"}'`；在此之前該元件是惰性的）——觀察
每個被跟隨會話的
`ev.session.<id>.*` 事件（toolcall 開始／完成——判斷觸發器——回合
開始／完成、助理文字、token 差異的推理尾端，以及視窗 80 % 處的
脈絡壓力觸發）進入一個具界的逐會話記憶體內當前回合框架，該框架在回合完成時清除，因此任何證據永遠不會
跨越回合，並詢問一個 LLM 評判者（一個無狀態的隱藏 `chat` 呼叫：固定的
快取穩定知識前綴——依 `llm.llm_resolve` 調整至評判者視窗的 80 % 減去 8 000 token 保留量，用於觀察與裁決，
並逐跟隨快取——加上一個短暫的觀察，無工具）該
證據是否值得一則 steer。只有指名現行、
非隱藏工具的高信心 steer 會被送達，且僅在閘門成立時：該 steer 帶有
非空的 `tools` 清單與在 `MaxMessage` 上限內的非空訊息，每個
名稱都會被正規化（去除反引號、`component.tool` 縮減為工具）、
必須對該會話可見、必須出現在訊息文字中，且其中至少
一個必須是工作者在此回合尚未使用的工具——一則只指名
框架中已有工具的 steer 會被讀作沉默，而非工具
的改變。送達是透過回合界線的
`svc.session.<id>.advise` 請求／回覆介面：runner 僅在該確切回合仍在執行時
接受建議——遲到的建議會被拒絕
（`stale-turn`/`no-active-turn`，加上 `wrong-session`、`empty` 與 `duplicate`
用於對上一則建議的精確重複，以及 `advisory-limit` 一旦該回合已有
一則），永不排入下一個回合。被接受的
建議會折入為一則標記的使用者訊息（`[Niffler advisor: expert] ...`）、
持久化，並在 `ev.session.<id>.advice` 上公告。評判通道本身保持
全域：一次判斷在途、共享冷卻、逐會話最新狀態合併。每個被解析的判斷——包含沉默——都會以
`ev.log.expert` 行發布（動作、原因、訊息），這是操作者回答
「它為何沉默？」的方式。已發布的數字：每回合最多 2 次判斷
（`MaxJudgmentsPerTurn`），彼此至少間隔 8 秒（`EvalCooldownMs`）；
框架保留 8 筆近期工具活動（`MaxActivities`）、每個欄位截斷於
400 字元（`MaxField`）、保留 2 000 字元的推理尾端（`MaxReasoningTail`）
並將建議訊息上限設為 1 200 字元（`MaxMessage`）。評判呼叫
本身上限為 1 536 個輸出 token（`JudgeMaxOutputTokens`）、要求
`reasoning_effort: "low"`（`JudgeReasoningEffort`）並在 120 秒後逾時
（`ChatTimeoutMs`）——三者皆為編譯期常數，因此更改其一即意味著
編輯 `components/expert/main.nim` 並重建。token 上限是
盡力而為：閘道可能會忽略它。

| Tool | What it does |
|---|---|
| `expert_follow {session_id, model?, provider?}` | 跟隨一個會話（多目標：每個被跟隨的會話保留其自有框架、知識前綴、判斷預算與逐跟隨指標）；重新跟隨會重設其框架。`model`/`provider` 會為該跟隨覆寫判斷呼叫；沒有它們時，評判者會跑在 `llm` 的預設後端（作用中的供應者）上，這使評判成本不落在工作者的模型上。受核准閘控。 |
| `expert_unfollow {session_id?}` | 有 `session_id` 時：捨棄該跟隨。沒有時：捨棄所有跟隨並丟棄其框架。 |
| `expert_reload` | 從現行目錄重建每個被跟隨會話的知識前綴（新的快取世代）。 |
| `expert_status {session_id?}` | 有 `session_id` 時：該跟隨的框架、知識版本、逐會話計數器（judgments、silences、steers、accepted、rejected、staleDrops、errors）、前綴診斷（`liveTools`、`skills`、`prefixChars`、`prefixBudgetTokens`）與評判 token 總計（`tokens {prompt, cached, completion}`）。沒有時：被跟隨的目標加上生命期診斷（相同的計數器與 token 總計，生命期）。 |

該元件沒有自己的配置：沒有任何 `NIF_*` 變數會改變它如何
跟隨或判斷（`NIF_LOG_LEVEL` 只決定其自有的
`ev.log.expert` 行是否可見）。

設計不變量：工作會話永不等待 expert
（盡力而為、冷卻、最新狀態合併）；沒有增長的 expert
逐字稿（每次判斷都是無狀態的），且元件本身不持久化任何東西——框架、前綴與計數器都活在行程中，因此重啟會丟棄
每個跟隨，而重新武裝是明確的；被接受
steer 的唯一存放產物是被跟隨會話中折入的訊息記錄）；失敗關閉
（任何解析／驗證／
傳輸錯誤都是沉默）；expert 永不採取行動——它只建議，而
受核准閘控的工作仍留在工作會話的人類閘門。

前綴持有該元件自己的政策、三個經審查的隨附技能
（`niffler-tools`、`niffler-fabric`、`niffler-harness`——一個遮蔽隨附名稱的專案或家目錄技能
會被拒絕，因此該允許清單即為信任
邊界），接著是被觀察會話自己的工具視圖：其凍結的直接
曝露與工具允許清單（讀自 `core.prompt_preview`）加上它可 `discover` 的隨需
工具。絕非全域 LLM 工具集——那會誇大
一個較舊或受允許清單限制的會話實際能呼叫的內容。

## Advisory discovery (`jev`) and the Von launcher

`jev` 元件是一個可選加入的實驗性 spike（設計與誠實的極限：
[docs/research/JEV-SPIKE.md](research/JEV-SPIKE.md)）：一個小候選清單之上的
精簡、可替換的顧問，由本機決策模型支撐。它是三個隨需、讀取效應的工具：

- `jev_recommend {task, query, kind: "tools"|"skills"}` — 可用的一步路徑：
  從 `core.discover`（隨需提示）或 `skill_list` 取得全新候選清單，然後詢問
  後端哪一項合適。查詢必須狹窄且非空（1–24 個候選；過大的集合拒絕而非
  截斷，空清單或空建議是有效答案）。
- `jev_suggest {task, candidates}` — 給自帶 1–24 項候選清單的呼叫方；在
  一個請求中配對 `noul`（有任何能力有幫助嗎？）與 `choice`。
- `jev_decide {state, questions}` — 原始的 System One 類型化問題
  （`noul`/`choice`/`score`），有界 state，無副作用。

它們**僅供建議**。不載入 schema、不載入技能、不呼叫任何東西、不授予
任何權限，回報的是未經校準的實驗性訊號 — 絕不是策略，絕不是核准閘門。
派送與核准仍是唯一的執行路徑，因此行動前必須用 `discover` ＋ `invoke`（或
`skill_load`）確認答案。後端故障是失敗開放的結果：繼續用普通探索。端點
在構造上僅限本機（`NIF_JEV_URL` 必須是不重導向的回環 `/v1/systemone`
URL），因為決策輸入攜帶私有倉庫脈絡 — 絕不要在 `task` 中傳遞秘密或
檔案內容。

推薦的整合方式是 **fabric 程式**，而不是直接迴圈：候選清單和原始答案留在
guest 中，只有已驗證的結果進入會話。`components/fabric/examples/
advisory-ranking.nim` 是可執行的形態（顧問 → 驗證 → 同一程式內的詞法後備，
因此決策模型的缺失絕不決定探索是否發生）；
`fabric_help {topic: "advisory-ranking"}` 返回其原始碼。

**影子實驗。** 為了在不打擾任何人的情況下收集證據，`jev` 還會在背景
判斷每次回合開始（預設開啟；`NIF_JEV_SHADOW=0` 關閉）：一個觀測已安裝的
技能清單，一個觀測可發現的隨需工具，使用該回合的請求（上限 2,000 位元組），
以及 — 除非設定了 `NIF_JEV_SHADOW_TOOL_QUERY` — 由其最長單詞衍生的詞法
查詢。每個候選集上限 24；過大的集合記錄為 `no-candidates`，絕不截斷。
不向模型暴露任何內容，不觸碰任何轉錄，會話的凍結前綴不受影響（整個元件
唯一的提示快取效應是在明確呼叫這些工具時附加的 tool history）。結果落在
儲存 kind `jevshadow`（`<sessionId>:<turnId>:<kind>`，可與轉錄 join），
攜帶候選快照、原始答案、`elapsedMs`/`queueMs`、終止 `status`（`done`、
`error`、`no-candidates`、進行中的 `pending`、回合先關閉時的 `stale`）與
`turnClosed`；judge 作為獨立的 PDEATHSIG 子行程執行（12 秒硬限制，一次
一個，有界佇列），因此 NATS 泵保持回應。**後端缺席是原裝安裝的預設狀態，
而不是實驗資料**：刪除進行中的標記，一則 `ev.log.jev` 警告標記中斷，
後續判斷暫停 60 秒冷卻並靜默重試 — 因此後端一旦應答，影子會自動恢復。
記錄包含任務文字 — 按敏感資料處理。

**啟動後端。** [Von](https://github.com/wfzyx/von) 是獨立的 Python 執行時，
刻意置於 `make build` 之外：

```bash
make install-jev   # idempotent: uv venv var/jev-venv + von-sdk (~5.4 GB)
make von-up        # enable the supervised launcher (persisted spawn record)
make von-down      # disable again (stops it, deletes the record)
```

`make install-jev` 從不屬於 `make setup`（體積與選用性就是原因）。`von`
**不在 manifest 中** — 啟用是一條持久化的 `core.spawn` 記錄，與外掛完全一樣，
因此監督器像管理任何元件一樣管理啟動器（PDEATHSIG、重啟原則、drain），
原裝 harness 從不為該執行時付費。啟動器以內核清理的子項
（`setpriv --pdeathsig`，監督器自己的包裝）啟動 venv 二進位檔，收養已在
端點應答的 Von 而不是重複啟動，並在閒置接縫上重新檢查稍後的
`make install-jev`。用 `von_status` 詢問它在做什麼：`starting`（Von 正在
載入權重 — 首次 serve 會下載模型，CPU 試驗中約 115 秒，因此在依賴 `jev`
前先輪詢）、`serving`（端點應答）、`absent`（venv 二進位檔缺失）或 `failed`
（子項退出；有上限的退避）。狀態只是啟動器自身視角的聲明 — 真正的
探針是 `jev` 呼叫。因為啟動器是普通的 spawn 記錄，LLM 也可以在會話中
啟用它：`discover` ＋ `invoke spawn {name: "von", arguments…}` — 與每個
`spawn` 一樣受核准閘控。

## Recovery

儲存庫是快照；`var/` 是可丟棄的建置輸出——以 `make clean` 刪除建置
輸出，絕不要用裸的 `rm -rf var`；而一個拒絕啟動的 `store` 意味著另一個行程仍持有鎖
（`var/store.db.lock` / `var/barrel-db.lock`），而非一個過期檔案：`make down`
或殺掉過期的 store，核心便會釋放它。如果 agent
（或某個 bug）弄壞了隨附元件——覆寫了 `var/bin` 中的二進位檔、
損毀了某個生成元件的記錄，或某個自行新增的元件在開機時崩潰——請以復原模式啟動 Niffler：

```bash
make recover        # stops anything running, then ./var/bin/niffler --recover
```

`--recover` 依序做三件事：

1. **從原始碼重建隨附的二進位檔**（`make build`，退回
   至 `nimble all`）——修復被覆寫／損毀的 `var/bin/*`。
2. **抹除儲存的元件記錄**——沒有殘留的持久化額外元件
   形狀可供還原。
3. 啟動所請求的設定檔（通常是完整的互動式 harness；
   `--recover --minimal` 選取最小設定檔）。**會話與
   訊息存續**——只有元件形狀被重設。

對於*原始碼*的損壞（有人編輯了 `components/`、`core/`、`sdk/`、
`manifest.yaml` 或 `Makefile`）：

```bash
# stop the harness first (close the UI, or Ctrl-C ./var/bin/niffler)
git restore components/ core/ sdk/ manifest.yaml Makefile   # or: git checkout -- .
make build
./var/bin/niffler                       # or just reopen the UI
```

## The store

`store` 就像其他任何元件一樣——一個位於匯流排上的文件儲存，具備
`put` / `get` / `list` / `del` 以及以 rev 為基礎的樂觀並行控制
（`put` 接受 `expectRev`，不符時以 `rev-conflict` 失敗）。barrel
引擎另外註冊了一個隱藏的 `selftest` 工具——一個真正的
put/get/rev/list/`del` 往返，`/doctor` 可以呼叫；兩個 SQL 引擎
只註冊那四個工具。
`put`、`get` 和 `list` 是隨選工具；`del` 是隱藏的——由 core 刪除
記錄，模型無法。`put` 也帶有 `x-harness.sessionId`，這正是讓下方
寫入圍籬得以成立的原因。**受會話綁定的呼叫者只能寫入精選的種類**
（目前是 `fabricprog`）：其他每個種類都由 harness 管理，並以
`forbidden-kind` 拒絕，因此任何執行中的會話都無法損毀逐字稿或元件
記錄。直接的匯流排呼叫者（cli、測試、core）保有完整存取權。
core 及其元件使用中的種類（store 工具自身的 docstring 只列出
其中一部分——這張表才是完整清單）：

| Kind | Id | Value |
|---|---|---|
| `conversation` | `conv-<ts>` | `{createdAt, model, title}`——會話標頭（也帶有凍結的系統提示、模型／思考選擇、各會話的預算控制與 token 計量器） |
| `message` | `<convId>:<seq>`（序號補零至六位數——id 順序即訊息順序） | `{conversationId, role, content, ...}` |
| `component` | `<name>` | `{name, binary, policy, addedAt}`——開機時還原的持久化形狀 |
| `plugin` | `<pkg name>` | `{name, repo, ref, dir, version, components, addedAt}`——`plugins` 元件的安裝記錄 |
| `provider` | 暱稱（加上 `active` 標記文件） | `provider` 元件的 LLM 供應商登錄。憑證以**明文**儲存——儲存檔案本身就是機密——而遮蔽只發生在工具回應中（`provider_list`；`mcp_servers` 同樣會遮蔽 `mcp` 記錄的 `env`/`headers`）。這涵蓋了兩種種類的機密，因此任何 `var/store.db` 或 `var/barrel-db` 的副本都是它們的副本 |
| `session` | `<sessionId>:tools` | 該會話凍結的直接工具集快照（見 [Progressive tool discovery](#progressive-tool-discovery)） |
| `slash` | `slash` | UI 所渲染的合併斜線指令表（見 [WIRE.md](WIRE.md)） |
| `agentjob` | `<jobId>` | 持久的背景 `agent_spawn` 工作記錄（續延會蓋上 `continued`、`activation`，以及佇列 `close`） |
| `agentnotice` | `<parentSession>:<seq>` | 子代理結算通知（摘要 + 指向完整回覆的追索；`deliveredAt`/`deliveredVia` 標記遞送） |
| `sessionmeta` | `<sessionId>` | 子代理血統／執行器中介資料：生成時為 `{parent}`；續延會加入 `activations`（回合數，從 1 起算）與 `firstActivationAt`；`close: true` 退役會設定 `closed` |
| `fabricprog` | 程式名稱 | 由模型精選的 fabric 程式庫（`fabric {name}` 執行其中一個） |
| `profile` | 設定檔名稱 | `profile` core 工具的具名工具設定檔選擇器清單；在其第一個回合時解析一次並寫入會話的直接工具集 |
| `approval` | `<sessionId>:<key>` | 用戶端的「不要再問」授權（以工具為鍵，或程式形狀的呼叫為 `tool:<digest>`）；core 讀取它以跳過核准閘門 |
| `contextreceipt` | `<convId>:<requestId>` | 溢位復原嘗試的要求範圍收據，在耗用之前寫入，並以結果更新 |
| `compaction_input` | `<convId>:<attemptId>` | 分頁的壓縮前快照，壓縮元件據以驗證、執行器據以提交（分頁為 `<id>:p<idx>`）。短暫性：嘗試一結算即刪除，而因當機或逾時的嘗試而孤兒化的分頁會在 600 秒後清掃——任何東西都不得將其視為持久（只有 `context_projection` 才是） |
| `context_projection` | `<convId>` | 每個會話一份文件——已提交的上下文投影（`version`、`generation`、`canonicalHigh`、`renderer`、正規化的 `checkpoint`、持久的 `covered` 正規範圍、`retained` id、`prunes`、`measurements`、`provenance`），執行器在壓縮後重用。以前一代的 `expectRev` 寫入一次；它是重新啟動時重建供應商視圖的真相來源，而當通知指名 `checkpoint` 參照時，回想解析器會讀取它的 `checkpoint`/`generation` |
| `spill` | `<convId>:<n>` | 一個被提升出上下文視窗的過大工具結果，可用 `context_recall {"ref": {"source": "spill", "id": "…"}}` 定址。提升在附加時為盡力而為（失敗會保留暫存檔指標且不加入參照）；缺失、空或格式錯誤的 spill 文件會被大聲拒絕，而非以空成功回應，且修剪閘門在修剪前會重新驗證該文件，因此損壞的 spill 絕不可能賠上最後一份副本 |
| `mcp` | 伺服器名稱 | `mcp` 元件的 MCP 伺服器設定記錄（見 [External MCP servers](#external-mcp-servers-mcp)） |
| `jevshadow` | `<sessionId>:<turnId>:<kind>`（`kind` = `tools`/`skills`） | 建議式探索實驗（`jev`）的每回合影子觀測：候選快照、原始答案、`elapsedMs`/`queueMs`、`status`/`turnClosed`。絕不向模型暴露，也絕不寫入轉錄；後端缺席時**不**寫任何記錄（見[建議式探索](#advisory-discovery-jev-and-the-von-launcher)）。記錄包含任務文字 — 按敏感資料處理 |
| `selftest` | store 自我測試探針 | 用後即丟——由 store 自身的自我測試往返寫入並刪除 |

後端是所選的引擎——預設為位於 `var/store.db` 的 SQLite，
`NIF_STORE_BACKEND=barrel` 時為位於 `var/barrel-db` 的 BitBarrel，或
DSN 共享的 TiDB 引擎（`NIF_STORE_TIDB_DSN`，無 flock——由資料列鎖與
rev 計數器在 harness 之間仲裁）。**恰好只有一個行程擁有該檔案**——
絕不要對同一個資料庫執行兩個以檔案為後端的 `store` 行程（對同一個
root 開機的第二個 core 就會這麼做；實驗時請使用暫存的 `NIF_ROOT`
副本）。

`list` 是一頁，不是完整視圖（見 [Store engines](#store-engines)）：
core 中所有必須看見整個種類的東西都走 `storeListAll`——
單一有上限的 `list` 在續接時曾悄悄截斷長逐字稿。`search` 則把「哪些對話提到過 …」變成伺服器端查詢，而不是先下載再過濾：`cli call search '{"kind":"conversation","query":"…"}'`（要在逐字稿文字中查找則用 `message`）返回與 `list` 相同的分頁結構。

## Testing

```bash
make test           # the full gate: the bus-contract suite (the desktop UI's
                    # frontend tests + typecheck live in gokr/niffler-ui)
make test-server    # ... server side only: one test-owned NATS per test, no node
make test-bash      # ... or just one — `make help` lists every target
                 # (test-uireg, test-autostart, test-<component>); the full
                 # bus suite is `make test-server`
```

`make test-server` 透過 `scripts/run-tests.sh` 在有界池中執行約 60 個
測試二進位檔（預設每個 core 一個測試）：測試各自擁有私有的 NATS
伺服器與暫存 root，因此它們能安全地重疊。每個測試的輸出會擷取到
`var/test-logs/<name>.log`，其牆鐘時間在完成時印出，摘要則列出最慢
者——可用 `TEST_JOBS=N`（或直接對腳本用 `NIF_TEST_JOBS=N`）覆寫；
`TEST_JOBS=1` 是舊的循序執行，而無論哪種方式日誌都保持逐測試。
`NIF_TEST_VERBOSE=1` 會將每個測試擷取的輸出交錯在其行之後。

每個測試都會啟動真正的元件二進位檔（Nim、Go *以及* TypeScript——
信封就是產物，因此一個 harness 測試每個 SDK），並透過每個測試為
自己啟動的私有 nats-server 驅動它們（`NIF_NATS_SPAWN` 式的隔離）。
桌面 UI 的前端測試不屬於這套件：UI 現在是
[gokr/niffler-ui](https://github.com/gokr/niffler-ui) 外掛，其 lib
單元測試與型別檢查在該儲存庫中執行（在該處 `make test` /
`make typecheck`），因此這個閘門保持自足。
以 core 為基礎的測試會將其所需的二進位檔快照到唯一的暫存
`NIF_ROOT`；Barrel、外掛複製、生成的元件、日誌與快取因此都被隔離。
個別的 `make test-*` 目標可以彼此並行執行，也可以與執行中的開發
harness 並行——`scripts/run-tests.sh` 正是靠這點來池化整套件。儲存庫
建置寫入（`make build`、`make clean`）由 `scripts/with-build-lock.sh`
序列化；執行時的 `builder.build` 不取該鎖，因此在第二個終端機的
`make clean` 會在執行中的建置底下刪除 `var/bin` 和 `var/build`。
代理建置的測試元件使用沙箱本地的 Nim 快取。

有幾個測試帶有自己的 fixture，而非真正的模型：
`components/ctxtest/` 是一個 stub-LLM 元件（一個隱藏的 `chat`，會依
會話 id 播放腳本化的回合），它也提供真正的工具無法隨選產生的契約
fixture——參數名稱改寫、schema 衝突、目錄重新發布的擾動、供 fabric
批次主機使用的 `effect: "read"` 項目、純量 `outputSchema`——外加
`ctxecho`，這個 `sessionContext` 探針證明 harness 私有上下文會從巢狀
呼叫中被剝除；`components/ctxtest/sink.nim` 註冊了第二個元件
（`ctxsink`，會回報 `sawSession`）以供同一項檢查使用。
`tests/mock_llm.nim` 和 `tests/mock_parallel_llm.nim` 是 `llm`
二進位檔的對等替身。它們都不在 `manifest.yaml` 中，也不由
`make build` 建置：每個測試將所需的那一個編譯進其私有的沙箱
`NIF_ROOT` 並在該處啟動它。

`/doctor deep` 另外會透過匯流排（`comp.selfTest`）向每個元件自身的
自我測試展開：例如 `bash` 真的會透過其行程群組路徑執行一個指令，
然後在 1 秒預算下證明逾時終止，預期結束碼為 124。未實作自我測試的
元件會列在 `selftestMissing` 之下（並作為一列
`selftest (not implementing)` markdown 列）——這是涵蓋範圍資訊，絕非
失敗的檢查。

壓縮契約有它自己的驗證通道：
`make test-compaction` 執行端對端的 propose/commit/restart/reload
fixture，而 `make test-conformance --bin:<path> --tool:<name>` 將同一套
contract-v1 套件指向替代的壓縮器——這是第三方摘要器的驗收測試
（兩者都搭上萬用字元的 `t_*` 套件，因此 `make test-server` 也會執行
它們）。`make live-smoke` 是選擇加入的實時閘門：對真正的供應商進行
真正的摘要，`SYNTHETIC_API_KEY=...`，在套件之外。

網路選擇加入：`NIF_TEST_INSTALL=1` 執行真正的
`cli install gokr/niffler-weather` + 工具驗證；`NIF_TEST_NETWORK=1`
對 GitHub 執行 `plugin_search`、對 skills.sh 執行 `skill_search`，以及
TypeScript builder 建置（npm registry）。安裝管線本身由 `t_plugins`
透過本地的 `file://` git 儲存庫以密封方式涵蓋。
觀察／日誌檔測試使用暫存輸出目錄，且絕不刪除開發者的 `var/logs` 或
`var/captures`。外部網路選擇加入即使其本地狀態已隔離，仍可能共用
供應商的速率限制。

## Starting and stopping

沒有啟動器腳本——二進位檔自己擁有生命週期：

- **桌面圖示 / `niffler-ui`**——最常見的情況。橋接器的第一個動作
  是 SDK 的 `ensureHarness`：探測 `NIF_NATS_URL` → `var/nats-url` →
  127.0.0.1:4222，尋找服務**此 root** 的 core（目錄帶有擁有該
  harness 的 root；外來複製的 core 絕不會被採用）；若無人回應，則以
  `NIF_AUTOSTART=1` 分離啟動 `var/bin/niffler`。該二進位檔本身由
  `make install-ui` 安裝——桌面 UI 是
  [gokr/niffler-ui](https://github.com/gokr/niffler-ui) 外掛，由
  builder 建置到 `var/bin/niffler-ui`，並由 `make install` 連結到
  PATH。探測很有耐心：附加會以 200 毫秒重試約 10 秒，而啟動的 core
  必須在 20 秒內回應，否則 `ensureHarness` 會以 `spawned core did
  not answer within 20s — check <root>` 失敗（Nim SDK 會先回收它在
  同一會話中較早啟動的 core，若它已結束）。
- **互動式外掛**（例如 `niffler-tui`）——它們**不會**呼叫
  `ensureHarness`，也絕不啟動 harness：它們探測執行中的匯流排
  （`NIF_NATS_URL` → `$NIF_ROOT/var/nats-url` → `./var/nats-url` →
  127.0.0.1:4222），連線並註冊 `client: true`（因此自動啟動的 core
  在她們執行期間保持運作）。與 `ensureHarness` 不同，它們**不會**
  檢查回應的 core 服務哪個 root，因此 TUI 可以加入桌面 UI 會拒絕的
  外來 harness 匯流排。這條鏈是逐用戶端的：Nim 用戶端（`cli`、
  `console`）探測 `NIF_NATS_URL` → `<NIF_ROOT 或其自身複製>/var/nats-url`
  → 127.0.0.1:4222，絕不探測 cwd，而 bash `dialog` 使用
  `NIF_NATS_URL` → `./var/nats-url`（僅 cwd）→ 127.0.0.1:4222。請先
  啟動 harness——桌面 UI 或 `./var/bin/niffler`。
- **終端機管理殼層**——直接執行 `./var/bin/niffler`，或
  `./var/bin/niffler --minimal` 以使用三元件開機設定檔。手動啟動的
  core 絕不會自行終止；以 Ctrl-C / SIGTERM 停止它。環境中的
  `NIF_AUTOSTART=1` 會覆寫殼層——即使在 tty 上該 core 也是服務模式
  ——而當它停在提示字元時，它會持續服務 `svc.core.call`，因此 UI 可以
  附加到 tty 啟動的 core。

互動式前端會註冊 `"client": true`（SDK 的 `interactive()` /
`Component.Client` 標記）。`console` 和 `dialog` 依此定義並非互動式
前端：兩者都不註冊 `client: true`，因此自動啟動的 core 可能在它們
底下結束（當新的 harness 出現時，`console` 會自行重新連線）。該標記
是註冊，不是租約：未經 `reg.depart` 就被殺掉的用戶端會讓自動啟動的
core 保持運作——並讓 core 相信有人類可達以供核准——直到目錄將其
移除（`ui` 登錄的 20 秒租約是另一個時鐘，見
[Clients and the UI registry](#clients-and-the-ui-registry)）。**自動
啟動**的 core 會計數它們：當最後一個離開時，它會在
`NIF_AUTOSTART_IDLE_S`（預設 10 秒——重新啟動的 UI 會在该視窗內重新
註冊）之後關閉，並帶走其元件與啟動的匯流排；若從未有任何一個到來，
它會在 `NIF_AUTOSTART_BOOT_S`（預設 60 秒）之後放棄。關閉附加到
*手動*啟動 core 的 UI 不會改變任何事——core 保持運作。
`NIF_ENSURE_ATTACH=0` 讓 `ensureHarness` 無條件啟動（測試）。
明確的 `NIF_NATS_URL` 則以另一種方式短路：用戶端只附加到那個匯流排，
不探測也不啟動任何東西。（`NIF_NATS_SPAWN=1` 是 core 端的孿生項
——一個在隨機埠上、由 core 擁有的隔離匯流排，絕不使用 4222；見
[Environment variables](#environment-variables)。）

在核心層級，同一條規則成立，只有一個刻意的例外：core 本身沒有
父行程死亡訊號——自動啟動的 core 必須比啟動它的 UI 活得久——而它
啟動的每個子行程都有。受監督的子行程（元件、會話執行器）在
util-linux 的 `setpriv` 位於 `PATH` 時會被包在
`setpriv --pdeathsig TERM` 中，SDK 在其啟動的元件中設定
`PR_SET_PDEATHSIG`，而隨附的 `nats-server` 在其自身的 `main` 中設定
它，因此即使 SIGKILL 也沒有東西能在其 harness 之後存活。在 Linux
之外（或沒有 `setpriv`）兩種機制都不存在，這就是孤兒匯流排的成因
（見 Troubleshooting）。

## Common tasks

```bash
./var/bin/niffler             # full harness in a terminal (admin shell)
./var/bin/niffler --minimal   # store + bash + llm only at boot
niffler-ui                    # desktop UI; autostarts the full profile
make build          # rebuild what changed
make install        # PATH entries (niffler, niffler-cli, niffler-console,
                    # + niffler-ui when its plugin binary exists and the
                    # niffler-tui wrapper on request — never component
                    # binaries such as the `grep` tool (`var/bin/grep`, which
                    # shells out to `rg`), so PATH cannot shadow grep/git/...)
make install-tui    # same, installing the niffler-tui terminal client quietly
                    # (= make install WITH_TUI=1)
make uninstall      # remove those PATH entries again
make install-ui     # install the desktop UI plugin (gokr/niffler-ui): an
                    # isolated auto-approved harness boots, the plugin manager
                    # clones + the builder builds it into var/bin/niffler-ui
make install-lsp    # install the lsp component's default language servers
make install-jev    # 安裝 jev 背後的 Von 執行時（選用，約 5.4 GB；
                    # 不屬於 `make setup`）
make von-up         # 啟用受監督的 Von 啟動器（持久化 spawn 記錄；
                    # `make von-down` 再次移除）
make test           # the full gate: the bus-contract suite (the UI repo's
                    # frontend tests live in gokr/niffler-ui)
make test-server    # the bus-contract suite alone (each test owns a private bus)
make doctor         # check prerequisites
make ram            # RAM of running stacks (harness + components + nats + clients)
make down-here      # stop this checkout's harness, components and spawned bus
                    # only — bench worktrees and other clones survive
make clean          # remove all build artifacts (var/, nimcache/)
```

- **無頭服務模式**（無 tty，供 UI／自動化使用）：
  `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null`
  ——服務 `svc.core.call`；需要核准的工具會被拒絕，除非有 UI 附加或
  設定了 `NIF_AUTO_APPROVE=1`。
- **附加到任何匯流排**：`NIF_NATS_URL=nats://host:4222`（甚至遠端），
  或在 core 之前於預設埠啟動你自己的 nats-server——只有當回應的
  core 服務**此 root** 時，core 才會重用 `127.0.0.1:4222` 上的匯流排；
  外來 harness，或上面沒有 core 的裸 nats-server，會讓 core 發出警告
  並改為啟動隔離的匯流排（指名此 root 自身某個匯流排的殘留
  `var/nats-pid` 會先被回收）。若要刻意強制使用某個匯流排，請設定
  `NIF_NATS_URL`。
- **在沒有 LLM 的情況下探測匯流排**：`tests/` 中的一次性
  `nim c -r` 腳本（見 AGENTS.md 的「Debugging the bus」）。
- **Wails**：桌面 UI（以及任何 Wails 用戶端套件）透過其套件配方
  建置，該配方必須執行 `wails build -tags webkit2_41`（Linux）——
  單純的 `go build` 會產生一個 stub。UI 的 SPA 開發伺服器位於
  gokr/niffler-ui 檢出中（在該處 `make dev`）。
- **監控**執行中系統的 RAM，使用 `make ram`（或
  `watch -n5 scripts/niffler-ram.sh`）：每個堆疊的總計——你的複製、
  `nifflerprod`，以及每個 bench 私有 harness 分別計算——涵蓋 harness
  + NATS + 所有啟動的元件 + 會話執行器 + 用戶端。成員資格依可執行檔
  路徑（`*/var/bin/*`、`niffler-ui`），而非行程樹：tui 是自動啟動
  harness 的*父行程*，而 bench 執行的私有匯流排屬於 bench 驅動程式，
  因此 PPID 走訪會兩者都漏掉。讀取 PSS，而非 RSS：共用同一份
  `var/bin` 建置的堆疊會在 RSS 中重複計算檔案支撐的頁面。`bash` 工具
  的工作負載子行程（編譯器、測試二進位檔）依設計被排除。

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| UI 在桌面應用程式內顯示「Running in a browser」 | `nats.ts` 綁定不符——`window.go.main.Bridge` 必須符合 Go 結構名稱（ui/README.md） |
| UI 橫幅：匯流排無法觸達 | core 自動啟動仍在進行或已失敗——在終端機中啟動 `./var/bin/niffler` 以查看開機錯誤 |
| 開機時出現 `core: WARNING missing binary for <name>` | 執行 `make build` |
| llm 錯誤 HTTP 401/403 | 先檢查作用中供應商的 key 或 token（`provider_status` 可看生效內容的遮蔽視圖，`provider_list` 可看 `expiresAt`）；只有在沒有已儲存的供應商作用中時，`.env` 或殼層環境中的 `NIF_OPENAI_API_KEY` 才會決定 |
| 無頭模式中出現「approval denied」 | 預期行為：沒有可達的人類。附加 UI、使用 `make run`，或在知情的情況下設定 `NIF_AUTO_APPROVE=1` |
| 兩個 store 爭奪同一個資料檔（`var/store.db` 或 `var/barrel-db`） | 單一寫入者規則——每個 root 只有一個 core；在暫存的 `NIF_ROOT` 副本中實驗 |
| 開機拒絕：「this harness has conversation history in var/barrel-db」 | 預設引擎已改為 SQLite，而你的歷史仍在 barrel 中——執行 `niffler-store-migrate --root <path>`（錯誤訊息會印出它），或設定 `NIF_STORE_BACKEND=barrel` 以保留舊引擎 |
| 孤兒化的 `nats-server` | 手動啟動的 `nats-server`、非 Linux 主機（沒有 PDEATHSIG 可回收它），或 SIGKILL 留下的殘留 `var/nats-pid`——檢查 pid 檔（core 會驗證 pid + comm，因此殘留檔案會被忽略），然後 `pkill -f nats-server` |
| 元件在開機時當機，在退避迴圈中重新啟動 | 透過 UI／終端機 `core.remove` 它，或 `make recover` |
| 代理修改過的原始碼 | `git restore components/ core/ sdk/ manifest.yaml Makefile` 然後 `make build`（見 Recovery） |
| 某個回合被取消但編譯持續執行 | `build` 未宣告 `x-harness.sessionId`，且 `builder` 未訂閱 `cancel.build`，因此取消被丟棄：編譯器執行到自己的截止時間，只有回覆被放棄。取消前先等待工具結果，或 `core.kill {name: "builder"}` |
| 會話呼叫失敗：「session runner binary missing」 | `var/bin/session` 從未建置——`make build` |
| `spawn` 失敗：「spawn failed — tool '<t>' already provided by <owner>」 | 註冊被拒絕——幾乎總是已存在的工具名稱（名稱全域唯一；請以元件名稱作為你的前綴）。修正名稱、重新建置並再次 `spawn`：失敗的嘗試已被回滾（複本已停止，未持久化任何東西），因此該名稱立即空出。在 core 的 stdout 上，同樣的拒絕讀作 `catalog: rejecting <name> — …` |
| `spawn` 失敗：「did not register within <n> ms」 | 元件未及時宣告自己——可能是啟動緩慢的元件，或是在途中死掉的二進位檔（core 會將 `var/logs/<name>.log` 的有界尾端附加到錯誤中）。修正原因並再次 `spawn`（該嘗試已被回滾），或為真正緩慢的元件提高 `NIF_SPAWN_WAIT_MS` |
