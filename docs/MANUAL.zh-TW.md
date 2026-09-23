# Niffler 手冊

操作、設定和恢復 Niffler harness 所需的一切，另加內建元件的參考章節。設計理由見
[research/REBOOT.md](research/REBOOT.md)；wire 協議見
[WIRE.md](WIRE.md)；core/元件邊界見
[ARCHITECTURE.md](ARCHITECTURE.md)；未完成工作彙總於
[research/PLAN.md](research/PLAN.md)。

> 🤖 AI 自動翻譯，**滯後於英文版**；以 [English](MANUAL.md) 為準。
> 章節標題保留英文，以便跨文件連結保持穩定。
> 上次全文同步早於 2026-09-18 的文件稽核：英文版此後新增了 9 個章節
> （`bash`/`repomap`/`grep` 詳解、Clients and the UI registry、
> Output caps and `finish_reason`、Repository inspection (`git`)、
> Fabric）並全篇修訂，本檔案尚未重新產生。需要目前行為時請直接閱讀
> 英文原文；完整重新翻譯是一次獨立的專項工作。

[English](MANUAL.md) · [简体中文](MANUAL.zh.md) · 繁體中文

## Contents

- [Layout of a running system](#layout-of-a-running-system)
- [Store engines](#store-engines)
- [State and configuration](#state-and-configuration) · [Environment variables](#environment-variables) · [The `.env` file](#the-env-file)
- [The bus in one screen](#the-bus-in-one-screen) · [Approvals](#approvals)
- [Context window](#context-window) · [Self-extension and component lifecycle](#self-extension-and-component-lifecycle)
- [Component ecosystem (`plugins`)](#component-ecosystem-plugins) · [Skills](#skills)
- [Provider registry (`provider`)](#provider-registry-provider) · [Fetch](#fetch)
- [External MCP servers (`mcp`)](#external-mcp-servers-mcp)
- [Language servers (`lsp`)](#language-servers-lsp) · [Background processes (`processes`)](#background-processes-processes)
- [Progressive tool discovery (`discover`/`invoke`)](#progressive-tool-discovery)
- [Model catalog (`models`)](#model-catalog-models)
- [System prompt (`systemprompt`)](#system-prompt-systemprompt)
- [Observation and logs (`observe`, `logfile`)](#observation-and-logs)
- [Hooks](#hooks)
- [Fabric and subagents](#fabric-and-subagents)
- [Expert advisory peer (`expert`)](#expert-advisory-peer-expert)
- [Recovery](#recovery) · [The store](#the-store) · [Testing](#testing)
- [Starting and stopping](#starting-and-stopping) · [Common tasks](#common-tasks) · [Troubleshooting](#troubleshooting)

## Layout of a running system

| 路徑 | 是什麼 |
|---|---|
| `core/` | 控制平面：system harness（`niffler.nim`：匯流排引導、supervisor、catalog、dispatch）+ session runner（`session.nim`：每個會話一個程序，會話迴圈） |
| `components/` | 內建元件原始碼：`bash`、`builder`、`store`、`plugins`、`skills`、`fetch`、`edit`、`grep`、`git`、`agent`、`fabric`、`expert`、`observe`、`logfile`、`hooks`、`dialog`、`systemprompt`、`cli`、`console`（Nim），`models`、`provider` 和 `llm`（Go），以及 `llm-openai` 替換示例 |
| `sdk/` | Nim SDK（`sdk/niffler`）+ `sdk/go`（Go）+ `sdk/ts`（TypeScript/Node.js，npm 包 `niffler-sdk`）；`sdk/envelope.nim` 中的信封才是核心產物 |
| `docs/` | 本手冊、wire 規範（`WIRE.md`）、設定設計（`research/SETTINGS.md`）、core 邊界理由（`ARCHITECTURE.md`）、fabric 使用者指南（`FABRIC_GUIDE.md`）、未完成工作（`research/PLAN.md`）以及 `research/`（設計歷史） |
| `manifest.yaml` | 引導清單：core 啟動哪些元件、重啟策略、可選的元件副本數 `replicas`；`--minimal` 把它過濾為 `store`、`bash` 和 `llm` |
| `var/` | **執行狀態，gitignored，可丟棄**——倉庫本身才是快照 |
| `var/bin/` | 建置出的二進位（系統 core + session runner + 元件）。由 `make build` 重新建置 |
| `var/store.db` | SQLite store 的資料檔案（預設引擎）——**單寫者**：同一時刻只有一個 `store` 程序可開啟它。較老的 harness/遷移前根目錄使用 `var/barrel-db` |
| `var/nats-url` | 最近一次啟動的匯流排地址；UI bridge 據此找到 core |
| `var/nats-monitor-url` | core 自行啟動匯流排時的 HTTP 監控端點；複用/遠端匯流排沒有該檔案 |
| `var/logs/`、`var/captures/` | 輪轉的結構化日誌和顯式 observe 探測匯出（見 [Observation and logs](#observation-and-logs)） |
| `var/nats-pid` | core 啟動的匯流排程序 pid（僅用於崩潰清理——存活的 core 退出時會自行停止匯流排） |
| `var/build/` | agent 建置元件的原始檔（builder 的暫存目錄） |
| `nimcache/` | 建置產物；`make clean` 會將它們（連同 `var/`）刪除 |

### Shipped components

| 元件 | 語言 | Manifest | 做什麼 |
|---|---|---|---|
| `store` | Nim/Go | required | 匯流排上的文件儲存（`put/get/list/del`，基於 rev 的併發控制）。各引擎以同一名稱註冊並提供相同工具：`store-sqlite`（Go，SQLite + goose 遷移，`var/store.db`）是**預設**；`barrel`（`var/bin/store`）和 `tidb` 仍可透過 `NIF_STORE_BACKEND` 選用——見 [Store engines](#store-engines) |
| `bash` | Nim | required | 經典工具：帶超時和輸出上限的 shell 命令。命令作為自身程序組的組長執行，因此超時或回合被取消會殺掉整棵程序樹（退出碼 124 / 130）——不會留下孤兒程序。結果攜帶 `text`（以 `(exit N)` 狀態行開頭——非零即失敗；124 = 超時，130 = 已取消——其後是合併的 stdout/stderr；LLM 記錄看到的就是它）以及機器欄位 `exit_code`、`cancelled`，輸出過大時還有 `spill {path, bytes, lines}`（溢位到臨時檔案，可用 `read` 分頁讀取）。`run_in_background: true` 把長跑命令（伺服器、監視器）交給 `processes` 元件而不是阻塞——見 [Background processes](#background-processes-processes) |
| `repomap` | Nim | optional | 排序後的工作區地圖（docs/research/REPOMAP.md）：約 1KB 內給出承重檔案及其關鍵定義，由 tree-sitter + 原生 Nim tags 圖與個性化 PageRank 建置（aider repomap 的移植）。`repo_map {workspace?, focus?, mentionedIdents?, budget?}` 是 onDemand 且為讀效應——模型主動詢問，不注入任何東西。工作區開啟時的自動追加（在 `ev.workspace.opened` 時追加一條 append-only 條目；元件釋出，runner 追加）**預設關閉**：設定 `NIF_REPOMAP_AUTOAPPEND=1` 選擇開啟。預設關閉是因為 A/B 沒有過線（full30：約多 40% token、準確率無提升；Multi10 high 開啟後 8/10 vs 9/10，儘管 low 復跑結論反轉、最初的高檔測試部分測的是樁地圖——見 `bench/reports/repomap-ab-*.md`），而且 onDemand 工具不會自己啟用。選擇開啟後，追加還有**門控**（`docs/research/REPOMAP-GATES.md`）：低於普查下限的工作區從不建置，樁地圖（位元組/符號/檔案閾值）從不注入——被扣留的地圖記錄為 `repo map withheld`。關閉追加時，它只是一個模型想要定位時可以發現的可選元件。快取：`var/repomap-tags/`（按 mtime 鍵控）。可選元件——缺失就沒有地圖，其他一切不變 |
| `processes` | Nim | optional | 帶歸屬者的長跑命令：`process_start`（脫離父程序、獨立程序組，立即返回 id）、`process_poll`（增量排空輸出）、`process_kill`（停止整個程序組）、`process_list`——見 [Background processes](#background-processes-processes) |
| `builder` | Nim | required | 編譯 agent 編寫的 Nim/Go/TypeScript 原始碼，並透過 `build_package` 建置外掛專案；外掛保留自己的依賴檔與鎖檔，builder 在隔離工作區執行受限 argv 配方並發布宣告的 artifact |
| `llm` | Go | required | 流式 chat 介面卡（隱藏的 `chat` 工具；`ev.llm.token` 增量；取消）——協議：OpenAI 相容 Chat Completions、OpenAI Codex（ChatGPT OAuth）Responses 和 Anthropic Messages；`components/llm-openai` 中的 `llm-openai` 是最小非流式示例，可透過 `manifest.yaml` 換上 |
| `models` | Go | optional | models.dev 提供商/模型目錄、原子快取、嚴格解析，以及外掛修正/發現層（見 [Model catalog](#model-catalog-models)） |
| `provider` | Go | optional | store 持久化的 LLM 提供商登錄檔：`provider_add`/`list`/`switch`/`active`/`remove`/`export`/`import`，訂閱 OAuth 登入（`provider_oauth_start`/`complete`/`cancel`），`ev.provider.switch` 通知 |
| `plugins` | Nim | optional | 生態門戶：topic 搜尋 + 包的安裝/更新/移除 |
| `skills` | Nim | optional | Agent Skills（SKILL.md）：發現、載入、資源訪問、基於 git 的安裝/移除 |
| `fetch` | Nim | optional | 網頁內容獲取：http/https、HTML→文字提取、大小上限與檔案溢位 |
| `edit` | Nim | optional | 檔案工具：`read`（規範的 `reads` 陣列——一次呼叫最多 12 個檔案/區間，可分頁，單檔案 `path` 語法糖；對超過 1000 行且其型別有語言伺服器的檔案做整體讀取時，改為返回 lsp 符號大綱——可用 offset/limit 取視窗，或 `offset: 1` 強制整體讀取，`NIF_READ_OUTLINE_LINES` 調整/禁用）、`edit`（唯一 `old_string`、帶保護的級聯回退、`replace_all`）、`write`（原子整檔案寫）、`undo_last_edit`（變更需審批）；錨定塊移動在 [niffler-hashline](https://github.com/gokr/niffler-hashline) 外掛中 |
| `lsp` | Nim | optional | 語言伺服器接縫：一個 `lsp` 工具——`diagnostics`（不用跑測試就能拿到編譯/lint 錯誤）、`documentSymbol`（檔案大綱：每個符號及其種類、名稱和從 1 開始的位置）、`workspaceSymbol`（基於伺服器索引的全倉符號搜尋——模糊 `query`，跨檔案結果）、`goToDefinition`、`findReferences`、`goToImplementation`、`hover`——面向任何已設定的 stdio 語言伺服器（預設為 gopls、nimtortoise、typescript-language-server、pyright、rust-analyzer、clangd、bash-language-server、jdtls、intelephense、solargraph、csharp-ls）。登錄檔是資料（`$XDG_CONFIG_HOME/niffler-lsp/servers.json`）：新增語言是一條設定或 agent 自己能執行的 `lsp_registry add`——絕不寫程式碼（AGENTS.md：語言無關的 core）。On-demand 工具 |
| `git` | Nim | optional | 只讀倉庫檢查：固定 argv 的 `git_status`/`git_diff`/`git_log`/`git_show`/`git_blame`（無需審批；變更仍走 bash），外加 `review_receipt`——`var/review-receipts/` 下用於推送前評審交接的本機 diff 指紋寫入/校驗對（從不呼叫模型；diff 自收據後有變化即校驗失敗）。On-demand 工具——worker 透過 `discover` + `invoke` 觸達它們，保持直接工具集精簡 |
| `agent` | Nim | optional | 子代理會話：`agent_run`/`agent_spawn`（新建或繼續的子代理、後臺作業、持久化結算通知——見 [Fabric and subagents](#fabric-and-subagents)） |
| `expert` | Nim | optional | 顧問同伴：併發跟隨一個或多個會話、由 LLM 評判、回合繫結的 steer（見 [Expert advisory peer](#expert-advisory-peer-expert)） |
| `fabric` | Nim | optional | 可程式設計工具呼叫：模型編寫一個編排工具的 Nim 程式；只有它的 `finish()` 值進入會話（見 [Fabric and subagents](#fabric-and-subagents)） |
| `grep` | Nim | optional（4 個副本） | ripgrep 驅動的搜尋：`grep`（內容，path:line:match，直接、輸出有上限）和 `files`（排序列表，按需）；感知 .gitignore，無需 shell 引號；無狀態的佇列組副本可併發處理同元件搜尋 |
| `systemprompt` | Nim | optional | 會話憲法：session runner 每個會話從 `svc.systemprompt.call` 獲取一次系統提示詞（見 [System prompt (`systemprompt`)](#system-prompt-systemprompt)） |
| `compaction` | Nim | optional | 預設可替換 `compaction_propose` 實現：校驗 runner 擁有的分頁快照、選擇允許的切點並返回結構化檢查點候選；只有 runner 才驗證並提交投影 |
| `recall` | Nim | optional | 隱藏的 `context_recall` 解析器：解析規範訊息、完整溢位文件和當前持久化檢查點 |
| `cli` | Nim | — | 面向指令碼/CI 的按需匯流排驅動器（`catalog`/`wait`/`call`/`install`） |
| `console` | Nim | — | 按需匯流排檢視器（在 stdout 渲染每個信封） |
| `observe` | Nim | optional | 有界實時匯流排環形緩衝、listen/trace 探測、安全捕獲匯出和 NATS 監控（見 [Observation and logs](#observation-and-logs)） |
| `logfile` | Nim | optional | 輪轉 JSONL 落盤和有界的持久化日誌搜尋（見 [Observation and logs](#observation-and-logs)） |
| `hooks` | Nim | off by default | 選定的匯流排事件觸發時執行操作者的 shell 命令（僅觀察；stdin 收 JSON，環境變數設定；見 [Hooks](#hooks)） |
| `mcp` | Go | optional | 外部 MCP 伺服器（Model Context Protocol）：store 持久化登錄檔（`mcp_servers`/`mcp_add`/`mcp_edit`/`mcp_remove`/`mcp_refresh`），每個伺服器一個受監督 bridge；其工具成為普通目錄工具，可經 `discover` + `invoke` 觸達（見 [External MCP servers](#external-mcp-servers-mcp)） |
| `dialog` | bash | — | 完全用 bash 寫的演示元件——nats CLI + jq，無 SDK、無編譯步驟：`dialog_show` 彈出桌面對話方塊（zenity、notify-send 或日誌回退），`dialog_ask` 向使用者提出 yes/no 問題並返回答案。隨 `var/bin/dialog` 一併建置（`make build`）但**不自動啟動**；用 `spawn {name: "dialog", binary: ".../var/bin/dialog"}`（core 的工具）啟動它。前置條件：natscli、jq、zenity——`make setup` 三者都會裝 |

### Minimal boot profile (`--minimal`)

正常 manifest 是完整、可自我擴充套件的 harness。要得到最小但可用的常駐執行時，啟動：

```bash
./var/bin/niffler --minimal
```

它把 manifest 的引導集合過濾為恰好三個服務元件：

- `store` —— 會話/訊息持久化和元件記錄
- `bash` —— 一個通用機器工具
- `llm` —— OpenAI 相容的模型訪問和流式輸出

core 和 NATS 照常執行，首個會話會啟動它正常的臨時
`var/bin/session <id>` runner。`builder`、`plugins`、`skills`、`fetch`、
`models`、`provider`、專用檔案工具以及觀察/日誌元件都不會啟動。透過
`core.spawn` 建立的持久化元件被有意不恢復，但其實 store 記錄不會刪除；之後
正常啟動會把它們恢復。minimal 只是引導設定，不是策略邊界——呼叫方在執行期間
仍可使用 `core.spawn`。

由於既沒有 `provider` 也沒有 `models`，正常會話回合直接從
`NIF_OPENAI_API_KEY`、`NIF_OPENAI_BASE_URL` 和 `NIF_OPENAI_MODEL` 解析後端。
當精確上下文視窗很重要時設定 `NIF_OPENAI_CONTEXT`；否則 `llm` 使用它內建的
小型模型表，最後回退到 128K。

```bash
NIF_OPENAI_API_KEY=sk-... \
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1 \
NIF_OPENAI_MODEL=deepseek-chat \
NIF_OPENAI_CONTEXT=1000000 \
./var/bin/niffler --minimal
```

桌面 UI 的自動啟動使用正常設定。要在 minimal 設定下使用 UI，先啟動上面的命令，
再啟動 `niffler-ui`；它會附著到已執行的 core。`--minimal --recover` 也有效：
recover 會先重建並清空 spawned 元件記錄，然後引導三元件設定。這只是執行時的
選擇；`make build` 仍會建置完整的出廠元件集。

### Session runners

一個會話 = 一個程序（`var/bin/session <sessionId>`），由 system harness 按需
啟動。客戶端始終呼叫 `svc.core.call`（工具 `session`）；system 為每個會話 id
確保一個 runner，並把回合轉發到 `svc.session.<sessionId>.call`。runner 是受監督
的子程序（重啟策略 `never`）；它以元件名 `session-<id>`（零工具）註冊，啟動時
從 `catalog {op: snapshot}` 播種自己的目錄，併發出與經典 core 內迴圈相同的
`ev.session.<id>.*` 事件。會話是臨時的：歷史存在 store 中，因此新的 runner 會在下次
呼叫時恢復會話。殺掉 runner 隻影響該會話——程序就是隔離單元。兩個方向上回合
都不會巢狀。

stdin/stdout tty（`make run`）是**管理 shell**，不是會話 UI：它只檢查 harness
自身——`help`、`status`、`catalog`、`tools`、`sessions`、`exit`——帶方向鍵歷史
和 Tab 補全（見 `core/tty.nim`）。LLM 對話在 `niffler-tui` 終端客戶端和 Web UI
中；指令碼化透過 `cli` 元件。

### Store engines

store 的**匯流排契約才是產物**：`put/get/list/del`、`expectRev` 樂觀併發、
按 id 排序的列表（docs/WIRE.md）。多個引擎實現它並以元件 `store` 註冊相同的
工具——消費者永遠不知道當前是哪個引擎。選擇是引導期的決定：
`NIF_STORE_BACKEND=sqlite|barrel|tidb`（預設 `sqlite`）；core 據此解析 manifest
條目的二進位，遇到未知值會拒絕啟動。

- **sqlite**（預設，`var/bin/store-sqlite`，Go）：同一文件契約落在 SQLite 上。
  文件以 JSON TEXT 原樣儲存；`put` 是一條原子語句（文件與 rev 一起移動——
  KV 引擎的兩鍵崩潰視窗消失了）；schema 由內嵌 goose 遷移管理；純 Go 驅動
  （`modernc.org/sqlite`，無 cgo）。資料檔案 `var/store.db`（WAL），可用任意
  SQLite 工具內省（`sqlite3 var/store.db 'select kind, count(*) from docs group
  by kind'`），也可只讀掛載到 DuckDB 做離線分析。自上下文壓縮落地後成為預設：
  上下文投影需要原子寫和可範圍讀取的列表（docs/research/COMPACTION.md §2）。
- **barrel**（`var/bin/store`）：嵌入的 BitBarrel KV（Bitcask 風格），位於
  `var/barrel-db`——按設計無 schema、零依賴、久經考驗。仍完全支援
  （`NIF_STORE_BACKEND=barrel`）；它的 `put` 是兩個鍵的兩步序列（先文件、後
  rev），因此兩者之間崩潰可能更新內容而沒有更新修訂號。
- **tidb**（`var/bin/store-tidb`，Go）：同一 schema 走 MySQL 協議
  （go-sql-driver）——網路共享 store，任意多個 harness 可以共用。
  `NIF_STORE_TIDB_DSN` 指向叢集（`root@tcp(host:4000)/niffler`；單節點 docker：
  `docker run -p 4000:4000 pingcap/tidb`）。`value` 保持 MEDIUMTEXT，而不用原生
  JSON 型別——二進位 JSON 會規範化鍵順序和數字精度，破壞逐字文件契約；索引
  查詢以後以 TEXT 上的生成列形式到來（一個 goose 遷移）。`kind`/`id` 是
  utf8mb4_bin：位元組精確相等、位元組序列表排序和大小寫敏感的 LIKE 字首（與其他
  引擎的契約一致）。沒有 flock——叢集按設計就是共享狀態；行鎖
  （`SELECT … FOR UPDATE`、悲觀事務）仲裁寫者，rev 計數器仍是樂觀併發的檢查。
  也能跑在普通 MySQL 8 上。

所有引擎都以相同方式強制單寫者：一個程序擁有該檔案（flock；崩潰時由核心釋放），
其他人都透過信封通訊。

`list` 是**一頁**，不是完整檢視：上限 1000 條，並返回 `hasMore` 加一個
`nextAfter` id 遊標。把它作為 `after` 傳回即可繼續走完剩餘部分——store 保留完整
歷史，所以長會話一次呼叫裝不下。core 自己的全量讀取（resume、`session_info`、
`conversation_delete`）會自動分頁。

### Migrating between engines

**切換引擎不會搬移資料。** 升級後，歷史仍在 `var/barrel-db` 的 harness 會拒絕
啟動，而不是開啟一個空的 `var/store.db`、看起來像丟掉了所有會話：

```
core: this harness has conversation history in var/barrel-db, but the
      default store engine is now SQLite and no var/store.db exists yet.
core: migrate first (nothing is moved automatically):
core:     niffler-store-migrate --root /path/to/harness
core: scan for other un-migrated roots (benchmarks, clones):
core:     niffler-store-migrate --scan
core: or keep using the old engine: NIF_STORE_BACKEND=barrel
```

`niffler-store-migrate`（位於 `var/bin`）**離線**執行——它啟動私有的 NATS 伺服器
和 store 程序，因此無需引導任何 harness，也絕不修改源資料。它透過匯流排契約從源
引擎讀取每個文件（所以任意引擎對都可行，包括 TiDB），逐條重放到全新的目標，
最後按 kind 核驗計數：

```bash
niffler-store-migrate --root ~/git/myharness      # migrate that root
niffler-store-migrate --root ~/git/myharness --dry-run
niffler-store-migrate --scan ~/git                # list un-migrated roots
niffler-store-migrate --all ~/git                 # migrate all of them
```

`--scan` 會找到頂層目錄、同級 clone 和基準測試樹
（`var/bench/**/niffler-root`）。遷移拒絕覆蓋已存在的目標資料庫；回滾只需
`NIF_STORE_BACKEND=barrel`，因為 barrel 檔案未被改動。同一條匯出/重放路徑可以在
兩個方向上搬移資料（docs/research/STORE_V2.md "Moving data between engines"）。

## State and configuration

Niffler 沒有單一設定檔。狀態分佈在五處，按生命週期選擇：引導決策用環境變數，
身份/選擇在 store，每會話的選擇在會話頭，顯示偏好在瀏覽器，派生的一切在
`var/`（可再生——刪掉它，`make build` 加一次啟動即可重建整個世界）。

| 位置 | 內容 | 生命週期 |
|---|---|---|
| **環境變數 / `.env`** | 所有 `NIF_*` 變數（下表）：引導與匯流排、LLM 連線、各元件調優。`.env`（根目錄，gitignored）儲存金鑰和本機覆蓋；shell 環境優先；`.env.example` 是帶預設值的參考副本 | 程序生命週期——元件啟動時讀一次環境；改設定要 `core.kill` + `core.spawn` |
| **store**（kind 表見 [The store](#the-store)） | 會話頭、訊息、`provider` 登錄檔（含憑據）、凍結的每會話工具集、slash 表、外掛/元件安裝記錄、子代理作業/血緣記錄、fabric 程式、MCP 伺服器設定 | 持久——harness 的資料庫 |
| **會話頭**（`conversation` kind） | 每會話選擇：model、modelOverride、thinking、profile、title、預算/token 計量——透過 `session` 呼叫設定（UI 中的 `/model`、`/effort`），並在回合結果中回顯 | 每會話 |
| **Home / 專案檔案** | skills 樹（專案 `.agents|.claude|.opencode/skills` > 內建 `skills/` > home `~/.niffler/skills` + agent 標準目錄 > `~/.config/opencode/skills`）；LSP 登錄檔 `~/.config/niffler-lsp/servers.json`（`NIF_LSP_REGISTRY`） | 持久，使用者可編輯 |
| **`var/`**（gitignored） | `bin/` 建置產物、`logs/` 匯流排 JSONL 和子程序日誌、`models/` 目錄快取、`nats-url`/`nats-pid` 匯流排認領、`processes/` 輸出池、`repomap-tags/` 地圖快取、`fetch/`、`captures/`、`store.db`（store 引擎的檔案——有且只有一個所有者） | 執行時，可再生 |
| **瀏覽器 localStorage** | 僅顯示偏好：推理/工具卡片的詳細級別、語言（`niffler-think`、`niffler-tools`） | 每瀏覽器 |
| **倉庫檔案** | `manifest.yaml`（出廠元件登錄檔）、`skills/`（內建技能）、建置檔案（`config.nims`、`*.nimble`、`Makefile`） | 版本化 |

值得記住的優先順序規則：shell 環境勝過 `.env`；active `provider` 勝過
`NIF_OPENAI_*`；會話凍結的工具集快照勝過實時 catalog（這正是 resume 位元組穩定的
原因）；專案 skills 遮蔽 home skills，home skills 遮蔽內建 skills。repomap、lsp
和 skills 元件還會把 `config.nims`、`tsconfig.json`、`package.json` 和 `go.mod`
當作倉庫*標記*（從哪裡開始遍歷），而不是要解析的設定。

這張表的環境變數部分，正是將來遷入 store 作為全域性設定並配上 `/settings` 命令的
候選——設計（優先順序 `會話頭 > store 設定 > env > 程式碼預設`、第一階段遷移哪些鍵、
哪些永遠留在 env）見 `research/SETTINGS.md`。

## Environment variables

所有元件都會載入 `.env`（從 harness 根和 cwd，既有的 shell 環境總是優先——見
下文）並繼承 core 的環境。完整集合：

| 變數 | 含義 | 預設值 |
|---|---|---|
| `NIF_ROOT` | harness 根目錄（倉庫）。未設定時 core 從二進位位置推導，併為所有子程序設定。元件用它尋找 SDK、`var/`、`.env`。每個元件都以 **cwd = NIF_ROOT** 執行，因此 agent 的 `bash pwd` 永遠是 home——無論你從哪裡啟動 harness | `<binary location>/../..` |
| `NIF_NATS_URL` | 匯流排地址。在**環境變數**裡（測試、bench、指令碼）：只附著——core 精確使用該匯流排。寫在 **`.env`**（或眾所周知的 `nats://127.0.0.1:4222`）：本 clone 的 **home 匯流排**——空閒時認領，僅在應答的 core 服務本 root 時才附著（透過 catalog 的 `root` 欄位識別），遇到外來 core 或裸 nats-server 會大聲讓出（改用隔離的隨機匯流排；先回收已記錄的多餘 `var/nats-pid`），並寫入 `var/nats-url` | auto |
| `NIF_NATS_SPAWN` | `1` 強制在隨機埠啟動 core 獨佔的隔離匯流排——絕不用 4222，絕不附著（開發 clone 和測試）。顯式 `NIF_NATS_URL` 優先 | unset |
| `NIF_AUTOSTART` | SDK 的 `ensureHarness` 不得不啟動 core 時設定：該 core 在最後一個互動客戶端離開後退出（見 Starting and stopping） | unset |
| `NIF_AUTOSTART_IDLE_S` | 最後一個互動客戶端離開後，autostarted core 退出前的秒數 | `10` |
| `NIF_AUTOSTART_BOOT_S` | autostarted core 等待第一個互動客戶端的秒數，超時放棄 | `60` |
| `NIF_ENSURE_ATTACH` | `0` 讓 `ensureHarness` 跳過附著、總是啟動 core（測試） | `1` |
| `NIF_STORE_BACKEND` | 引導時選擇的 store 引擎：`sqlite`（預設 → `var/bin/store-sqlite`）、`barrel`（→ `var/bin/store`）、`tidb`（→ `var/bin/store-tidb`）；其他值拒絕啟動。所有引擎都以元件 `store` 註冊相同工具——見 [Store engines](#store-engines)。未遷移的 barrel 會讓 core 列印 `niffler-store-migrate` 指引並拒絕啟動；`barrel` 是逃生口 | `sqlite` |
| `NIF_STORE_TIDB_DSN` | `tidb` store 引擎的 TiDB/MySQL DSN，如 `root@tcp(127.0.0.1:4000)/niffler`（單節點 docker：`docker run -p 4000:4000 pingcap/tidb`）。該引擎必需——沒有本機預設值；元件缺它會拒絕啟動。除非 DSN 設定 `time_zone`，會話強制 UTC | unset |
| `NIF_GIT_MIRROR` | `plugins` 元件 clone 包時代替 `https://github.com` 的主機字首（如 `https://cnb.cool` 或 Gitee 映象）——API/搜尋端點仍在 GitHub | unset |
| `NIF_NPM_REGISTRY` | `builder` 安裝 ts 元件使用的 npm registry（如 `https://registry.npmmirror.com`） | npm 預設 |
| `NIF_OPENAI_API_KEY` | LLM 介面卡（`llm`）的 API key。任何會話回合都需要 | — |
| `NIF_OPENAI_BASE_URL` | OpenAI 相容端點 | `https://api.openai.com/v1` |
| `NIF_OPENAI_MODEL` | 模型名 | `deepseek-chat` |
| `NIF_OPENAI_PROVIDER` | 預設 LLM 連線的 models catalog provider id；未設定時常見端點會被推斷 | inferred |
| `NIF_OPENAI_CONTEXT` | llm 向 core 上下文守衛報告的顯式上下文視窗（token） | `models` 目錄，然後 `llm` 回退 |
| `NIF_AGENT_MODEL_WEAK` / `NIF_AGENT_MODEL_MEDIUM` / `NIF_AGENT_MODEL_STRONG` | 請求 `modelTier` 時新子代理使用的確切模型 id；子代理的檔位會被夾到父會話已設定的檔位 | unset |
| `NIF_AGENT_DEFAULT_TIER` | 父會話的確切模型不在已設定階梯中時使用的檔位上限（`weak`、`medium` 或 `strong`） | `strong` |
| `NIF_AGENT_WAKES` | 後臺子代理在會話空閒時結算後，該會話可連續執行的自主喚醒回合數（docs/WIRE.md "Autonomous wake"）；人類的下一條訊息重置預算，`0` 禁用喚醒（通知隨後等待下一回合的 pull 排空） | `3` |
| `NIF_AGENT_NOTICE_HOLD` | `0` 允許回合在最後一步收到結算通知時照常關閉（通知等待下一回合排空）；預設會把回合多保持一步，使它不能越過剛剛結束的子代理關閉（docs/WIRE.md "Busy-parent inbox"） | `1` |
| `NIF_LLM_PROVIDERS` | 命名提供商的 JSON 物件 `{nickname: {baseUrl, apiKey, model, context, catalog}}`，供 `chat` 工具的 `provider` 引數解析；provider 登錄檔（`provider` 元件）啟用時取代預設值 | `{}` |
| `NIF_MODELS_URL` | models.dev 相容目錄的基址或 JSON 端點 | `https://models.dev/api.json` |
| `NIF_MODELS_PATH` | 固定的本機基線目錄；便於離線/測試 | unset |
| `NIF_MODELS_OVERRIDE` | 在所有外掛來源之後應用的本機 JSON Merge Patch | unset |
| `NIF_MODELS_OFFLINE` | `1` 禁用遠端目錄重新整理 | unset |
| `NIF_MODELS_CACHE_DIR` | 目錄和來源補丁快取 | `$NIF_ROOT/var/models` |
| `NIF_MODELS_CACHE_TTL` | 重新抓取基線前的最小年齡 | `5m` |
| `NIF_MODELS_REFRESH_INTERVAL` | 後臺重新整理間隔；`0` 禁用 | `1h` |
| `NIF_FETCH_DIR` | 大體積 fetch 結果和臨時提取檔案 | `$NIF_ROOT/var/fetch` |
| `NIF_FETCH_ALLOW_PRIVATE` | `1` 允許 `fetch` 工具訪問 loopback/私有/鏈路本機地址；僅用於可信的本機開發服務 | unset（阻止） |
| `NIF_SKILLS_BUNDLED_DIR` | 顯式指定 `skills` 元件內建樹的位置，取代 `<repo>/skills` 及其 `$NIF_ROOT/skills` 回退。路徑不存在時發現機制提供編譯內建副本（目錄 `(baked)`） | `<repo>/skills` |
| `NIF_MCP_DIRECT_THRESHOLD` | 設定為 `expose: direct` 的 MCP 伺服器可直接釋出的快取工具數上限；更大的伺服器延遲到漸進式發現 | `10` |
| `NIF_MCP_BRIDGE_BIN` | mcp-bridge 二進位的顯式路徑 | `<root>/var/bin/mcp-bridge` |
| `NIF_PROCESSES_SPOOL_CAP` | 後臺程序輸出檔案在下次 poll 時被截斷為尾部的閾值 | `33554432` |
| `NIF_PROCESSES_POLL_CHUNK` | 單次 `process_poll` 每流返回的最大新增位元組數（保持在 spool 上限之下，突發總會被切開） | `65536` |
| `NIF_LSP_REGISTRY` | 語言伺服器使用者登錄檔（`servers.json`）的絕對路徑 | `$XDG_CONFIG_HOME/niffler-lsp/servers.json` |
| `NIF_LSP_WARM_MAX` | `ev.workspace.opened` 時每個工作區預啟動的重型（持有索引的）語言伺服器數 | `2` |
| `NIF_LSP_WARM_CHEAP` | 預啟動的輕量（不建索引）伺服器數，使用自己的預算——它們絕不擠掉重型名額 | `1` |
| `NIF_LSP_WARM_TOTAL` | 每個工作區預啟動程序的總上限 | `4` |
| `NIF_LSP_BIN` | `make install-lsp` 使用的安裝目錄（伺服器包裝指令碼和使用者本機 JDK）；也作為預設回退 bin 目錄參與解析 | `~/.local/bin` |
| `NIF_LSP_BIN_DIRS` | 在 PATH 之外額外搜尋伺服器二進位的目錄（展開 `~`） | — |
| `NIF_TRAFILATURA` | Trafilatura 可執行檔案路徑/名稱；`off` 禁用外部提取 | 在 `PATH` 上自動探測 `trafilatura` |
| `NIF_LOG_LEVEL` | SDK 結構化日誌釋出閾值（`debug`、`info`、`warn`、`error`） | `info` |
| `NIF_LLM_MAX_RETRIES` | 瞬時 LLM 失敗（429/5xx/過載/連線斷開）的額外嘗試次數，指數退避；每次重試都會廣播 `ev.session.<id>.retry`。認證/配額/壞請求錯誤總是快速失敗 | `2` |
| `NIF_LLM_MAX_STREAM_RETRIES` | 流式回應中途斷開時的額外嘗試——與一般情況分開計預算，因為斷開的流可能已經計費了輸出 | `2` |
| `NIF_LLM_MAX_CONNECT_RETRIES` | 連線/撥號失敗的額外嘗試次數 | `2` |
| `NIF_LLM_RETRY_AFTER_CAP_MS` | 伺服器 `retry-after` 提示的等待上限；更長的提示等待會被夾到這個值 | `3600000` |
| `NIF_LLM_TIMEOUT_MS` | 單次 `llm` `chat` 完成的時限；慢推理模型（例如經 llmgateway 的 GLM thinking=max）單次回應可能超過預設值 | `300000` |
| `NIF_CTX_RESERVE` | 上下文准入保留的輸出 token；預設為模型在目錄中解析出的輸出上限，未知時 `16384`；`0` 禁用保留 | 目錄輸出上限 |
| `NIF_COMPACTION_TOOL` | runner 選擇的 contract-v1 候選工具；為空則禁用摘要，但不影響 prune/trim/錯誤准入 | `compaction_propose` |
| `NIF_COMPACTION_TIMEOUT_MS` | 整個候選呼叫的截止時間（最小 5000 ms） | `90000` |
| `NIF_COMPACTION_MAX_LLM_CALLS` | 授予一次嘗試的輔助摘要呼叫預算；報告呼叫數超過授予值的候選會被判為無效 | `4` |
| `NIF_COMPACTION_MAX_SUMMARY_TOKENS` | 每次呼叫的檢查點輸出上限 | `4096` |
| `NIF_OBSERVE_RING` | observe 全域性環形緩衝保留的訊息數 | `2000` |
| `NIF_OBSERVE_RING_BYTES` | 全域性環形緩衝保留的近似 wire 位元組數 | `16777216` |
| `NIF_OBSERVE_ENTRY_BYTES` | 每條觀察訊息保留的最大位元組數 | `65536` |
| `NIF_OBSERVE_MAX_PROBES` | 同時保留的活躍 + 已停止探測數 | `32` |
| `NIF_OBSERVE_PROBE_BYTES` | 每個探測保留的位元組數 | `2097152` |
| `NIF_OBSERVE_CAPTURE_DIR` | `observe_dump` 的受限目錄 | `$NIF_ROOT/var/captures` |
| `NIF_OBSERVE_CAPTURE_BYTES` | 生成捕獲的總配額；最舊的檔案先被清理 | `67108864` |
| `NIF_OBSERVE_MONITOR_URL` | 外部/複用匯流排的顯式 nats-server HTTP 端點 | core 發現檔案 |
| `NIF_LOGFILE_DIR` | JSONL 輸出目錄 | `$NIF_ROOT/var/logs` |
| `NIF_LOGFILE_SUBJECTS` | 要持久化的逗號分隔 NATS 模式 | `ev.log.>` |
| `NIF_LOGFILE_MAX_BYTES` | 輪轉前每個 JSONL 檔案的活躍位元組數 | `10485760` |
| `NIF_LOGFILE_KEEP` | 保留的輪轉代數（`0` 禁用） | `5` |
| `NIF_LOGFILE_MAX_FILES` | 回退到 `bus.jsonl` 前的元件專用檔案數 | `64` |
| `NIF_LOGFILE_SCAN_BYTES` | 單次 `logfile_search` 檢查的最大位元組數 | `16777216` |
| `NIF_LOGFILE_DIRECTORY_ENTRIES` | 每次查詢列舉的候選 JSONL 路徑上限 | `10000` |
| `NIF_AUTO_APPROVE` | `1` → 繞過審批門（見下文）。僅用於無人值守自動化；絕不要在你在意的會話中設定 | unset |
| `NIF_AUTO_CONTINUE` | `1` → 回合觸及會話軟限制（`/limit`）時不再詢問、繼續執行。僅用於無人值守自動化 | unset |
| `NIF_MAX_TURN_ROUNDS` | 每回合的硬性 LLM 輪數上限；顯式的每會話 `maxRounds` 可以收窄它 | `1000` |
| `NIF_MAX_DIRECT_TOKENS` | `invoke {sticky: true}` 提升時對會話直接工具集的估算 token 上限；超出的提升會被推遲並在工具結果中報告 | `4000` |
| `NIF_PROFILE` | 新會話預設的命名工具設定，在 `session` 呼叫未攜帶 `profile` 引數時使用 | unset |
| `NIF_AGENT_MAX_DEPTH` | `agent_spawn` 委託可巢狀的深度上限（core 在分發時強制執行；agent 元件映象同一限制）。`0` 完全禁止委託；到達上限時 spawn 工具仍然可見 | `1` |
| `NIF_HOOKS_EVENTS` | hooks 元件監視的逗號分隔匯流排主題；主題中任意位置的 `>` 通配可用。啟動時讀取——改設定即 `core.kill` + `core.spawn` | `ev.session.*.turn` |
| `NIF_HOOKS_<SUBJECT>` | 某個被監視主題要執行的 shell 命令（點和 `>` 變成 `_`：`ev.session.*.turn` → `NIF_HOOKS_EV_SESSION_TURN`）；事件負載以 JSON 從 stdin 傳入 | unset |
| `NIF_HOOKS_TIMEOUT_MS` | 每個 hook 的超時；超過 60000 的值會被夾住 | `10000` |
| `NIF_MCP_REGISTRY_URL` | 外部 MCP 伺服器目錄的基址（氣隙/代理環境） | `registry.modelcontextprotocol.io` |
| `NIF_MCP_PROBE_TIMEOUT_MS` | `mcp_add` 中一次真實連線探測的超時（覆蓋 30s 預設值，並在呼叫自身的 `timeoutMs` 更高時覆蓋它） | `30000` |
| `NIF_READ_OUTLINE_LINES` | 超過該整讀行數閾值時，read 返回語言伺服器符號大綱而不是原始視窗；`0` 禁用大綱 | `1000` |
| `NIF_REPOMAP_AUTOAPPEND` | `1` 選擇開啟 repomap 元件的工作區開啟自動追加（每個新會話注入一次地圖）。預設關閉——各 A/B 的符號隨區間反轉，最初的高檔測試部分測的是樁地圖（`bench/reports/repomap-ab-*.md`）。`repo_map` onDemand 工具不受影響 | unset |
| `NIF_REPOMAP_MIN_CENSUS` | 追加的普查檔案下限：覆蓋原始檔更少的工作區從不建圖（docs/research/REPOMAP-GATES.md） | `50` |
| `NIF_REPOMAP_MIN_BYTES` | 追加內容門控：渲染出的地圖小於該位元組數即視為樁，予以扣留 | `800` |
| `NIF_REPOMAP_MIN_SYMBOLS` | 追加內容門控：渲染符號行數下限 | `25` |
| `NIF_REPOMAP_MIN_FILES` | 追加內容門控：承載符號的檔案數下限 | `5` |
| `NIF_RUNNER_IDLE_S` | session runner 無會話呼叫達到該時長後退場；下一次呼叫會啟動新的 runner（子代理按需重新確保） | `600` |
| `NIF_WRITE_MAX_BYTES` | `write` 工具整檔案負載的上限 | `900000` |
| `NIF_OAUTH_CALLBACK_HOST` | 本機 OAuth 回撥監聽的主機（埠固定為 1455/53692） | `127.0.0.1` |
| `NIF_LOG_MAX_MB` | core 在 `var/logs` 中保留子程序日誌的上限（MB） | `200` |
| `NIF_LOG_RETENTION_DAYS` | core 清理子程序日誌前的保留天數 | `7` |

每個 Niffler 變數都帶 `NIF_` 字首，因此 harness 絕不會與採用裸約定的工具
（`NATS_URL`、`OPENAI_API_KEY`）衝突。

### The `.env` file

`.env`（倉庫根目錄，gitignored）儲存本機金鑰/設定：

```bash
NIF_OPENAI_API_KEY=sk-...
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1
NIF_OPENAI_MODEL=deepseek-chat
```

載入規則（Nim SDK、Go SDK 和 UI bridge 完全一致）：既有 shell 環境**總是**勝過
`.env`；`.env` 依次從當前目錄和 `$NIF_ROOT` 載入。因此
`NIF_OPENAI_API_KEY=other ./var/bin/niffler` 覆蓋檔案值，想要檔案值就先
`unset NIF_OPENAI_API_KEY`。

倉庫根目錄的 `.env.example` 是完整參考：每個 `NIF_*` 變數、全部註釋掉、註釋值
即預設值，並說明它控制什麼——複製它，取消註釋即可。

## The bus in one screen

core 只說一種協議：NATS 上的 JSON 信封（細節見 [WIRE.md](WIRE.md)）。主題：

```
reg.publish            元件宣告自己：{name, version, pid, tools:[{name, schema}]}
reg.depart             優雅關閉宣告
svc.<component>.call   佇列組的工具呼叫請求/應答
svc.session.<id>.steer   回合中途訊息注入（fire-and-forget，{content}）
svc.session.<id>.advise  回合繫結的顧問請求/應答（expert 同伴）：
                         僅當命名 turnId 仍活躍時接受
ev.session.<id>.turn        {sessionId, turnId, phase: start|done, content?, error?}
ev.session.<id>.assistant   {sessionId, turnId?, content, provider?, model?, context?, usage?}
ev.session.<id>.status      {sessionId, turnId?, provider?, model?, context?, usedTokens?}
ev.session.<id>.token       {sessionId, turnId?, content, reasoning}  （實時 token 增量）
ev.session.<id>.toolcall    {sessionId, turnId?, callId?, phase: start|done, tool, args, result|error, durationMs?}
ev.session.<id>.advice      {sessionId, turnId?, source, content} 一條建議被折入
ev.session.<id>.notice      {sessionId, turnId?, kind?, content?, jobId?, child?,
                       status?} 執行時機器內容被折入（子代理結算、後臺程序退出、自主喚醒）
ev.session.<id>.done        {sessionId, turnId?, reply} | {sessionId, turnId?, error}
ev.session.<id>.context     {sessionId, turnId?, promptTokens, usedTokens, context, warning?|trimmed?}
ev.catalog.updated     任何註冊變化之後的直接（面向提示詞的）工具投影；
                       `catalog {op: snapshot}` 仍返回全部（含隱藏/on-demand schema）
ev.models.updated      重新整理後有效的 provider/model/source 計數
ev.provider.switch     provider 元件 → 匯流排：{nickname, previous, source, at}
ev.provider.changed    脫敏後的 provider 登錄檔失效事件
ev.llm.token           llm 介面卡 → core：{sessionId, content, reasoning} 增量
ev.sys.drain           core → 元件：停止接活、完成在途、退出
svc.approval.<name>.request 定向審批，發給正在驅動該回合的元件（由呼叫信封
                       的 `caller` 推導）；driver 先 ack {id, ack: true}，
                       再回答 {id, ok}
ev.approval.request    core → UI：{id, tool, args, caller?, fallback?} ——
                       人工門控，廣播（見下文 Approvals）
ev.approval.reply      UI → core：{id, ack?} | {id, ok}
ev.approval.resolved   core → UI：{id, ok} —— 門控裁決；關閉過期彈窗
cancel.<component>     取消側通道：回合取消落在在途分發上時由 runner 釋出；
                       bash 會殺掉命令的程序組（見 WIRE.md）
```

**流式。** `llm` 元件在生成時流式輸出 token：`ev.llm.token` 增量（content 和
reasoning）→ core 為活躍回合轉發為 `ev.session.<id>.token` → UI 追加到實時 assistant
氣泡。最終的 `ev.session.<id>.assistant` 事件總是攜帶完整內容，因此漏掉最後一幀也會
自愈。向 `llm.cancel.<sessionId>` 釋出訊息即可中止在途呼叫。

用 `nats sub '>'` 附著到匯流排，可以實時看到 harness 在思考。
或者更好：**console 元件**（`./var/bin/console`，不在 manifest 中——自己在第二個
終端啟動）訂閱一切並以可讀方式渲染 wire 流量：帶工具和引數的呼叫、結果、錯誤、
事件、審批——這就是你跟蹤實時安裝或卡住的工具呼叫的方式：

```bash
./var/bin/console    # 在另一個終端，harness 執行時
```

**cli 元件**（`./var/bin/cli`）從指令碼或流水線驅動同一條匯流排——非互動、對 CI
友好（成功退出 0）；它是指令碼入口，tty 管理 shell 是互動入口：

```bash
./var/bin/cli catalog                        # 元件及其工具
./var/bin/cli wait <component> [secs]        # 等待註冊
./var/bin/cli call <tool> '<json args>'      # 分發並列印結果
./var/bin/cli install <repo>[@<ref>]         # plugin_install + 驗證
```

`cli install` 會 clone、經 builder 建置、啟動每個元件，並等待每個服務名出現在
core 已接受的 catalog 中；互動式元件以建置完成為驗證。CLI 的目錄和工具查詢也
使用 core 的權威目錄，絕不使用原始註冊廣播。外掛倉庫的 CI 透過這一條命令執行
harness 來證明包可用。`file://` 倉庫 URL 可從本機 git 倉庫安裝（封閉測試、
映象）。基於名稱的驗證不能區分已接受元件與同名新啟動的程序。

## Approvals

schema 攜帶 `x-harness.approval: "always"` 的工具——當前是
`bash`、`build`（`builder` 元件）、core 的 `spawn`、`kill` 和
`remove`、`edit`、`write`、`undo_last_edit`、`fabric`、`agent_run`、
`agent_spawn`、`agent_ask`、`expert_follow`、`lsp_registry`、`mcp_add`、
`mcp_edit`、`mcp_remove`、`mcp_refresh`、`plugin_install`、`plugin_update`、
`plugin_remove`、`process_start`、`process_kill`、`skill_install`、
`skill_remove`、`provider_add`、`provider_update`、`provider_export`、
`provider_import`、`provider_use_environment`、`observe_send`、
`observe_request`、`observe_dump`、`observe_monitor`——執行前都需要人類的
許可（core 未註冊的 `conversation_delete` 介面同樣被門控）：

- **終端 harness**（`make run`）：出現 `[approval]` 提示，顯示工具名和引數；
  回答 `y`/`n`（只有 core 在終端上且沒有 UI 附著時才回退到 tty 提示）。
- **Web UI / 互動元件**：請求被路由到正在驅動該會話的那個元件——core 從呼叫
  信封自稱的 `caller` 推導，併發布到該元件的私有主題
  `svc.approval.<name>.request`。driver 先 ack（`{id, ack: true}`）確認正在
  詢問人類，顯示帶工具名和引數的彈窗，再回答 `{id, ok}`。
- **driver 不在/非互動**：若 driver 在短視窗內沒有 ack，請求會在
  `ev.approval.request` 上以 `fallback: true` 重新廣播，讓任何互動客戶端接管。
  直接（非會話）呼叫立即廣播。
- **兩者都沒有**（服務模式且沒有 UI）：呼叫**被拒絕**並給出明確錯誤——絕不
  靜默批准。
- 裁決到達時，core 釋出 `ev.approval.resolved {id, ok}`，讓每個客戶端關閉
  過期的彈窗。
- 無人應答的 UI 請求在 5 分鐘後超時並被拒絕。
- `NIF_AUTO_APPROVE=1` 繞過門控（無人值守自動化）。

### Conversation controls: `/approvals`, `/limit` and `/compact`

這三個控制屬於你（人類），永遠不屬於模型，而且只作用於一個會話。它們都透過
session 呼叫設定（Web UI 以 `/approvals`、`/limit` 和 `/compact` 暴露；任何
匯流排客戶端都可直接呼叫 `session`）。`approvals` 和 `limits` 設定會隨會話持久化，
因此恢復的會話會保留它們；`/compact` 是一個動作，不是設定。

- **`/approvals auto`** —— 該會話不再詢問：每個被門控的工具都會被授予，core
  會大聲記日誌（`core: approval auto-granted for <tool>`），因為靜默授予正是
  門控要防止的事。`/approvals ask`（或帶空引數的 `/approvals`）恢復正常門控。
  用於你決定完全信任的會話；更窄的信任仍可用每工具的“不再詢問”記錄。
- **`/limit rounds=N tokens=N seconds=N`** —— 回合的軟預算：LLM 輪數、累計
  token 和牆鍾秒數（在每次工具分發前檢查，不只是回合之間）。觸及之一時回合
  不會死：core 透過同一審批通道問你**“繼續嗎？”**（UI 顯示一個 Continue/Stop
  提示並指明是哪個限制），*是*會把該限制再放寬一步。*否*、無應答或沒有可達
  客戶端會以獨特的 `limit-<dimension>` 記錄結束回合，記錄中給出限制名和提升
  它的命令。`/limit clear` 清除全部三項。
- **`/compact`** —— 立即執行壓縮器，而不是等待自動壓力階梯：core 向已設定的
  壓縮元件請求允許切點上的檢查點，原子安裝它，併發出通常的
  `ev.session.<id>.context {reason: "reset:compact"}`。不執行 LLM 回合，也不追加
  使用者訊息。提交會把已測量的提示詞大小清零（這份投影還沒經提供商測量過），因此
  手動路徑還會發出一幀 status —— `usedTokens` 是本機估算值、`estimated: true`，
  並帶上視窗大小 —— 否則上下文儀表會一直顯示壓縮前的數字，直到下一回合重新測量；
  下一次請求的實測值會替換該估算。回覆報告 `compacted: true` 及前後 token 數，或
  `compacted: false` 及原因（未設定壓縮元件、壓縮器拒絕、或還無可壓縮內容）；
  拒絕絕不靜默降級為有損裁剪。

關鍵區別：這些限制是*你的*，所以可以協商；作業級預算
（`maxRounds`/`maxCalls`/`maxTokens`，`agent` 元件把它們凍結進子代理會話，
以及 `NIF_MAX_TURN_ROUNDS`）保持硬性——子代理不能靠話術給自己爭取更多預算。
`NIF_AUTO_CONTINUE=1` 對所有“繼續嗎”問題回答是（無人值守自動化，精神同
`NIF_AUTO_APPROVE=1`）。

回合執行期間到達的 session 呼叫會立即以 `busy` 拒絕
（“the conversation is mid-turn — retry when the turn finishes”）而不是等待：
回合絕不巢狀，而選擇等待的客戶端只會耗盡自己的超時（這就是長回合中
`/export` 看起來壞掉的原因）。

## Context window

core 監視會話使用了模型上下文視窗的多少，並採取*樸素*行動——不做摘要，
除模型上報的數字外不做 token 數學：

- 有效視窗在每個回合前由隱藏的 `llm_resolve {model?}` 解析，因此新選擇的模型
  的限制會在推理前到達上下文守衛。提供商的 `context` 和 `NIF_OPENAI_CONTEXT`
  覆蓋 models 目錄；若移除 `models`，小型內建表和保守的 128K 仍作為回退。
  結果包含無金鑰的 provider、model、catalog 和 context 來源資訊，供互動客戶端
  使用。見 [Model catalog](#model-catalog-models)。

- `session {sessionId, content?, model?, thinking?, title?, cwd?, profile?, discovery?, tools?, maxRounds?, maxCalls?, maxTokens?}`
  接受會話作用域的模型覆蓋。僅模型的呼叫會持久化並解析選擇，不做推理；帶空值
  出現則清除它。`profile` 命名儲存的工具設定，只在會話首次呼叫時解析進直接
  工具集（`NIF_PROFILE` 提供預設）；未知設定會讓呼叫失敗，恢復時會忽略該引數。
  `discovery {…}` 是顯式客戶端發現：它執行 `discover`，把 schema 記錄進持久化
  發現摘要並作為使用者訊息追加——不執行 LLM 回合，也不提升進直接工具集。
  core 把選擇存進會話頭，並在一個回合內的所有工具輪次中釘住已解析的模型。
- 每會話控制在首次呼叫時凍結並持久化在頭中：`tools`（子代理可分發的工具
  白名單）、`maxRounds`（每回合 LLM 輪數，1–`NIF_MAX_TURN_ROUNDS`，收窄硬
  上限）、`maxCalls`（每回合工具分發總數，1–500——每次分發嘗試都計數，成功
  或報錯），以及 `maxTokens`（每回合累計提供商上報 token，檢查於每個新輪次
  之前）。預算耗盡會讓回合以 budget-exhausted 錯誤結束——子代理驅動
  （`agent_run`/`agent_spawn`）把它作為失敗上報，而不是文字回復。
- `cwd` 釘住會話的**工作區**：`NIF_ROOT` 內的一個已存在目錄（相對路徑相對根
  解析），建立後不可變並持久化在頭中，使恢復的 runner 以完全相同的方式解析
  上下文和路徑。session runner 在分發時重寫路徑形態的工具引數：bash 以
  workspace 為 cwd 執行，edit/grep/read 在那裡解析相對路徑，git 工具以
  workspace 倉庫為作用域。systemprompt 元件在它與根不同時追加一條工作區提示。
  預設工作區就是 `NIF_ROOT` 本身。
- 每次 chat 呼叫後 core 記錄 prompt token，並用 `usage.total_tokens`
  （或 prompt + completion 回退）作為當前佔用的最佳值。provider、model、
  context、佔用和覆蓋也映象進會話頭，因此計量器無需載入整個記錄就能跨重啟
  存活。
- core 發出 `ev.session.<id>.status`，包含已解析的 provider/model/context 和當前
  `usedTokens`；客戶端直接渲染 `usedTokens / context`。當提供商上報快取輸入
  （`prompt_tokens_details.cached_tokens`）時，status 事件還攜帶
  `cacheHitTokens` 和 `cacheHitRatio`——凍結的提示詞字首意味著首次請求後大部分
  prompt token 應命中快取，所以低比率是值得注意的訊號（Web UI 每條訊息顯示
  `⚡ NN% cached`；TUI 狀態行顯示一個 `⚡ NN% cached` 小片）。
- 持久化訊息攜帶從不進入 LLM 的審計後設資料：每條訊息的 `createdAt`、到處都有
  的 `turnId`，以及 assistant、tool 和 error 記錄上的 `startedAt`/
  `durationMs`（LLM 呼叫本身失敗時會持久化一條 `error` 記錄，回放會跳過
  error 角色）。
- 准入執行在**每次**提供商請求之前，包括每個工具迴圈輪次。在還沒有上報用量
  之前，它用保守的 chars/4 估算給整個請求定價（訊息加上凍結的工具 schema）。
  保留的餘量是目錄中該模型宣告的輸出上限（`limit.output`，例如 DeepSeek 的
  384000）——提供商在准入時把請求的 `max_tokens` 計入其視窗，因此固定 16K
  的保留曾讓 736,803 token 的提示詞溢位 1,048,576 的提供商限制，而該提示詞
  本身是裝得下的。`NIF_CTX_RESERVE` 覆蓋推匯出的保留量。core 在到達有效線的
  75% 處警告一次（`ev.session.<id>.context {reason: "warn:threshold"}`）；線上上
  ——絕不晚於視窗的 90%——core 執行有界階梯：確定性工具結果 prune → 已設定
  壓縮器 → 最老完整回合 trim → 顯式 `context-recovery-required`。在 wire 上，
  `llm` 元件還會把請求的輸出夾到序列化提示詞（訊息加工具 schema）留出的餘量，
  因此任一層的估算漂移都無法把裝得下的提示詞推過提供商限制。它絕不有意傳送
  超窗請求。
- 觸發以**提供商的標度而非估算的標度**度量：每個成功回應都會重新測量校準
  偏移（上報的 `prompt_tokens` 減去對同一請求的本機估算），准入、警告和 trim
  都以估算 + 偏移給候選定價。原始 chars/4 代理可能比更密的 tokenizer 落後
  數萬 token——在一個 524K 視窗的會話中觀察到：所謂“90%”線實際在約 99% 才
  觸發，而 core 稱之為 86% 的請求被 400 拒絕。偏移是按模型作用域的（模型變化
  時清除，從下一個回應重新學習），恢復時用儲存用量播種，夾在 `[0, window]`，
  從不持久化——首次回應時重新測量。
- 內建的 `compaction_propose` 可替換：設定
  `NIF_COMPACTION_TOOL=<tool>` 選擇另一個 contract-v1 實現，或設為空以禁用
  摘要而保留確定性守衛。`NIF_COMPACTION_TIMEOUT_MS`、
  `NIF_COMPACTION_MAX_LLM_CALLS` 和 `NIF_COMPACTION_MAX_SUMMARY_TOKENS` 約束
  每次嘗試。runner 寫一份臨時的分頁 `compaction_input` 快照，校驗候選的
  generation/digest/cut/schema/size 和嚴格縮減，然後用樂觀 `expectRev` 提交
  一份 `context_projection` 文件。元件永不寫會話或投影記錄。
- 成功投影發出 `reason: "reset:compact"`；無模型 prune 發出 `reset:prune`；
  有損回退發出 `reset:trim`。`reset:tools` 保留給真正的 sticky 工具 schema
  提升。這些是唯一有意的提示詞字首重建，使快取未命中可歸因。
- 規範 `message` 文件不可變且只追加。prune 和壓縮只改變提供商投影；重啟的
  runner 校驗並過載持久化檢查點加保留的規範尾部，`context_recall` 解析規範/
  spill/當前檢查點引用。缺失或損壞的投影引用會顯式失敗，而不是靜默回放超限
  區間。
- 提供商上報的 `context-overflow` 只得到一次帶收據的恢復嘗試。同樣的
  prune → 壓縮器 → trim 順序重新測量；第二次溢位即終止，絕不無限重試。當
  容量未知且拒絕資訊中沒有可解析的視窗時，嘗試會盲減（無損 prune，再 trim 到
  最新請求），且只有候選確實縮小才會發出重試——不可縮減的候選以終止收場，
  而不是重發被拒絕的東西。介面卡把提供商的各種溢位措辭（包括某些主機返回的
  裸 `"Context limit exceeded"` 正文）規範化為穩定的 `context-overflow` 字首；
  runner 的分類器保留原始措辭作為回退。
- 有損 trim 是**持久的**：它把切到的規範 seqNo 記進會話頭（`trimThrough`），
  普通恢復會遵守它，因此重啟會重建 trim 後的投影，而不是重新膨脹完整 trim 前
  上下文、同時計量器恢復 trim 後的用量。被丟掉的回合仍留在規範歷史中供
  `context_recall` 使用。

## Self-extension and component lifecycle

agent 在對話中途、執行時新增能力：

1. 編寫元件原始碼（Nim：`import niffler/sdk`，型別化工具模式；Go：
   `import sdk "niffler.dev/sdk"`；TypeScript：`sdk/ts` 包——見系統提示詞）
2. `build {lang, name, source}`（`builder` 元件）把它編譯進 `var/bin/`
3. `spawn {name, binary, replicas?}`（core）啟動它；它自行註冊；新會話直接
   暴露它的工具（非 on-demand 時），已有會話透過 `discover` + `invoke` 觸達
   （見 [Progressive tool discovery](#progressive-tool-discovery)）
4. `kill {name}` 臨時停止每個副本（下次引導恢復）；`remove {name}` 停止整個組
   並刪除其持久化記錄

`replicas` 可選（1–16，預設 1）且會持久化。只用於無狀態或外部協調的元件：
所有副本共享同一 `svc.<name>.call` NATS 佇列組，因此併發請求每個程序分到一條。
絕不復制單寫者的 `store`，也不要複製像 `edit` 那樣變更/撤銷狀態是程序本機的
元件。預設 Nim SDK pump 保持序列。它的初始 NATS 連線在匯流排繫結期間最多重試
60 秒，然後進入 supervisor 的正常退避；關閉會中斷該等待。元件在副本不合適時
可以顯式擁有原生併發：長期/共享狀態的 Nim worker 首選 `std/threads` +
`std/locks`，隔離作業用 `taskpools`，永不使用 `asyncdispatch`。在 Go 中，普通
`Tool` handler 保持獨佔；經過審計的 handler 可以使用 `ToolConcurrent`
（預設最多 16 個在途，可經 `ConcurrentLimit` 設定）。併發 handler 必須同步
共享狀態，且不得同步呼叫同元件上序列化的工具。這個服務端選擇與面向 runner 的
`x-harness.parallel` 提示相互獨立。

**形態的持久化**：spawned 元件記錄在 store 中（kind `component`），正常引導時
恢復。`--minimal` 不碰這些記錄，但不恢復它們。`core` 本身、匯流排、catalog 和
supervisor 不可移除——這種不對稱正是架構（ARCHITECTURE.md）。

## Component ecosystem (`plugins`)

`plugins` 元件是生態門戶——社群元件包就是根目錄帶 `niffler.json` manifest 的
普通 GitHub 倉庫（一個倉庫 = 一個包 = N 個元件）。v1 manifest 保留 `main` 原始碼
形式；v2 manifest 宣告 `project`、argv `steps` 和 `artifact`，依賴繼續由
`package.json`/鎖檔、`go.mod`/`go.sum` 或 Nimble 檔案完整定義。帶 GitHub topic
`niffler-component` 的倉庫無需任何登錄檔即可被發現：

| 工具 | 做什麼 |
|---|---|
| `plugin_search {query?}` | GitHub topic 搜尋；返回倉庫、描述、star 數 |
| `plugin_installed` | 本 harness 已安裝的包 |
| `plugin_install {repo, version?}` | clone 到 `var/plugins/<pkg>@<ref>/`，v1 經 builder 的 `build`、v2 經 `build_package` 建置每個元件，然後 `spawn` 每個服務元件（需審批） |
| `plugin_update {package}` | 更新到最新 release tag：移除、按新 ref 重灌；沒有 release 的包（跟蹤分支）原地拉取（現有 clone 的 `git pull --ff-only`），只在拉取移動了 HEAD 時重建 |
| `plugin_remove {package}` | `core.remove` 每個受監督元件，刪除 clone，丟棄記錄 |

- 安裝/更新/移除都帶 `x-harness.approval: "always"`——它們執行第三方程式碼，
  而且每一次單獨的 spawn/remove 還會再經 core 審批。除非信任釋出者，絕不要在
  `NIF_AUTO_APPROVE=1` 下執行它們。
- 預設 ref 是最新 release tag，否則預設分支。`version` 顯式固定 tag 或分支。
- 元件總是經 `builder` 從原始碼建置——與 agent 編寫元件走同一條路。執行 Niffler
  本身就提供工具鏈（Nim/Go 和 NATS SDK），因此不需要 NATS C 庫；每個平台用
  自己的工具鏈編譯。Go 條目可以宣告
  `"sources": ["component/helper.go", ...]`；這些必須是與 `main` 同目錄、同包的
  非符號連結 `.go` 檔案，builder 把它們作為一個包編譯。
- v2 外掛在自己的生態系統檔案中宣告依賴：TypeScript 使用
  `package.json`/`package-lock.json`，Go 使用 `go.mod`/`go.sum`，Nim 使用
  `.nimble`/鎖檔。配方在 project 目錄執行，也可以組合工具鏈（例如
  `npm ci` 後執行 `wails build`）；`${NIF_SDK_ROOT}`、`${NIF_SDK_GO}`、
  `${NIF_SDK_TS}`、`${NIF_PROJECT}` 和 `${NIF_OUTPUT}` 是唯一 builder 替換項。
  步驟是 argv 陣列而不是 shell 字串，builder 會拒絕路徑穿越、
  符號連結輸入、超大專案、錯誤 runner 和未宣告的 artifact。
- manifest 條目標記 `"interactive": true` 的元件會建置進 `var/bin`，但不會傳給
  `core.spawn`。它是終端客戶端（例如 TUI），由使用者手動啟動，因此不受監督、
  不會在引導時重啟。移除或更新其包之前先手動停止任何執行中的客戶端。
- 安裝記錄存在 store（kind `plugin`，id = 包名）；它們會像所有元件記錄一樣被
  `--recover` 清空——重新安裝時新引導會按記錄的 repo/ref 重新 clone。
- GitHub API 以未認證方式使用（每 IP 60 請求/小時）。
- 釋出：新增 `niffler-component` topic 並打 release tag（`v1.0.0`）。
  [`gokr/niffler-weather`](https://github.com/gokr/niffler-weather) 示例的釋出
  工作流自我驗證：它引導一個 harness 並透過 `plugin_install` 安裝該包，因此每個
  tag 都證明包能幹淨地安裝。
- 包可以透過註冊一個帶 `x-models-source: {version: 1, priority: ...}` 的隱藏
  工具來擴充套件或修正模型後設資料。`models` 元件會自動發現它，並在該元件存在期間
  應用其 JSON Merge Patch。見 [Source plugins](#source-plugins)。

## Skills

`skills` 元件為 agent 提供可複用的工作流指導——開放的
[Agent Skills](https://agentskills.io) 格式（帶 YAML frontmatter 的 SKILL.md
檔案），與 Claude Code、opencode 和 Cursor 所用約定相同。它只透過匯流排讀取/載入：
沒有任何工具把技能加進提示詞，載入是經工具結果的漸進式披露。

全部八個工具都是 **on-demand**（`x-harness.onDemand`）：都不在會話凍結的直接
工具集中，因此首次觸達要走一次 `discover` + `invoke`（見 [Progressive tool
discovery](#progressive-tool-discovery)）。載入技能會把其文字追加到歷史——
這裡沒有任何東西改寫凍結的提示詞字首，所以 `skill_load` 的代價是一次快取讀取，
而不是快取未命中。

發現覆蓋倉庫內建技能加上標準 agent 目錄（每個技能名首個匹配勝出——專案勝過
內建、勝過 home、勝過 config）：

| 來源 | 目錄 |
|---|---|
| project | `$NIF_ROOT/.agents/skills`、`$NIF_ROOT/.claude/skills`、`$NIF_ROOT/.opencode/skills` |
| bundled | `<repo>/skills`（隨 Niffler 出廠；`$NIF_ROOT/skills` 為回退，`NIF_SKILLS_BUNDLED_DIR` 覆蓋這兩者）——永不可移除 |
| home | `~/.agents/skills`、`~/.claude/skills`、`~/.opencode/skills`、`~/.niffler/skills` |
| config | `~/.config/opencode/skills`（`npx skills add -g -a opencode` 安裝的位置） |

同一來源內目錄按列出順序嘗試，因此 `~/.agents/skills/nats` 會勝過
`~/.claude/skills/nats`。發現是**每次呼叫都重新遍歷**——沒有快取登錄檔、沒有
重新整理操作——因此 `skill_install` 或另一個 agent 的 `npx skills add` 立即可見。
遍歷**不進入符號連結目錄**：只透過符號連結到達掃描目錄的技能不會被發現，
`skill_audit` 也不會列出它（因此像 `~/.claude/skills → ~/.agents/skills` 這樣
的符號連結農場是不可見的——當連結目標本身也會被掃描時無害，否則靜默丟失）。

內建技能（`todo-markdown`——把 todo 狀態儲存在倉庫 TODO.md，而不是工具狀態；
`niffler-tools`——哪個工具適合哪項工作；`niffler-fabric`——構造 fabric 程式；
`niffler-harness`——操作執行中的 harness）讓 Niffler 開箱即用；把同名技能放進
專案或 home 目錄即可遮蔽。

當**沒有**可達的內建樹時——部署只帶 `var/bin` 而沒有倉庫 checkout，既沒有
`<repo>/skills` 也沒有 `$NIF_ROOT/skills`——發現會回退到**編譯進二進位**的
內建 SKILL.md 檔案。這些條目的 source 為 `bundled`、dir 為 `(baked)`；它們不帶
資源（`skill_resources` 為空——內建技能本來也不帶任何資源），且永不可移除。
磁碟按名稱總是優先，因此有 checkout 時不受回退影響。

| 工具 | 做什麼 |
|---|---|
| `skill_list {query?, source?}` | 可用技能（name、description、version、tags、source、dir）；按子串或來源過濾；編譯內建回退條目的 dir 為 `(baked)` |
| `skill_search {query, owner?}` | 線上搜尋 skills.sh 登錄檔（`npx skills find` 後端）：名稱、倉庫來源、安裝數；`source`+`name` 對可直接餵給 `skill_install` |
| `skill_load {name}` | 完整 SKILL.md 指令 + 資源列表進入會話（載入機制）；正文超過 200 000 位元組會截斷並帶 `truncated: true` |
| `skill_resources {name}` | 技能的 `references/`、`scripts/`、`assets/` 檔案 |
| `skill_resource {name, path}` | 按需讀取一個資源 |
| `skill_audit` | 磁碟上每個 SKILL.md 的只讀、未合併清單——外加僅由編譯內建回退提供的名稱（dir `(baked)`）：標出每個名稱的實際勝出者和每個被遮蔽/無效的副本（無效 = 不可讀的 SKILL.md、無法解析的 frontmatter、或沒有 `name`；發現結果在 `skill_list` 中合併，因此遮蔽只在這裡可見） |
| `skill_install {repo, skill?, global?}` | clone git 倉庫，把選定的 SKILL.md 樹複製到 `~/.niffler/skills`（預設）或 `$NIF_ROOT/.opencode/skills` |
| `skill_remove {name}` | 只從 Niffler 管理的目錄刪除技能 |

- `skill_search` 是對 `https://skills.sh/api/search` 的只讀 HTTP 呼叫
  （未認證）；不需要審批。安裝需要：search → `skill_install {repo, skill}` →
  審批對話方塊 → 完成。
- 用 `npx skills add <owner>/<repo>`（skills.sh 生態 CLI）安裝的技能落在上面的
  標準目錄並被直接發現，無需重灌；`skill_install` 的存在是為了讓 Niffler 不依賴
  Node，走純 git。它只複製 SKILL.md 樹——不執行任何程式碼——並接受
  `owner/name`、github.com URL 和 `file://` 本機倉庫（封閉測試）。
- 包含多個技能的倉庫（例如 `vercel-labs/agent-skills`）需要 `skill` 引數；
  缺少時 `skill_install` 會列出候選。
- `skill_remove` 拒絕 `~/.niffler/skills` 和 `$NIF_ROOT/.opencode/skills` 之外的
  任何東西——其他 agent 裝進共享目錄的技能要用它們自己的工具解除安裝。
- 安裝和移除帶 `x-harness.approval: "always"`（它們寫到 `var/` 之外）。

## Provider registry (`provider`)

已設定的 LLM 後端是 store 記錄，不是設定檔。`provider` 元件把它們儲存在
kind `provider` 下（id = 暱稱，外加 `active` 標記文件），並向 agent 和 `llm`
暴露它們：

| 工具 | 做什麼 |
|---|---|
| `provider_add {nickname, apiKey, protocol?, baseUrl?, model?, catalog?, context?, plugin?, active?}` | 新增 API-key 提供商（`protocol`：`openai-chat` 預設或 `anthropic`）；第一個會自動成為 active；回應脫敏 |
| `provider_update {nickname, apiKey?, protocol?, baseUrl?, model?, catalog?, context?, plugin?}` | 隱藏的客戶端 API，用於部分更新；省略 API key 則保留原值 |
| `provider_oauth_start {protocol, method?, nickname?, model?, active?}` | 隱藏，開始訂閱登入：`protocol` 為 `openai-codex`（ChatGPT Plus/Pro）或 `anthropic`（Claude Pro/Max）；`method` 為 `browser`（本機回撥）或 `device`（無頭，僅 OpenAI）。返回 `{flowId, url, userCode?, callbackAvailable, expiresAt}` |
| `provider_oauth_complete {flowId, code?}` | 隱藏，輪詢/完成登入；在回撥（或貼上的 `code`）到達前返回 `{pending, retryAfterMs?}`，然後儲存提供商並脫敏上報 |
| `provider_oauth_cancel {flowId}` | 隱藏，取消待處理登入並關閉其回撥監聽 |
| `provider_list` | 所有已存提供商（脫敏——無金鑰/token）、哪個 active；每條帶 `authType`（`api_key`/`oauth`）、`protocol` 和 `expiresAt` |
| `provider_status` | 隱藏，脫敏的有效提供商，含環境回退和 `hasKey` |
| `provider_active` | 隱藏的內部讀取，返回有效提供商的完整設定（含憑據） |
| `provider_get {nickname}` | 隱藏的內部完整設定讀取，用於在一個回合內釘住顯式儲存的提供商 |
| `provider_models {nickname?\|baseUrl?, apiKey?, refresh?}` | 提供商的 `/models` 端點當前提供的模型 id——按暱稱取已存提供商，或顯式端點+key（連線表單，憑據尚未儲存時）。按端點磁碟快取 5 分鐘（探測失敗時提供過期快取）；錯誤返回給呼叫方，便於客戶端回退到目錄 |
| `provider_switch {nickname}` | 讓另一個已存提供商成為 active；實時更新 LLM 後端 |
| `provider_use_environment` | 隱藏的客戶端 API，清除儲存標記並回到 `NIF_OPENAI_*` |
| `provider_remove {nickname}` | 刪除提供商；若它是 active，另一個接管或恢復環境回退 |
| `provider_export` / `provider_import` | JSON 備份/遷移往返，含憑據；import 合併、校驗記錄並可恢復 active 標記 |

### Wire protocols

每個提供商帶一個 `protocol`，`llm` 據此路由：

- `openai-chat` —— OpenAI 相容的 Chat Completions 端點（預設；DeepSeek、
  OpenRouter、本機 vLLM……）。
- `openai-codex` —— ChatGPT 的 Codex Responses 端點
  （`https://chatgpt.com/backend-api/codex/responses`），帶 ChatGPT OAuth 頭
  （`chatgpt-account-id`、`OpenAI-Beta: responses=experimental`）；訊息被翻譯成
  Responses API 輸入格式，SSE 事件流（text/reasoning 增量、函式呼叫）對映回
  共享結果形態。
- `anthropic` —— Anthropic Messages 端點；OAuth 登入傳送 Claude Code 身份頭
  和 beta，系統提示詞以 Claude Code 前言開頭，工具呼叫/結果被翻譯成
  `tool_use`/`tool_result` 塊（連續工具結果合併進一條 user 訊息）。

### Subscription OAuth (ChatGPT Plus/Pro, Claude Pro/Max)

`provider` 元件實現與 Pi 和 opencode 相同的 PKCE 登入流程（固定 localhost 回撥
埠、手動重定向/程式碼回退，以及面向無頭機器的 OpenAI 裝置碼流程）：

1. `provider_oauth_start` 返回授權 URL；互動客戶端在系統瀏覽器中開啟。OpenAI
   也可選擇 `device` 登入（在 `auth.openai.com/codex/device` 輸入短碼）。
2. `provider_oauth_complete` 輪詢直到授權完成，然後交換程式碼並儲存提供商——
   `authType: "oauth"`，含 access token、refresh token、過期時間和（ChatGPT 時）
   從 JWT 中提取的 account id。
3. 每次憑據讀取（`provider_active`、`provider_get`、狀態解析）都會在過期前
   5 分鐘內透明重新整理 token 並持久化輪轉後的憑據。`llm` 元件永遠看不到 refresh
   token。

環境旋鈕：`NIF_OAUTH_CALLBACK_HOST`（預設 `127.0.0.1`）移動本機回撥監聽器
（埠像參考客戶端一樣固定為 1455/53692）。匯出包含存活的 refresh token——把
`provider_export` 的輸出當作金鑰。

- `provider_add`/`provider_update`/`provider_import`/`provider_export` 帶
  `x-harness.approval: "always"`——它們搬移憑據或修改連線設定。互動客戶端在
  使用者顯式操作後直接呼叫隱藏的 update/status 工具，且絕不可渲染/記錄憑據負載。
- `llm` 在每次 chat 呼叫時從 active 的已存提供商解析預設後端，因此
  `provider_switch` 立即生效。當 `provider` 元件缺席或沒有 active 時，`llm`
  像以前一樣回退到 `NIF_OPENAI_*` 和 `NIF_LLM_PROVIDERS` 表。`chat` 或
  `llm_resolve` 的顯式 `provider` 引數先解析已存暱稱，再解析
  `NIF_LLM_PROVIDERS`，因此會話可以在其回合內釘住一個非 active 的已存提供商
  而不切換全域性預設。
- 已存提供商的顯式 `context`（token）勝過 models 目錄；其 `catalog` id 命名
  用於上下文查詢的 models.dev 提供商，`plugin` 可以命名一個掛鉤提供商專屬工具
  的元件。每次切換時元件釋出
  `ev.provider.switch {nickname, previous, source, at}`，讓這類外掛啟用或隱藏
  自己的工具。每次登錄檔變更還會發布無金鑰的
  `ev.provider.changed {op, nickname, active, source, at}`，供互動客戶端使其
  provider/model 檢視失效。
- `active` 標記是一個普通 store 文件——需要手動手術時用 `store` 工具刪除或
  覆蓋它。

## Hooks

`hooks` 元件（預設關閉）在選定的匯流排事件觸發時執行操作者的 shell 命令——它是
CodeWhale hooks 中僅觀察的子集（docs/research/CODEWHALE.md）。一個 hook 就是
一個普通程序：解碼後的事件負載以 pretty JSON 從命令的 stdin 傳入，命令本身絕不
與事件資料做插值，失敗和超時（預設 10s，最大 60s）會記錄日誌且絕不致命。這裡
有意沒有 steering/veto：審批決策在 core 的分發門裡。

設定基於環境變數，啟動時讀取（改設定 = `core.kill` + `core.spawn`）：

```bash
NIF_HOOKS_EVENTS="ev.session.*.turn,ev.log.error"   # 要監視的主題
NIF_HOOKS_EV_SESSION_TURN='notify-send Niffler "turn finished"'
NIF_HOOKS_EV_LOG_ERROR='jq -r .payload.msg | mail -s Niffler you@example.com'
NIF_HOOKS_TIMEOUT_MS=10000
```

主題 → 環境變數名：點和 `>` 變成 `_` 並大寫
（`ev.session.*.turn` → `NIF_HOOKS_EV_SESSION_TURN`）。可工作的示例——桌面通知、
聲音提醒、郵件、webhook、錯誤尾部——在 `components/hooks/README.md` 中。

## Fetch

`fetch` 元件是網頁訪問工具（舊 niffler `fetch` 工具的移植）。一個工具：

| 工具 | 做什麼 |
|---|---|
| `fetch {url, method?, headers?, body?, timeout?, maxSize?, convertToText?}` | 對 http(s) URL 執行 GET/POST/PUT/DELETE/HEAD/OPTIONS/PATCH；HTML → 經 Trafilatura 或純 Nim 回退得到乾淨文字；跟隨重定向；執行各種上限 |

- `convertToText`（預設 true）從 HTML 提取可讀文字——JSON 負載總是原樣返回。
- 若 `PATH` 上有 `trafilatura`，fetch 把已下載的 HTML 交給它做更高質量的主內容
  提取（限制 30 秒）。缺失、失敗、超時或空提取回退到內建的 `htmlparser` 遍歷。
  設定 `NIF_TRAFILATURA` 為可執行檔案路徑/名稱以覆蓋探測，或用 `off` 禁用它。
- 回應受 `maxSize` 限制（預設 10 MiB，最大 50 MiB）；處理超過 200 KB 的內容會
  寫到 `$NIF_FETCH_DIR`（預設 `$NIF_ROOT/var/fetch`）下的檔案，工具結果指向它，
  因此 agent 用自己的檔案工具讀取大頁面而不是撐爆會話。
- 錯誤（非 2xx、超時、超大回應、非法 URL/方法）以 `ok: false` 返回，帶狀態和
  正文片段。
- 只讀網路訪問——不設審批門（和 `plugin_search` 一樣）。

## Language servers (`lsp`)

Status: **implemented**（Nim 元件；確定性的 fixture 測試；niffler-tui 客戶端
提供 `/lsp` 登錄檔選擇器）。

一個面向任何 stdio 語言伺服器的通用接縫。元件不認識任何語言：哪個伺服器處理
哪個副檔名是**資料**——登錄檔內建了合理的預設值。新增語言是設定條目，
絕不寫程式碼（AGENTS.md 不變數：語言無關的 core）。

### The tools

| 工具 | 做什麼 |
|---|---|
| `lsp {operation, path, line?, character?}` | 針對該檔案的語言伺服器執行一次查詢：`diagnostics`（不用跑測試就能拿到編譯/lint 錯誤）、`documentSymbol`（檔案大綱：每個符號及其種類、名稱和從 1 開始的位置——無需 line/character）、`workspaceSymbol`（全倉符號搜尋——模糊 `query` 字串；伺服器在預熱後建索引，因此首次呼叫可能需要重試）、`goToDefinition`、`findReferences`、`goToImplementation`、`hover`——或 `warmup`：`path` 傳目錄（或 `workspaceRoot`），普查其語言並預啟動對應伺服器 |
| `lsp_servers {}` | 列出已設定伺服器（只讀、免審批），帶來源：`builtin` 預設或 `user` 登錄檔條目 |
| `lsp_registry {action: add\|remove, name, command, extensions?}` | 修改使用者登錄檔（寫操作，需審批）；`add` 也會覆蓋同名內建項 |

模型傳送從 1 開始的 line/character（UTF-16，匹配 LSP 的 code-unit 約定）；
`findReferences` 總是包含宣告；結果有上限（100 個位置 / 16 KB）並帶截斷後設資料；
結構化 `[E_LSP_*]` 錯誤（`E_LSP_UNAVAILABLE`、`E_LSP_UNSUPPORTED`、
`E_LSP_TIMEOUT`、`E_LSP_SCOPE`、`E_NOT_FOUND`）讓呼叫方按 code 路由而不是解析
散文——超時和協議錯誤會附上伺服器最後一行 stderr，指明實際失敗原因（缺二進位、
崩潰、索引中）。

三個工具都是 **on-demand**（`discover`/`invoke`——見 [Progressive tool
discovery](#progressive-tool-discovery)），保持凍結工具集精簡；工具描述就是
模型的 when-to-use 指南。`lsp` 工具只讀且免審批；`lsp_registry` 寫登錄檔檔案，
需審批。

### Model usage

典型回合：

- 編輯不熟悉的程式碼前：對符號用 `goToDefinition`/`hover`，而不是從 grep 匹配
  裡猜。
- 編輯編譯型語言後：對改動的檔案跑 `diagnostics`——一次呼叫拿到編譯器裁決，
  而不是一整輪測試。
- 文字匹配有歧義時：`findReferences` 以語義方式解析符號。

查詢會臨時開啟文件（`didOpen` 當前位元組 → 請求 → `didClose`），因此每次查詢都
看到檔案此刻在磁碟上的樣子——包括 agent 自己剛寫入的編輯。每個
(server, workspace) 保持一個伺服器程序並在查詢間複用；超時或協議錯誤會拆掉該
例項，讓下一次查詢從新程序開始。路徑被限制在會話工作區內（相對 `path` 引數相對
它解析；`..` 和絕對逃逸被拒絕）。

會話工作區宣告時（`ev.workspace.opened`）core 會自動觸發一次**預熱**：元件執行
有界的副檔名普查（5000 個檔案或 2 秒預算後停止）併為最常見的語言預啟動伺服器，
使首次真實查詢不必付伺服器啟動成本。`warmup` 操作顯式重跑同一路徑。

未設定的語言降級而不中斷：沒有伺服器（或二進位缺失）的副檔名返回
`E_LSP_UNAVAILABLE`，訊息裡給出修復方式——“add one with the lsp_registry tool
(or edit <registry path>)”。模型自行回退到 grep/read。

### Registry: adding a language

三條路徑，都寫同一個檔案：

1. **TUI 選擇器** —— niffler-tui 中的 `/lsp`：瀏覽已設定伺服器，`a` 新增
   （name、command、extensions——例如 `elixir-ls`、`elixir-ls`、`.ex, .exs`），
   ctrl+s 儲存（人工審批提示，因為它在寫設定）；`e` 編輯（內建項以覆蓋形式
   開啟），`d` 刪除使用者條目。
2. **讓 agent 來做** —— “register elixir-ls for Elixir files” → 模型自己呼叫
   `lsp_registry add`（同樣需審批）。
3. **直接編輯檔案** —— `$XDG_CONFIG_HOME/niffler-lsp/servers.json`：

```json
{
  "elixir-ls": {
    "command": ["elixir-ls"],
    "extensions": {".ex": "elixir", ".exs": "elixir"}
  }
}
```

每個條目：`command`（argv 陣列，或按空白拆分的普通字串）加一個 `extensions`
對映（前導點副檔名 → LSP language id）。可選的 `initializationOptions` 透傳給
伺服器的 `initialize`。另外兩個可選鍵承載以前要寫程式碼的東西：`requires`（必須
可解析的執行時二進位，例如 jdtls 的 `["java"]`——執行時缺失的伺服器會自我報告，
而不是啟動後即死），以及 `cheap`（不建索引、因而不佔重型預熱名額的伺服器；
bash-language-server 是內建例子）。

內建預設——gopls、nimtortoise、typescript-language-server、pyright、
rust-analyzer、clangd、bash-language-server、jdtls、intelephense、solargraph、
csharp-ls——只要二進位在 `PATH` 或回退目錄（`~/go/bin`、`~/.nimble/bin`、
`~/.local/bin`、`~/.dotnet/tools`）中就可用；`make install-lsp` 冪等地安裝它們
（Go、Nim 和 TS 是必需的——Niffler 由它們建置——其餘是 y/n 提示，`--all` 用於
無人值守安裝；每種語言失敗不致命：lsp 工具只是以 `E_LSP_UNAVAILABLE` 跳過它；
`NIF_LSP_BIN` 覆蓋安裝目錄，預設 `~/.local/bin`，它也是預設回退 bin 目錄）。
Java 是唯一連*執行時*也會安裝的語言：`PATH` 上沒有 JDK 17+ 時，裝一個使用者本機
JDK 21 到 `~/.local/share/niffler-lsp/jdk`（無需 sudo，和伺服器下載一樣）——
此前沒有 JRE 的 jdtls 包裝指令碼會報告“ok”然後在查詢中途死掉。
新增同名條目即可覆蓋內建項。登錄檔每次呼叫重新讀取，因此編輯立即生效。

設定 `NIF_LSP_REGISTRY` 為絕對路徑可遷移使用者登錄檔（測試、多 harness 環境）。

**預熱預算。** core 在會話引導時釋出 `ev.workspace.opened`；元件普查工作區
（有界遍歷）並預啟動伺服器，使首次真實查詢不必付冷啟動。重型伺服器——那些給
整個工作區建索引的（gopls、rust-analyzer、jdtls、clangd、pyright、
intelephense、solargraph）——上限為 `NIF_LSP_WARM_MAX`（預設 2）個；不建索引的
*輕量*伺服器有自己的預算（`NIF_LSP_WARM_CHEAP`，預設 1，且只從 2 個以上匹配
檔案起）並且絕不擠掉重型名額——否則在一個滿是 `.sh` 檔案的倉庫裡
bash-language-server 會佔掉兩個名額之一，而任務實際所用的語言反而排不上。
`NIF_LSP_WARM_TOTAL`（預設 4）是每個工作區預啟動程序的上限。`requires` 執行時
缺失的名額會列在 `skipped`（“jdtls (needs 'java')”）而不是被啟動。

## Background processes (`processes`)

Status: **implemented**（Nim 元件；`tests/t_processes.nim`）。

bash 按設計是同步的——伺服器、監視器和測試迴圈需要不同的契約：啟動一次、
增量輪詢輸出、顯式終止。

| 工具 | 做什麼 |
|---|---|
| `process_start {command, label?, workdir?}` | 分離啟動命令（獨立程序組、stdin 來自 /dev/null、stdout/stderr 追加到 `var/processes/` 下的輸出池檔案）並立即返回 id。需審批 |
| `process_poll {id, waitMs?, filter?, tail?}` | 排空自上次 poll 以來追加的輸出——增量，絕不重新注入舊位元組；`waitMs` 阻塞直到有新輸出或程序退出（上限 25 秒）；`filter` 是對新行的正則（排空遊標仍會越過全部行推進）；任何非空 `tail` 會重讀最後約 64 KB 原始輸出。讀效應 |
| `process_kill {id}` | 終止整個程序組。需審批 |
| `process_list {}` | 顯示登錄檔——執行中和最近結束的條目及其退出碼。讀效應 |

細節：

- 子程序以追加模式寫輸出池檔案（絕不用可能死鎖的管道）；元件按每流遊標讀取，
  因此作業系統會吸收輸出突發。超過上限（32 MiB，`NIF_PROCESSES_SPOOL_CAP`）的
  輸出池會在下次 poll 時被截斷為尾部；一次 poll 每流最多返回
  `NIF_PROCESSES_POLL_CHUNK` 個新位元組（預設 64 KiB）。
- 上限：32 個併發程序；最近結束的 50 個條目留在登錄檔中。
- **結束的程序會告知其會話。** 透過 `bash` 工具的 `run_in_background` 標誌啟動
  程序時，bash 把歸屬會話交給登錄檔；該子程序退出時，`processes` 向該會話釋出
  退出通知（與子代理結算通知相同的通道），因此接下來的回合以
  `[background process p3 (dev-server) exited(code 0)] ran 412s, 8123 bytes of
  output — read it with \`process_poll\` …` 開頭。它是一個指標：輸出留在輸出池，
  命令文字從不外傳。

  這就是後臺作業不再被忽略的原因：元件按週期 tick（SDK 的 `onIdle`）回收子程序，
  而不僅是有人輪詢時——這也意味著 `process_list` 會及時顯示 `exited(code N)`，
  而不是在被問之前一直顯示 `running`。沒有歸屬會話啟動的程序（直接
  `process_start`，例如來自 `cli`），或其會話 runner 已經退場的程序，不會被告知
  任何人——請輪詢。
- `process_list` 條目帶 `started_at`（epoch 秒），因此客戶端可以顯示某物已執行
  多久（`bg 1 (7m)`）。
- 崩潰安全：子程序是程序組組長，因此被 SIGKILL 的元件會留下它們繼續執行——
  `registry.json`（pid + /proc starttime，挫敗 pid 複用）驅動一次引導清掃，在
  開始服務前殺掉前世遺留的孤兒。程序隨 harness 一起死亡。

四個工具都是 on-demand（`discover`/`invoke`）。bash 工具的 `run_in_background`
標誌是此元件之上的薄生產者：呼叫立即返回 id（不適用超時），記錄行指向
`process_poll`/`process_kill`。若元件未執行，bash 回答 `[E_BACKGROUND]` 並建議
同步執行該命令。

## External MCP servers (`mcp`)

Status: **implemented**（manager + bridge + 發現整合；UI 介面只是同一批工具上的
薄客戶端）。

Niffler 充當 MCP **客戶端/宿主**：每個設定的外部 MCP 伺服器（Model Context
Protocol）成為一個受監督的 bridge 程序，伺服器的工具成為普通目錄工具——可發現、
可呼叫，且像任何元件工具一樣受審批門控。bridge 基於官方 Go SDK
（`github.com/modelcontextprotocol/go-sdk`）。

### Shape

```
store kind "mcp"（每個伺服器一條記錄）
        │ 由 mcp manager 持有（components/mcp）
        ▼
spawn {name: "mcp-<server>", binary: var/bin/mcp-bridge, args: ["--server", <server>]}
        │ 每個伺服器一個受監督程序（經元件記錄在重啟後倖存；
        │ supervisor 在失敗時重啟它）
        ▼
bridge 宣告 mcp_<server>_<tool> schema  ──►  catalog ──► discover/invoke
        │
        └── 惰性 MCP 會話 ──► stdio 子程序 / streamable-http / sse
```

- **命名**：工具加字首 `mcp_<server>_<tool>`（niffler 小寫約定，在目錄中全域性
  唯一）；描述帶 `[mcp:<server>]` 來源字首。伺服器名必須匹配
  `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`（≤32 字元，保留 `bridge`；每 harness
  ≤100 個伺服器）；工具名清洗到同一字母表並截斷到 64 字元。manager 拒絕生成的
  工具名與另一伺服器或目錄工具衝突的伺服器。
- **暴露**：預設 on-demand（`x-harness.onDemand`）——schema 經
  `discover {component: "mcp-<server>"}` 進入會話，呼叫經 `invoke`，因此 MCP
  伺服器永不膨脹凍結的直接工具集。`"expose": "direct"` 讓某伺服器的工具進入
  每個新會話的快照。
- **惰性會話**：新增伺服器時用一次真實連線（initialize + tools/list）校驗，並在
  記錄中快取工具清單；MCP 子程序/HTTP 會話本身在首次工具呼叫時啟動，並在
  `idleMs`（預設 5 分鐘；上限 24 小時）後空閒退出。每次呼叫獲得按呼叫超時
  （`timeoutMs`，預設 120 秒，上限 24 小時）。引導 harness 從不為
  `npx`/`uvx` 啟動付費。
- **取消**：MCP 工具宣告 `x-harness.sessionId`——session runner 把活躍會話 id
  注入為 `__session.session`，被取消回合的 `cancel.mcp-<server>` 事件
  （docs/WIRE.md）立即中止在途 MCP 呼叫。直接呼叫方（CLI 指令碼）得到 `""`——
  它們無法偽造會話，未被歸屬的呼叫只受 `timeoutMs` 約束。
- **金鑰按引用**：`env` 值、`headers` 值、`args` 和 `url` 可以包含從 harness
  環境在 bridge 連線或啟動伺服器時解析的 `${NAME}` 引用——store 只保留佔位符，
  列表只回顯鍵名，缺失變數會讓連線以明確錯誤失敗，而不是傳送空憑據。裸 `$`
  保持字面。
- **沙箱**：stdio 伺服器在 guard 程序（`mcp-bridge --stdio-guard <cmd>`）下執行，
  guard 擁有伺服器的程序組並監視一條生命線管道——bridge 死亡（含 SIGKILL）時
  guard 先 SIGTERM 再 SIGKILL 整組；核心 `PDEATHSIG` 又為 guard 兜底，因此 MCP
  伺服器絕不會比其 harness 活得更久。stdio 伺服器繼承固定的環境白名單
  （PATH、HOME、TMPDIR、USER、SHELL、LANG、TERM）——harness 環境中的 `NIF_*`
  變數和金鑰永不觸及它們。HTTP/SSE 伺服器只看到設定的 `Authorization` 頭，且僅
  當它指向伺服器自身源時——憑據絕不重放到跨源重定向目標（重定向被拒絕）。
- **結果大小**：≤64 KiB 的 MCP 結果內聯返回；更大的溢位到
  `$NIF_ROOT/var/mcp-results/result-*.json`，工具返回短預覽加檔案路徑（可用
  niffler_edit、niffler_grep 或 bash 讀取），而不是撐爆上下文視窗。
- **漂移**：每個新會話（以及伺服器推送的
  `notifications/tools/list_changed`）時 bridge 重新列出伺服器的工具；契約移動
  時它持久化新鮮清單（盡力而為，rev 重試）並以退出碼 3 退出，讓 supervisor
  重啟它宣告當前真相。目錄和執行不會長期不一致。
- **隔離**：每個伺服器一個程序；掛起或崩潰的伺服器無法拖垮其他伺服器
  （supervisor 的失敗退避會重啟它）。伺服器被移除後，其工具在已有會話中保留
  凍結 schema——呼叫隨後經正常路由失敗。

### The record

每個伺服器一個 store 文件（kind `mcp`，id = 清洗後的伺服器名；`mcp_servers`
列出它們並把 env/header **值脫敏**）：

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

`type` 選擇傳輸：`stdio`（預設；`command`+`args`+可選 `env`/`cwd`）、`http`
（streamable HTTP；`url`+可選 `headers`）或 `sse`（`url`+`headers`）。
`approval: "always"` 用人工審批提示門控該伺服器的每個工具；`effect: "read"`
把工具標記為只讀供 fabric 排程；`concurrency: "serial"` 用於無法處理重疊呼叫的
伺服器（預設 `parallel`，經 SDK 有界的 `ToolConcurrent`）。manager 擁有除
`tools` 之外的每個欄位——bridge 只在伺服器漂移時重寫該快取。

### Tools

都在 `mcp` 元件上，全部 on-demand；寫操作需審批：

| 工具 | 效果 |
|---|---|
| `mcp_servers` | 列出記錄 + 實時 bridge 狀態（已註冊工具、會話狀態、最後錯誤） |
| `mcp_add` | 用一次真實連線校驗（經 bridge 的 probe 模式——設定在 stdin，不上匯流排），儲存帶快取工具清單的記錄，啟動 bridge。校驗超時：30s 或 `timeoutMs` 中較大者（`NIF_MCP_PROBE_TIMEOUT_MS` 覆蓋）——`npx`/`uvx` 伺服器的首次執行會下載包 |
| `mcp_edit` | 合併提供的欄位，重新校驗，重啟（禁用時停止） |
| `mcp_remove` | `core.remove` 該 bridge（引導時不會復活）+ 刪除記錄 |
| `mcp_refresh` | 強制 bridge 丟棄會話、重連並立即重新列出 |

因此新增 MCP 伺服器按設計會請求兩次審批：一次是 `mcp_add` 本身，一次是它觸發
的 `core.spawn`——改變 harness 形態上的人工門控（docs/ARCHITECTURE.md）。

### Prompts, resources, registry

- **Prompts 變成斜槓命令。** 每個伺服器 prompt 註冊為隱藏目錄工具
  `mcp_<server>_prompt`（LLM 不可見，`x-harness.hidden`）加一個斜槓命令
  `mcp-<server>-<promptname>`，其命名引數映象 prompt 的 arguments（每伺服器
  ≤32 個 prompt，每個 ≤16 個引數）。渲染 prompt 是普通匯流排呼叫；結果把渲染文字
  作為 `userMessage` 攜帶，UI 把它作為**使用者**訊息追加到會話（斜槓結果約定，
  `ui/frontend/src/lib/slashResult.ts`）——prompt 輸出絕不以 system/assistant
  內容注入記錄。bridge 在漂移時像工具一樣重新註冊它們（含伺服器推送的
  `notifications/prompt_list_changed`）。
- **Resources** 以一個併發工具 `mcp_<server>_resources` 呈現
  （`x-harness.effect: "read"`）：`{op: "list"}` 或 `{op: "read", uri: ...}`。
  文字結果遵循與工具結果相同的 64 KiB 內聯上限（更大的溢位到
  `var/mcp-results`）；二進位 blob 以 base64 加 MCP mimeType 返回。
- **Registry**：`mcp_search <query>` 查詢官方 MCP Registry
  （`registry.modelcontextprotocol.io`；用 `NIF_MCP_REGISTRY_URL` 覆蓋），返回
  name/title/description/version 以及給 npm/PyPI 打包條目建議的 `mcp_add`
  設定——版本從登錄檔固定（`npx -y <id>@<v>` / `uvx <id>==<v>`）。只有當條目無需
  任何設定時才標記 `installable`；包 id 中的模板變數或宣告的必需 env/headers
  以 `requirements`（“configuration required: ...”）呈現，而不是半填的設定。
- **漂移也覆蓋 prompts**：`checkDriftLocked`（新會話）和兩個 list-changed 通知
  都會重新列出工具*和* prompts；記錄的快取被重新整理，bridge 以退出碼 3 觸發
  supervisor 重啟。

### Verification

`tests/t_mcp.nim`（在 `make test` 中）：把一個無依賴的 fixture MCP 伺服器
（`tests/fixtures/mcp_server.nim`，stdio 上的換行分隔 JSON-RPC）和一個 mock 登錄檔
（`tests/fixtures/mock_registry.nim`，純標準庫 HTTP）編譯進私有沙箱，並演練整個
契約——add（含金鑰脫敏）、bridge 註冊、發現提示 + 完整 schema、惰性 invoke、
工具錯誤傳播、飛行中取消（`cancel.mcp-<server>` 中止在途呼叫）、resources
list/read、prompt 斜槓命令 + 渲染、對 mock 的登錄檔搜尋、伺服器推送漂移
（持久化 + 重啟 + 重新發現）、edit/respawn、用於引導恢復的 spawn 引數持久化，
以及移除。兩個迴歸測試釘住程序衛生修復：被 SIGKILL 的 guard 不得留下孤兒 MCP
伺服器（核心 `PDEATHSIG`），失敗的 add 不得留下記錄。Go 單元測試（`make gotest`）
覆蓋 SDK 的凍結註冊門（`Announce` 在遲註冊時 panic；ready 後的呼叫以
`not-ready` 失敗）、名稱/契約校驗、登錄檔形態解析、傳輸憑據/重定向規則，以及
取消管線。

## Progressive tool discovery

Status: **implemented**。

Niffler 保持一個完整的全域性目錄，同時向每個會話暴露一個小而不可變的工具集。
額外的 schema 透過 `discover` 進入只追加的訊息歷史；對這些工具的呼叫走固定的
`invoke` 閘道器。這減少了提示詞膨脹，又不削弱 core 的審批或超時策略。

### Model

#### Existence is global; exposure is per conversation

元件在匯流排上存活即存在。`reg.publish` 把它的所有工具插入 core 的目錄；
`reg.depart` 或 supervisor 清理會移除它們。`var/bin` 下的二進位在 manifest
autostart、`core.spawn` 或外掛安裝啟動它之前是惰性的。

暴露是另一回事：

| 級別 | schema 後設資料 | 直接 LLM schema | 發現 | 呼叫 |
|---|---|---|---|---|
| direct | 無 `x-harness.onDemand` | 進入新會話快照 | 提示 + schema 查詢 | 直接或 `invoke` |
| on demand | `x-harness.onDemand: true` | 省略 | 提示 + schema 查詢 | `invoke` |
| hidden | `x-harness.hidden: true` | 省略 | 省略，含顯式查詢 | 僅元件/core |

兩者同時存在時 hidden 優先。暴露不是 ACL：完整目錄仍是路由的權威。面向 LLM 的
`invoke` 閘道器拒絕隱藏目標，而元件仍可直接經 NATS 請求隱藏工具。

#### Full catalog and projections

- `catalog {op: "snapshot"}` 返回完整元件註冊和 schema。session runner 從它
  播種本機目錄。
- `catalog {op: "components"}` 返回 CLI 使用的完整元件→工具名對映。
- `catalog {op: "list"}` 返回當前按名稱排序的、面向*新*會話的直接投影。它不是
  已有會話的工具集。
- 分發、審批、`x-harness.timeoutMs` 和元件間呼叫始終查詢完整目錄。

### Core tools

`discover` 和 `invoke` 是每個新會話中的直接 core 工具。`profile` 是管理命名
工具設定的 on-demand core 工具；`session.profile` 在會話首次建立時選擇一個。
Web UI 或 TUI 中的 `/profile` 設定 `/new` 使用的客戶端預設值。
`session_info`（onDemand）總結會話（頭欄位、按角色訊息計數、累計 completion
token）；`prompt_preview`（onDemand）展示組合請求的來源——系統提示詞來自哪裡、
多少個專案上下文檔案餵給它、凍結的直接工具名 vs. 目前已發現的 schema、
訊息/token 計數——而不傳送任何東西。`doctor`（onDemand）是一次性機器可讀健康
報告：store 可達性、llm 註冊、active provider、systemprompt 是否存在、目錄大小、
會話數，外加自檢扇出——每個註冊了標準 `selftest` 工具（docs/WIRE.md）的元件都會
被要求自檢，其逐項結果收集進報告（未實現的元件列為未實現）。`deep: true` 時
探測變成實測——lsp 元件對一次性 fixture 啟動每個已設定語言伺服器（乾淨檔案 →
0 診斷、hover 有答案、壞檔案 → 錯誤），store 對其引擎做完整的 put/get/rev/list/del
往返。快速模式保持廉價（僅二進位解析）；適合作為 CI 存活門或第一步診斷。UI 把它
暴露為 `/doctor`。報告還帶一份渲染好的 Markdown 表（`text`，即 `/doctor` 顯示的
內容），`ask: true` 會加一條 `userMessage`（docs/WIRE.md 約定），讓客戶端把解讀
請求作為使用者回合提交。

#### Explicit client commands

聊天客戶端無需 LLM 回合即可暴露同樣的目錄狀態：

- `/components [all|direct|discovered|undiscovered]` 列出活躍元件並按當前會話中
  每個工具的暴露狀態過濾。`direct` 表示 schema 在請求的 tools 陣列裡；
  `discovered` 表示它已在歷史中、可透過 `invoke` 呼叫；`undiscovered` 表示它
  存活但尚未暴露給本會話。
- `/discover COMPONENT` 或 `/discover tool=NAME` 執行顯式發現請求，並把返回的
  schema 記錄進會話的持久化發現摘要。它不把工具提升進直接陣列；想要直接 schema
  暴露時，在 `/new` 用設定，或 `invoke` 時帶 `sticky: true`。
- `/profile NAME` 為新會話選擇命名設定；`/profile default` 清除選擇。改變它
  絕不改寫已有會話的凍結暴露。

Web 的 Components 面板提供相同的 all/direct/discovered/undiscovered 過濾和文字
搜尋。隱藏工具保持內部，`/discover` 永不列出。

#### Hints

```json
{"query": "web"}
```

`query` 可選，大小寫不敏感地匹配元件名、工具名和描述。多詞查詢是合取：每個空白
分隔的詞都必須出現在元件名或工具名/描述中——像 “mechanical fan-out” 這樣的
關鍵詞短語即使沒有描述逐字包含它也會匹配。空查詢返回只帶工具名的匯流排目錄；
`component` 和 `tools` 呼叫返回完整描述和 schema。結果是確定性的：元件和工具按
名稱排序，描述是規範化單行提示，截斷到 200 字元，易變欄位如 pid 和註冊時間被
排除。

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

`discover {component: "fetch"}` 返回該元件的 direct 和 on-demand 提示。沒有
非隱藏工具的元件被省略。

#### Schemas

只請求下一步需要的工具，一次最多 16 個：

```json
{"component": "fetch", "tools": ["fetch"]}
```

結果包含規範化完整 schema，按工具名排序：

```json
{
  "component": "fetch",
  "tools": [
    {"name": "fetch", "schema": {"type": "object", "properties": {}}}
  ]
}
```

未知和隱藏工具請求的錯誤形狀相同，因此發現不是隱藏工具的存在性預言機。

不帶 `component` 的 `tools` 搜尋每個活躍元件——呼叫方常常知道工具名但不知道
歸屬。返回的每個 schema 隨後攜帶歸屬 `component`，沒有可發現工具的名稱列在
`notFound`（空的 schema 集還是錯誤，會點名請求的工具）。

#### Invocation

透過固定閘道器呼叫已發現的 schema：

```json
{
  "tool": "fetch",
  "arguments": {"url": "https://example.com"}
}
```

`invoke` 遞迴進入正常的 `dispatchToolCall` 路徑。目標工具的審批對話方塊、超時、
元件路由和錯誤因此與直接呼叫完全一致。它也能觸達會話啟動後新註冊的、當時還不
存在的非隱藏工具。

### Session state and caching

提供商提示詞快取包含頂層工具定義。把已發現的具象 schema 加到後續 `tools` 陣列
會改變字首並使累積快取失效。只把 schema 作為工具結果返回是隻追加的，但模型仍
需要一個宣告的函式來呼叫它；這就是 `invoke` 固定且通用的原因。

首個回合，session runner：

1. 計算 `Catalog.promptTools()`；
2. 把確切有序的 schema 存到 store kind `session`、id
   `<sessionId>:tools`；
3. 在每次 LLM 輪次和 runner 重啟後都使用該快照。

文件形狀：

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

`direct` 攜帶 schema，因為它是 resume 安全的提供商快照。`discovered` 是供檢查
和 UI 狀態用的持久化摘要；schema 本身存在於持久化的工具結果訊息中。只有成功的
全 schema `discover` 呼叫會更新它。提示搜尋和失敗查詢不會。

元件註冊變動絕不改變已有會話的直接陣列。後來的元件透過 `discover` 找到、經
`invoke` 呼叫。若一個直接元件離場，其凍結 schema 留在該會話中以求快取穩定；
呼叫經正常路由失敗，當前發現會反映它已消失。

### Shipped policy

完整出廠 manifest 下，有 7 個直接工具：

- Core：`discover`、`invoke`。
- 例行工作：`bash`、`grep` 和檔案工具 `read`/`edit`/`write`（`edit` 元件）。

長尾是 on-demand：

- 搜尋和檢查：`files`（排序列表）、git 工具、`undo_last_edit`，以及
  observe/logfile 診斷。
- 狀態和內省：store `get`/`list`、`session_info`，以及技能入口
  `skill_list`/`skill_load`（只在合適時載入工作流指南）。
- 編排：`fabric`、`agent_*` 工具、`expert_follow`。
- Core 生命週期/狀態/目錄、builder、plugins 和 fetch。
- Models 和 provider 管理。
- 技能資源、線上搜尋、安裝和移除。

內部工具保持隱藏：core `session`/`session_prepare`、store `del`、LLM
`chat`/`llm_resolve`、systemprompt prompt，以及帶憑據的 provider 工具
（`provider_update`、`provider_use_environment`、`provider_status`、
`provider_active`、`provider_get`）。Store 的 `put` 是 on demand（它攜帶
`x-harness.sessionId` 用於凍結工具集快照）。

缺少 `onDemand` 後設資料仍視為直接，以相容第三方。會話啟動後 spawn 的元件仍不會
改變該會話的凍結直接陣列；discover/invoke 是新能力握手的途徑。

### UI

Live Components 面板把全域性 `core.status` 資料與活躍會話的暴露文件結合。工具
chip 用文字加顏色：

- `direct`：在不可變提供商工具陣列中；
- `seen`：其 schema 已在本會話成功發現；
- `demand`：存活且非隱藏，但未在本會話暴露；
- `internal`：對 LLM 隱藏。

元件存活是單獨的狀態點。面板在會話選擇、目錄變化、發現/完成事件、重連和週期
輪詢時過載。刪除會話也會刪除其暴露文件。

### Verification

`tests/t_discover.nim` 是端到端契約。它證明確定性投影和發現、完整目錄保留、
隱藏不洩露、經 invoke 的審批與超時保持、實際的 session-runner LLM 負載、遲
註冊下的不可變行為、schema 在訊息歷史中的持久化，以及持久的 UI 暴露後設資料。

用 `make test-discover` 單獨執行；它也是 `make test` 的一部分。

---

## Model catalog (`models`)

`models` 元件是 Niffler 可替換的提供商/模型後設資料平面。它不屬於 core，也不是
通用推理介面卡。它回答存在哪些提供商和模型、如何定址、支援什麼、以及限額和
價格。`llm` 元件仍然擁有實際 wire 協議、認證流程、請求變換和流式。

設計借鑑了 Pi 和 OpenCode 中有用的共同形態：

- models.dev 是廣泛的精選基線。
- 一個小型內嵌種子讓首次離線引導即可用。
- 最後驗證過的下載被原子寫入，失敗時保留。
- 修正和提供商發現是確定性層，不是對下載檔案的編輯。
- 使用者提供的模型 id 嚴格解析；含糊的裸 id 絕不按目錄順序選擇。

### Merge order

有效目錄按此順序重建：

1. `NIF_MODELS_PATH`、快取的 models.dev 目錄，或內嵌種子。
2. 已註冊的 `x-models-source` 外掛，按 `priority` 升序、再按
   `component/tool`。因此更大的 priority 勝出。
3. `NIF_MODELS_OVERRIDE`，總是最後。

外掛和本機層是 JSON Merge Patch（RFC 7396）：物件合併，陣列和標量替換，`null`
刪除鍵。完整的 models.dev 形態被保留，包括 Niffler 尚未使用的欄位。

元件在啟動時和每小時重新整理。models.dev 下載在其快取年齡小於五分鐘時跳過。HTTP
抓取有界、重試、校驗（沒有可用模型條目的目錄被拒絕，因此畸形回應無法替換
last-known-good 快取），並原子重新命名進 `var/models/api.json`。每個已註冊外掛
來源也有一份 last-known-good 補丁在 `var/models/sources/` 下；來源暫時失敗時
使用該補丁，但僅在該來源元件仍註冊期間。本機覆蓋在檔案於重寫中途不可讀時保留
上一份補丁。失敗的重新整理會自動重試（30 秒或設定的間隔，取更早者），因此沒有
`reg.depart` 的崩潰對賬不會拖到下一個小時 tick。`ev.sys.drain` 取消重新整理工作並
關閉元件。

### Tools

| 工具 | 用途 |
|---|---|
| `models_providers` | 提供商連線後設資料和設定狀態，絕不含金鑰值 |
| `models_list` | 帶能力、模態、限額和成本的過濾模型搜尋 |
| `models_get` | 供其他元件使用的精確提供商/模型描述符 |
| `models_resolve` | 嚴格的 `provider/model` 或全域性唯一裸 id 解析 |
| `models_refresh` | 排隊重新整理 models.dev 和每個活躍擴充套件來源 |
| `models_sources` | 來源、新鮮度、過期回退和錯誤診斷 |

`models_list {status: "active"}` 也匹配 status 欄位缺失的模型（models.dev 對正常
模型省略它）。列表結果在會超過匯流排負載限制時被裁剪，單個過大的描述符會報錯而
不是在 wire 上超時。描述符後設資料遞迴脫敏：類金鑰鍵（api keys、tokens、
passwords、credentials、authorization headers、private keys、cookies）絕不到達
呼叫方，無論在提供商還是模型層。

實時來源：models.dev 是後設資料權威（限額、定價），但提供商實際提供的 id 來自
提供商自身。存在兩個互補介面——`provider` 元件的 `provider_models` 工具用已存
或顯式憑據按需探測端點（連線表單），而 `llm` 元件註冊一個 `x-models-source`
外掛（priority 150），其補丁新增每個提供商被觀察到提供的 id（chat 之後後臺
探測，10 分鐘 TTL），使整個目錄收斂到端點實際列出的內容。兩者都是盡力而為：
失敗絕不影響 chat 或目錄基線。

`llm` 向 `models_get` 詢問所選模型的上下文視窗。顯式提供商 `context` 和
`NIF_OPENAI_CONTEXT` 仍然優先，若移除 `models`，現有小型回退仍可用。提供商端點
按主機名分類，而不是 URL 子串。互動客戶端應呼叫隱藏、無憑據的
`llm_resolve {model?}`，而不是重複這套優先順序：它報告有效全域性 provider、可選的
會話模型覆蓋、catalog、context，以及每個值的來源。

### Source plugins

模型來源是 `plugins` 安裝的普通元件。一個隱藏工具攜帶此註冊擴充套件：

```json
{
  "x-models-source": {"version": 1, "priority": 200},
  "x-harness": {"hidden": true}
}
```

`models` 從 `reg.publish` 和 core 的完整目錄快照中發現帶標記的工具，因此元件
引導順序無關緊要。它以 `{"version": 1}` 呼叫該工具。結果是 JSON Merge Patch
（RFC 7396）：

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

完整的可工作來源元件示例——標記、工具、包佈局和驗證——見
[MODEL_SOURCES.md](MODEL_SOURCES.md)。

把來源放進普通 `niffler.json` 包。安裝、更新、移除、程序隔離和持久化都已由現有
`plugins` 和 core 生命週期處理。移除來源元件會立即從有效目錄移除其補丁。core
不新增任何模型專屬擴充套件機制。

### Configuration

設定變數（`NIF_MODELS_*`）列在上面的主 [Environment variables](#environment-variables)
表中。

元件只報告提供商使用哪些憑據環境變數名以及是否設定了其中一個。它絕不返回憑據
值。提供商專屬 OAuth、環境憑據、header、請求變換和原生 API 行為屬於推理介面卡
元件，它們可以獨立於本目錄以外掛形式出廠或安裝。

---

## System prompt (`systemprompt`)

Status: **由 `systemprompt` 元件 implemented**。

### Boundary

系統提示詞不是 LLM 呼叫的工具——它是每個會話起始時遵循的常駐指令集。它住在元件
裡，不在 core：core 只保留最小的結構性回退，session runner 每個會話從
`svc.systemprompt.call` 獲取真正的憲法一次。替換憲法是普通 Niffler 操作：寫一個
在同一主題上應答的元件，`build` 它，`kill` 舊的，`spawn` 你的。agent 可以對自己
這麼做。

### How it works

- **每會話凍結。** 解析出的提示詞在首個回合持久化進會話頭（`systemPrompt`
  欄位），並在任何 runner 程序的每次恢復中原樣複用。提示詞字首保持穩定，因此
  提供商複用快取；中途死亡或變化的元件絕不改寫執行中會話的指令。
- **回退。** 元件缺席、緩慢（500 ms 探測，目錄說它已註冊時改為 8 s 預算）或
  損壞 → core 內建的最小提示詞。core 絕不硬依賴元件來引導。
- **上限。** 應答在兩側都截斷於 200 KB。
- **Agent 預取。** `agent` 元件在子代理子會話的首個回合前為其請求提示詞，並經
  session 呼叫的 `systemPrompt` 欄位傳入（盡力而為——runner 自己的回退覆蓋元件
  缺失）。

### The default component's prompt assembly

1. `components/systemprompt/baseprompt.txt` —— 產品提示詞（自擴充套件階梯、SDK
   示例、倉庫佈局），做 `$ROOT` 替換，編譯期經 `staticRead` 烘焙進二進位。編輯
   它 = 重建 + 重啟；沒有執行時檔案依賴。
2. 倉庫的本機上下文檔案，Pi 風格，包在 `<project_context>`/
   `<project_instructions path="...">` 標籤裡，位於產品提示詞之後：
   - 每目錄首個命中勝出：`AGENTS.override.md`、`AGENTS.md`、`AGENTS.MD`、
     `CLAUDE.md`、`CLAUDE.MD`（每目錄一個檔案——`AGENTS.md` 遮蔽旁邊的
     `CLAUDE.md`；跟隨符號連結）；
   - 從會話 cwd 向上到 `/` 的祖先遍歷，harness 根優先，按路徑去重——越靠近
     cwd 的檔案越晚出現，因此最具體的指令是模型最後讀到的；
   - worktree 遮蔽規則：harness 根是主倉庫下的 `git worktree` 時，跳過主倉庫
     根的上下文檔案——否則祖先遍歷會把同一邏輯倉庫範圍應用兩次。
3. 每會話的 `<workspace>` 尾巴，僅在會話 cwd **不是** harness 根時追加：它點名
   工作目錄（相對路徑從它解析）和 harness 根，使 `docs/`、`components/` 和
   `sdk/` 從根外工作區也能按絕對路徑解析。上面的凍結頭要麼有要麼沒有路徑——
   根是每會話事實，在同一臺機器上每個會話都一樣，因此提供商快取字首仍然對齊。

該工具是 `x-harness.hidden`——它絕不出現在 LLM 工具集中；它是基礎設施，只有
core 和元件可達。

## Observation and logs

Status: **由 `observe` 和 `logfile` 元件 implemented**。

### Boundary

觀察匯流排，而非元件內部。兩個元件都是基於 SDK 的普通 NATS 公民；core 從不匯入
它們。唯一的 core 整合是可選的 nats-server HTTP 監控：core 擁有匯流排時分配第二個
loopback 埠，並在伺服器就緒後寫 `var/nats-monitor-url`。

觀察是一項管理能力。匯流排捕獲可能包含工具引數、模型輸出、審批和來自每個會話的
資料。Niffler 當前的信任模型是單一可信使用者/管理員；不要把 observe 服務或捕獲
目錄暴露給不可信的匯流排客戶端。

### `observe`: bounded live inspection

`observe` 有一個原始 `>` 訂閱。它保留原始 JSON 節點，包括未知信封欄位和裸註冊
負載。畸形 JSON 在 UTF-8 有效時保留為 `{raw, decodeError}`；任意位元組改用無損
`rawBase64`。超大訊息以有界 base64 預覽表示，而不是讓一條訊息吃掉程序。

全域性環形緩衝同時受訊息數和近似 wire 位元組約束。每個定向探測有獨立的條數和位元組
上限；探測數量也有上限。已停止的探測在 `observe_remove` 釋放其記憶體前仍可查詢。

| 工具 | 用途 |
|---|---|
| `observe_subjects` | core 可達時列出權威元件/服務檢視、已知事件模式，以及最常觀察到的具體主題 |
| `observe_listen` | 為詞法正確的 NATS 模式（`*` 和結尾 `>`）加可選正則啟動有界捕獲 |
| `observe_trace` | 捕獲對某元件的呼叫並按信封 id 關聯結果/錯誤收件箱回覆 |
| `observe_probes` | 檢查探測狀態、保留位元組、上限和在途 trace |
| `observe_stop` | 凍結探測同時保留其條目 |
| `observe_remove` | 刪除探測並釋放其記憶體 |
| `observe_events` | 按時間/kind/component/subject/正則過濾，以最新優先查詢探測或全域性環形緩衝 |
| `observe_logs` | 在記憶體中查詢最近的 `ev.log.*` 事件 |
| `observe_dump` | 需審批，把單個探測匯出到 `NIF_OBSERVE_CAPTURE_DIR` 之下；不接受任意輸出路徑 |
| `observe_monitor` | 讀取 nats-server 連線/訂閱計數和最常訂閱模式 |
| `observe_send` | 向具體的 `ev.*` 或 `llm.cancel.*` 主題釋出事件；需審批 |
| `observe_request` | 對具體 `svc.*.call` 的診斷請求/應答；需審批且限制 30 秒 |

`observe_send` 不能傳送 call/result/error 信封或註冊。`observe_send`、
`observe_request`、`observe_monitor` 和會改檔案的 `observe_dump` 帶
`x-harness.approval: always`，因此 LLM 路徑必須透過 core 的人工門。
直接與 `svc.observe.call` 對話的客戶端已經是可信匯流排對等方，繞過 core 策略，
正如它可以直接呼叫任何其他服務主題。生成的捕獲按最舊優先修剪到位元組配額和
256 檔案上限。

Trace 請求在 60 秒後從待關聯表過期。探測主題、標籤和正則輸入有固定上限；超大
探測條目被丟棄並計數，而不是保留在位元組預算之外。工具回應在 wire 約 64 KiB 的
內聯結果約定之前停止並報告 `truncated`（或大型診斷回覆的值位元組後設資料），而不是
返回無界資料。

### `logfile`: rotating JSONL persistence

`logfile` 是盡力而為的程序本機持久化，不是審計日誌。Core NATS 是至多一次：
啟動前或重啟期間發出的事件會丟失。保證重放需要顯式的 JetStream 設計。

預設輸入是 `ev.log.>`。合法的元件名得到單個檔案：

```text
var/logs/bash.jsonl
var/logs/bash.jsonl.1
...
```

`NIF_LOGFILE_SUBJECTS` 可以選其他主題。非日誌流量（包括全匯流排 `>`）進入單個
`bus.jsonl`；因此動態收件箱主題不會產生無界的檔案描述符或檔名。元件日誌檔案
數有上限，超出的/偽造的元件主題也回退到 `bus.jsonl`。多個設定的模式視為一個
本機過濾的並集，因此重疊模式對每條匹配發布恰好持久化一次。

每行記錄寫入時間與原始 wire 資料：

```json
{"receivedAt": 1780000000.25, "subject": "ev.log.bash", "message": {"v": 1, "id": "...", "kind": "event", "payload": {"level": "info", "msg": "..."}}}
```

畸形 UTF-8 輸入使用無損 `rawBase64`；文字型畸形輸入使用 `raw` 和
`decodeError`。落盤對每條記錄開啟、追加、重新整理、關閉。輪轉在重新命名已關閉檔案前
比較 `當前大小 + 記錄大小`，因此恰好邊界的寫入不會留下過期檔案控制代碼。大於設定
檔案大小的單條記錄被保留為活躍檔案，並在下一條記錄前輪轉。
`NIF_LOGFILE_KEEP=0` 不保留任何輪轉代。

`logfile_search` 只從保留檔案讀取有界尾部，把匹配記錄按 `receivedAt` 最新優先
排序，並報告 `truncated`、`scannedBytes`、畸形行計數和讀取錯誤。結果也有編碼後
的回應位元組預算。結構化日誌記錄暴露 `component`、`level`、`msg`、`ctx` 和可選
的 emitter 時間；原始匯流排記錄暴露保留的訊息。搜尋絕不相信 emitter 提供的時間戳
來決定 `since`/`until` 視窗。目錄列舉受 `NIF_LOGFILE_DIRECTORY_ENTRIES` 限制，
檔案更多時報告 `directoryTruncated`；搜尋仍檢查有界子集。

`logfile_paths` 報告有界的保留檔案列表加 `writeErrors`、`lastError` 和
`lastErrorAt`。檔案系統失敗也會寫 stderr。在平臺允許時捕獲目錄僅使用者可訪問；
活躍符號連結目標被拒絕。

### SDK APIs

三個 SDK 都暴露相同的觀察/日誌和原始信封 API：

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

每個 SDK 都讓 NATS 做主題匹配，並且只把訊息派發給投遞它的訂閱所繫結的 handler。
這避免了以前的叉積：一次呼叫可能經 call、event 和 tap 路徑重複投遞。Nim 保持
無回撥、無執行緒；Go 使用已有的互斥鎖，TypeScript 用 promise 鏈。Go 等待排空的
訂閱回撥（到其有界關閉寬限），TypeScript 等待排隊的 handler，且不會死鎖顯式
關閉自己元件的 handler。

#### Idle work (`onIdle`)

三個 SDK 都暴露相同的*空閒接縫*——為沒有請求能承載的工作準備的回撥（回收後臺
子程序、健康探測、快取重新整理）。`components/processes` 用它來在無人輪詢時察覺後臺
子程序退出，這正是其退出通知得以實現的原因。

```nim
proc onIdle*(c: Component, intervalMs: int, handler: IdleHandler): Component
```

```go
func (c *Component) OnIdle(interval time.Duration, handler func(*Component)) *Component
```

```ts
comp.onIdle(intervalMs, handler)
```

API 是映象的；*執行模型*是各執行時自己的，因此契約按 SDK 分別陳述：

| SDK | 執行於 | 互斥 |
|---|---|---|
| Nim | pump 迴圈，在遍歷之間 | 絕不在 handler 執行時——該迴圈是序列的 |
| Go | 自己的 ticker goroutine | 取序列 handler 鎖；`ToolConcurrent` handler 只持讀鎖，因此可與它們重疊 |
| TS | promise 鏈，像每個 handler | 絕不與其他 handler 交錯 |

三者共同點：在 connect/run 之前註冊，每元件一個 handler（第二次註冊替換第一次），
間隔下限 10ms，定時器隨連線啟動、隨關閉停止，idle handler panic 會被記錄、
絕不致命。只要“每 N 秒”就是全部需求，優先用它而不是元件執行緒。

Nim 的任意信封請求輔助函式在等待期間只繼續泵原始 tap 訂閱。Tool 和 event
handler 保持不巢狀，而觀察者可以在 `observe_request` 期間為目標請求和應答打
時間戳。Trace 時長和過期使用單調時鐘；顯示的 `at` 值仍是牆鍾 epoch 秒。

結構化日誌在確切主題 `ev.log.<component>` 上釋出事件，帶
`{component, level, msg, ctx?, at}`。級別為 `debug`、`info`、`warn` 和 `error`。
`NIF_LOG_LEVEL` 預設 `info`，並在每個 SDK 中於釋出前壓制更低階別。發出的非法
級別會失敗；非法閾值回退到 `info`。

### Monitoring

core 自行啟動 nats-server 時使用不同的 loopback 客戶端和 HTTP 埠，然後寫入
（二進位是 `components/nats` 建置出的元件 `var/bin/nats-server`，若不存在則用
PATH 上的 `nats-server`）：

```text
var/nats-url
var/nats-monitor-url
```

監控發現檔案僅在客戶端連線成功後寫入。複用或遠端匯流排沒有可發現的 HTTP 端點；
顯式設定 `NIF_OBSERVE_MONITOR_URL`。`NIF_NATS_SPAWN=1` 強制在隨機埠啟動 core
獨佔的隔離匯流排（主要用於測試和診斷）——絕不用 4222；環境裡顯式的
`NIF_NATS_URL` 優先。

`observe_monitor` 每次請求用新的 HTTP 客戶端讀取 `/subsz` 和 `/connz`。它報告
訂閱詳情是否被截斷；`mostSubscribed` 指訂閱者密度，不是訊息吞吐。

所有 `NIF_OBSERVE_*`、`NIF_LOGFILE_*` 和 `NIF_LOG_LEVEL` 變數都列在上面的主
[Environment variables](#environment-variables) 表中。

所有上限在啟動時校驗；非法設定以非零退出，而不是靜默替換為預設值。

### Verification

`tests/t_observe.nim` 覆蓋精確一次 tap、通配邊界、註冊捕獲、上限/位元組淘汰、
診斷請求期間的單調 trace 關聯、畸形呼叫回覆、超時行為、內嵌 NUL 和無效 UTF-8
原始資料、回應邊界、審批後設資料、按配額修剪的安全 dump、監控發現和非法設定。

`tests/t_logfile.nim` 覆蓋 SDK 日誌過濾、最新優先查詢、時間/正則過濾、編碼回應
和實際磁碟讀取邊界、精確一次重疊主題模式、已關閉檔案輪轉、零保留、內嵌 NUL
全匯流排保留、有界路徑列表、sink 健康和非法設定。兩個測試都使用隔離的臨時輸出
目錄，且都是 `make test` 的一部分。

## Fabric and subagents

`fabric` 元件新增可程式設計工具呼叫：模型編寫一個驅動 Niffler 工具自身的 Nim 程式，
只有程式的 `finish()` 值進入會話。`agent` 元件把會話變成子代理。完整設計和威脅
模型見 [research/FABRIC.md](research/FABRIC.md)（塑造它的外部評審：
[research/FABRIC_FEEDBACK.md](research/FABRIC_FEEDBACK.md)）。帶提示措辭和可
工作示例的使用者指南：[FABRIC_GUIDE.md](FABRIC_GUIDE.md)。

| 工具 | 做什麼 |
|---|---|
| `fabric {code | name, tools?, strings?, timeoutMs?, maxCalls?}` | 執行一個 LLM 編寫的 Nim 程式：`var/bin/fabric-exec` 把它編譯進私有程序（無內嵌 VM；相同程式快取在 `var/fabric-cache`）。`code` 是內聯程式原始碼；`name` 執行模型策展的 `fabricprog` 庫中的已存程式。帶 `tools` 時，選定 schema 被釘住並生成編譯期檢查的 `tools.<name>(...)` 包裝；allowlist 內的 `callTool` 仍是回退。只有 `finish(value)` 到達會話。獲批的原生程式碼就是 bash 級信任，不是沙箱。 |
| `agent_run {task, session?, close?, fork?, model?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | 在子代理會話中執行任務並返回最終回覆。不帶 `session` 時啟動**全新**子代理（自己的 runner、自己的迴圈）。帶 `session`（此前返回的 `sessionId`）時給該**已有子代理再一個回合**——其會話、模型、thinking、工具和預算在首回合凍結，因此呼叫方的 model/thinking/tools/預算引數被忽略，結果報告子代理的 `effective` 控制；子代理必須屬於本會話、未關閉、且不在回合中（否則以 `code: "busy"` 拒絕——改用 `agent_spawn` 排隊）。全新執行的每作業可選預算：`maxRounds`（每回合工具輪數，1–`NIF_MAX_TURN_ROUNDS`）、`maxCalls`（工具分發總數，1-500）、`maxTokens`（累計 token）——耗盡會讓回合以 budget-exhausted 失敗結束。`close: true` 在本回合後使子代理退場（不刪除任何東西；後續繼續會被拒絕）。 |
| `agent_spawn {task, session?, close?, fork?, model?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | 同樣任務在後臺啟動；立即返回 `{jobId, sessionId}`。不帶 `session` 時啟動全新子代理；帶 `session` 時為已有子代理**排隊**另一個回合（凍結控制規則同 `agent_run`，但子代理在回合中也可以——該回合隨後執行；只有血緣父會話可以繼續）。`close: true` 在排隊/後臺回合結算後使子代理退場。`timeoutMs` 是作業預算：超過後該作業會在下次被觀察時被取消（agent_stop 語義）。 |
| `agent_status {jobId}` | 非阻塞的持久化作業查詢（running/done/failed/stopped + 回覆或錯誤）。 |
| `agent_wait {jobId, timeoutMs?}` | 阻塞直到後臺作業終態；遲到的等待讀取持久化記錄。 |
| `agent_stop {jobId}` | 真正取消執行中的作業：子代理的 LLM 請求被中止，其回合迅速結束，在途 bash 命令被殺（整棵程序樹）。終態記錄寫 "stopped"。 |
| `agent_steer {session_id, message}` | 向執行中的後臺作業回合注入訊息（在 LLM 輪次之間排空）。 |
| `agent_list {scope?}` | 呼叫方的子代理名冊，由持久化血緣推導：每個子代理一行，帶 `sessionId`、`jobId`、`task` 和基於駐留的 `status`——`running`（正在工作）、`idle`（回合之間駐留）、`ready`（僅在儲存中；**可恢復，不是已完成**）。`scope: "descendants"` 遍歷整棵樹（當前深度 1）。子代理結算時你會被通知，因此這是用於定位，不是輪詢。 |
| `agent_notices {session?, peek?}` | 排空本會話待處理的子代理**結算通知**——每個結束、被停止或失敗的後臺子代理一條。通知會自動投遞（見下文）；這裡用於會話空閒期間到達的通知，`peek` 檢視而不消費。 |

### Settlement notices

到達終態的後臺子代理會告知其**父會話**，而不只是 UI（`ev.agent.done` 僅觀察）。
通知是一條在任何投遞嘗試之前寫入的持久化 `agentnotice` 記錄，它是*指標*，
不是回覆：

- 父會話回合執行中時，通知立即折入（steer 通道）為帶結構標記的使用者訊息；
  would-stop 點也會排空通知，因此回合不能在最後一步收到結算時關閉
  （`NIF_AGENT_NOTICE_HOLD=0` 只禁用這一保持）；
- 否則父會話被**喚醒**：agent 元件啟動一個唯一工作就是折入待處理通知的回合，
  因此結算無需人類詢問即可見。喚醒受 `NIF_AGENT_WAKES`（預設 3 個連續喚醒
  回合；人類的下一條訊息重置預算，`0` 禁用喚醒）約束。被拒絕的喚醒不持久化
  任何東西，父會話下一回合在回合頂部排空所有待處理通知（pull 通道）——模型
  無需輪詢；
- 無論哪條通道，通知攜帶有界 `summary`、`replyBytes`（未截斷長度）和
  `fullReplyIn: "agent_status"`，因為完整回覆已經持久化在 `agentjob` 記錄中、
  一次呼叫可達。

通知是盡力而為：store 或 agent 元件不可達只損失一條通知，絕不損失一個回合。

### Continuation (sessions with memory)

兩個驅動都接受 `session`：此前返回的 `sessionId` 給該子代理另一個回合而不是
新建。子代理保留其會話——只傳送新任務即可。授權是持久化血緣關係
（`sessionmeta.parent`），因此只有子代理自己的父會話可以繼續它，每種失敗都
顯式拒絕：未知會話、根會話、外來的子代理、已關閉子代理和 store 不可達都返回
不同的錯誤，而不是靜默啟動全新子代理。

兩個驅動的區別正是其承諾的區別：

- `agent_run {session}` 承諾**現在**給結果，因此回合中的子代理被拒絕
  （`code: "busy"`，點名 `agent_spawn`/`agent_wait`/`agent_status`）；
- `agent_spawn {session}` 承諾工作**會發生**，因此它排隊——子代理的 runner
  序列化回合，下一個執行排隊的那個。

繼續是隻追加歷史：後續任務作為下一條使用者訊息持久化（無前言、無系統提示詞），
因此子代理的快取字首存活。每個回合推進子代理的啟用賬本
（`sessionmeta.activations`，附 `firstActivationAt`），後臺繼續在 `agentjob`
記錄上蓋 `continued`/`activation` 章。`close: true` 在回合後使子代理退場
（`sessionmeta.closed`）——記錄和記錄文字倖存；只有進一步繼續被拒絕。

### Delegation depth

`NIF_AGENT_MAX_DEPTH`（預設 **1**）限制委託可巢狀多深，在分發時透過遍歷
`sessionmeta.parent` 連結求值。`0` 完全禁止委託。到達上限時 spawn 工具仍然
可見：被拒絕的啟動返回點名限制和呼叫方深度的錯誤，讓模型知道原因。把它提到
1 以上是刻意行為——子代理的同步 `agent_run` 由 agent 元件可重入地服務
（見 WIRE.md "Delegation depth"），而來自子代理的 `agent_spawn` 完全不需要
重入（後臺作業從不持有 pump）。

### Fork (a child that has read the discussion)

`fork: true | {"lastK": n} | {"maxChars": n}`——僅用於**全新 spawn**（fork 是
出生，不是繼續；`fork` + `session` 被拒絕）——在子代理首次請求前用本會話
**已完成回合**播種其訊息日誌，讓子代理*讀過*討論而不是被告知。結果和
`session_info` 攜帶來源（`{source, uptoId, copied}`）。

- **切點是均衡且從 0 連續的**：只落在已完成回合邊界——絕不切進工具輪中途——
  種子是能重放為合法提供商訊息列表的最長記錄字首（每個 `tool_calls` 都有其
  tool 記錄應答，沒有孤兒 tool 記錄）。尾部在途回合被排除；崩潰留下的懸空中途
  歷史把 fork 截在那裡（fail-closed 勝過複製不均衡字首）。
- **預算按回合邊界切**，並且丟棄一切的選擇會 fail closed——空子代理看起來像
  成功，但那是錯的。
- **不復制什麼**：每條訊息的 `usage` 計量（子代理的賬目是自己的）、
  `summary`/`error` 角色記錄（summary 是所複製原始記錄的派生；error 記錄是
  父會話的審計）、工具集快照（`<session>:tools`），以及頭的控制欄位——fork 是
  出生：呼叫方的 `tools`/`maxRounds`/… 引數從此呼叫凍結子代理的控制，而絕不是
  父會話的。
- **出生即冷**：子代理的首次請求未快取地重放繼承的歷史；第二個回合起變暖。
  這是*判斷*繼承的代價，只有當前言否則不得不敘述上下文時才是正確取捨。不需要
  判斷的大批搬運正是 `fabric` 的用途。

- **治理而非沙箱**：guest 在 bash 的信任類——人類批准程式一次
  （`x-harness.approval: always`）。每個巢狀呼叫穿過會話巢狀呼叫代理
  （`svc.session.<id>.tool`），重新進入單一分發門（審批、完整 schema 校驗、
  截止時間）。執行器子程序不持有 NATS 連線，也沒有憑據。
- **審批清單**：程式審批顯示原始碼摘要、`var/approval-sources/<digest>.nim` 下的
  完整程式（許可權 0600）、選定的工具和宣告的預算。持久化自動批准按
  `fabric:<digest>` 鍵控——批准一個程式絕不覆蓋另一個。
- **守衛**：代理拒絕隱藏工具和內部/遞迴介面（`fabric`、`agent`、`chat`、
  `session`、`invoke`、`session_prepare`）；每回合租約使過期請求失效；
  `maxCalls` 約束呼叫；`x-harness.noSpawn` 在分發時拒絕來自子代理的子代理
  spawn。
- **上下文經濟**：中間結果絕不進入會話；過大的 `finish()` 值溢位到
  `var/fabric-artifacts/<run>.json`（許可權 0600），工具結果指向該路徑。
- **Guest API**：`import fabricguest` 提供結構化的
  `call(tool, JsonNode) -> JsonNode`、`batch`、`finish(JsonNode)`、`log`/`logg`、
  `stringArg`/`inputs`（外加遺留的 `callTool`/`j*` 字串輔助函式）。
  `fabricmeta.nim` 把釘住的執行時 schema 變成輸入型別化的包裝；結果除非工具
  宣告標量 `outputSchema`，否則是 `JsonNode`。`fabric_help` 工具從元件內部返回
  參考和示例原始碼，無需定位檔案。可工作示例：`components/fabric/examples/`。
- **何時用哪個**：判斷逐步進行的直接迴圈；機械的已知形態編排用 `fabric`；
  需要自己上下文的探索性子任務用 `agent_run`；混合程式可以呼叫 `agent_run`。

## Expert advisory peer (`expert`)

`expert` 元件是非互動的顧問同伴（設計：
[research/EXPERT.md](research/EXPERT.md)）。它併發跟隨一個或多個工作會話——
用 `expert_follow {session_id}` 顯式武裝（需審批，預設關閉）——把每個被跟隨
會話的 `ev.session.<id>.*` 事件看進一個有界的每會話記憶體當前回合幀，並詢問 LLM 裁判
（一次無狀態隱藏 `chat` 呼叫：固定快取穩定的知識字首 + 一條臨時觀察，無工具）
證據是否值得 steer。只有高置信度、點名活躍非隱藏工具的 steer 會被投遞，經
回合繫結的 `svc.session.<id>.advise` 請求/應答介面：runner 僅在該確切回合仍在
執行時接受建議——遲到的建議被拒絕（`stale-turn`/`no-active-turn`），絕不排進
下一回合。被接受的建議作為帶標記的使用者訊息折入
（`[Niffler advisor: expert] ...`），持久化，並在 `ev.session.<id>.advice` 上宣告。
裁判通道本身保持全域性：一次只有一條判斷在途、共享冷卻、每會話最新狀態合併。

| 工具 | 做什麼 |
|---|---|
| `expert_follow {session_id, model?, provider?}` | 跟隨一個會話（多目標：每個被跟隨會話保留自己的幀、知識字首、判斷預算和每跟隨指標）；重新跟隨會重置其幀。`model`/`provider` 為該跟隨覆蓋判斷呼叫。需審批。 |
| `expert_unfollow {session_id?}` | 帶 `session_id`：丟棄該跟隨。不帶：丟棄所有跟隨並扔掉它們的幀。 |
| `expert_reload` | 從實時目錄重建每個被跟隨會話的知識字首（新的快取紀元）。 |
| `expert_status {session_id?}` | 帶 `session_id`：該跟隨的幀、知識版本和每會話計數器（judgments、silences、steers、accepted、rejected、staleDrops、errors）。不帶：被跟隨目標加生命週期診斷。 |

設計不變數：工作會話絕不等待 expert（盡力而為、冷卻、最新狀態合併）；沒有增長
的 expert 記錄文字（每次判斷都是無狀態的）；fail closed（任何解析/校驗/傳輸
錯誤都是沉默）；expert 絕不行動——它只建議，需審批的工作仍留給工作會話的人類門。

## Recovery

倉庫是快照；`var/` 是可丟棄的建置輸出。如果 agent（或 bug）弄壞了出廠元件
——覆蓋了 `var/bin` 中的二進位、損壞了 spawned 元件記錄，或自加元件在引導時
崩潰——以 recover 模式啟動 Niffler：

```bash
make recover        # 先停掉一切，再 ./var/bin/niffler --recover
```

`--recover` 按順序做三件事：

1. **從原始碼重建出廠二進位**（`make build`，回退到 `nimble all`）——修復被覆蓋/
   損壞的 `var/bin/*`。
2. **清空 store 的元件記錄**——沒有遺留的持久化額外元件形態可供恢復。
3. 引導所請求的設定（通常是完整互動 harness；`--recover --minimal` 選擇
   minimal 設定）。**會話和訊息倖存**——只有元件形態被重置。

對於*原始碼*被破壞：

```bash
# 先停止 harness（關閉 UI，或 Ctrl-C ./var/bin/niffler）
git restore components/ core/ sdk/      # 或：git checkout -- .
make build
./var/bin/niffler                       # 或直接重開 UI
```

## The store

`store` 和其他元件一樣——匯流排上的文件儲存，帶 `put` / `get` / `list` / `del`
和基於 rev 的樂觀併發（`put` 接受 `expectRev`，不匹配時以 `rev-conflict`
失敗）。core 使用的 kind：

| Kind | Id | 值 |
|---|---|---|
| `conversation` | `conv-<ts>` | `{createdAt, model, title}` —— 會話頭（也攜帶凍結的系統提示詞、模型/thinking 選擇、每會話預算控制和 token 計量） |
| `message` | `<convId>:<seq>` | `{conversationId, role, content, ...}` |
| `component` | `<name>` | `{name, binary, policy, addedAt}` —— 引導時恢復的持久化形態 |
| `plugin` | `<pkg name>` | `{name, repo, ref, dir, version, components, addedAt}` —— `plugins` 元件的安裝記錄 |
| `provider` | nickname（外加 `active` 標記文件） | `provider` 元件的靜態脫敏 LLM 提供商登錄檔 |
| `session` | `<sessionId>:tools` | 會話凍結的直接工具集快照（見 [Progressive tool discovery](#progressive-tool-discovery)） |
| `slash` | `slash` | UI 渲染的合併斜槓命令表（見 [WIRE.md](WIRE.md)） |
| `agentjob` | `<jobId>` | 持久化後臺 `agent_spawn` 作業記錄（繼續會蓋 `continued`、`activation`，並排隊 `close`） |
| `agentnotice` | `<parentSession>:<seq>` | 子代理結算通知（摘要 + 完整回覆的追索；`deliveredAt`/`deliveredVia` 標記投遞） |
| `sessionmeta` | `<sessionId>` | 子代理血緣 / runner 後設資料：spawn 時 `{parent}`；繼續新增 `activations`（回合數，從 1 開始）和 `firstActivationAt`；`close: true` 退場設定 `closed` |
| `fabricprog` | 程式名 | 模型策展的 fabric 程式庫（`fabric {name}` 執行其中一個） |

後端是所選引擎——預設 SQLite 位於 `var/store.db`，或 `NIF_STORE_BACKEND=barrel`
時 BitBarrel 位於 `var/barrel-db`。**有且只有一個程序擁有該檔案**——絕不要對
同一資料庫執行兩個 `store` 程序（對同一根啟動第二個 core 就會如此；實驗請用
臨時 `NIF_ROOT` 副本）。

## Testing

```bash
make test           # 完整門：匯流排契約套件（桌面 UI 的前端測試與 typecheck
                    # 位於 gokr/niffler-ui）
make test-server    # ... 僅服務端：每個測試一個測試自有 NATS，不用 node
make test-bash      # ... 或只跑一個：test-store、test-builder、test-console、
                 # test-plugins、test-skills、test-fetch、test-models、
                 # test-observe、test-logfile、test-core、test-cli、
                 # test-autostart、test-smoke
```

每個測試都引導真實元件二進位（Nim、Go *和* TypeScript——信封才是產物，所以
一個 harness 測試每個 SDK）並透過其 loopback 埠由 NATS 分配的私有 NATS 伺服器
驅動它們。桌面 UI 的前端測試不在本套件內：UI 現在是
[gokr/niffler-ui](https://github.com/gokr/niffler-ui) 外掛，其 lib 單元測試和
typecheck 在該倉庫執行（那裡的 `make test` / `make typecheck`），因此本門檻
保持自包含。
基於 core 的測試把所需二進位快照進唯一臨時 `NIF_ROOT`；Barrel、外掛 clone、
生成元件、日誌和快取因此都被隔離。單獨的 `make test-*` 目標可以彼此以及與執行中
的開發 harness 併發執行。倉庫建置寫入被序列化，而 agent 建置的測試元件使用
沙箱本機 Nim 快取。網路可選項：`NIF_TEST_INSTALL=1` 執行真實的
`cli install gokr/niffler-weather` + 工具驗證；`NIF_TEST_NETWORK=1` 執行針對
GitHub 的 `plugin_search`、針對 skills.sh 的 `skill_search`，以及 TypeScript
builder 建置（npm registry）。安裝管線本身由 `t_plugins` 經本機 `file://` git
倉庫封閉覆蓋。Observe/logfile 測試使用臨時輸出目錄，絕不刪除開發者的
`var/logs` 或 `var/captures`。外部網路可選項即使本機狀態隔離，仍可能共享提供商
速率限制。

## Starting and stopping

沒有啟動器指令碼——二進位自己擁有生命週期：

- **桌面圖示 / `niffler-ui`** —— 常見情況。bridge 的第一件事是 SDK 的
  `ensureHarness`：探測 `NIF_NATS_URL` → `var/nats-url` → 127.0.0.1:4222，尋找
  服務**本 root** 的 core（目錄攜帶所屬 harness 的 root；外來 clone 的 core
  絕不被採納）；無人應答時，以 `NIF_AUTOSTART=1` 分離啟動 `var/bin/niffler`。
  二進位本身由 `make install-ui` 安裝——桌面 UI 是
  [gokr/niffler-ui](https://github.com/gokr/niffler-ui) 外掛，由 builder 建置
  進 `var/bin/niffler-ui`，再由 `make install` 連結到 PATH。
- **互動外掛**（例如 `niffler-tui`）——它們**不**呼叫 `ensureHarness`，絕不
  啟動 harness：它們探測實時匯流排（`NIF_NATS_URL` → `var/nats-url` →
  127.0.0.1:4222），連線並註冊 `client: true`（這樣 autostarted core 在它們
  執行期間保持存活）。先啟動 harness——桌面 UI 或 `./var/bin/niffler`。
- **終端管理 shell** —— 直接 `./var/bin/niffler`，或
  `./var/bin/niffler --minimal` 用三元件引導設定。手動啟動的 core 絕不自行
  終止；用 Ctrl-C / SIGTERM 停止它。

互動前端註冊 `"client": true`（SDK 的 `interactive()` / `Component.Client`
標記）。**Autostarted** core 會數它們：最後一個離開後，它會在
`NIF_AUTOSTART_IDLE_S`（預設 10s——重啟的 UI 在該視窗內重新註冊）後關閉，
帶走其元件和 spawned 匯流排；若從未有客戶端到達，它在 `NIF_AUTOSTART_BOOT_S`
（預設 60s）後放棄。關閉附著到*手動*啟動 core 的 UI 不改變任何東西——core
保持執行。`NIF_ENSURE_ATTACH=0` 讓 `ensureHarness` 無條件啟動（測試）。

## Common tasks

```bash
./var/bin/niffler             # 終端中的完整 harness（管理 shell）
./var/bin/niffler --minimal   # 引導時只要 store + bash + llm
niffler-ui                    # 桌面 UI；autostart 完整設定
make build          # 重建發生變化的部分
make install        # PATH 條目（niffler、niffler-cli、niffler-console，
                    # + 外掛二進位存在時的 niffler-ui，以及按需安裝的
                    # niffler-tui 包裝指令碼——絕不含元件二進位，因此 PATH
                    # 不會遮蔽 grep/git/...）
make install-tui    # 同上，安靜地安裝 niffler-tui 終端客戶端
                    # (= make install WITH_TUI=1)
make uninstall      # 再次移除這些 PATH 條目
make install-ui     # 安裝桌面 UI 外掛（gokr/niffler-ui）：啟動一個隔離的
                    # 自動審批 harness，外掛管理器 clone、builder 建置進
                    # var/bin/niffler-ui
make install-lsp    # 安裝 lsp 元件的預設語言伺服器
make test           # 完整門：匯流排契約套件（UI 倉庫的前端測試位於
                    # gokr/niffler-ui）
make test-server    # 僅匯流排契約套件（每個測試擁有自己的私有匯流排）
make doctor         # 檢查前置條件
make ram            # 執行中各棧的 RAM（harness + 元件 + nats + 客戶端）
make down-here      # 只停掉此 checkout 的 harness、元件和 spawned 匯流排
                    # ——bench worktree 和其他 clone 倖存
make clean          # 刪除所有建置產物（var/、nimcache/）
```

- **無頭服務模式**（無 tty，供 UI/自動化）：
  `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null`——
  服務 `svc.core.call`；需要審批的工具會被拒絕，除非有 UI 附著或設定了
  `NIF_AUTO_APPROVE=1`。
- **附著到任何匯流排**：`NIF_NATS_URL=nats://host:4222`（甚至遠端），或先自行在
  預設埠啟動 nats-server——core 複用 `127.0.0.1:4222` 上的實時匯流排，只在無人
  應答時啟動自己的（建置出的 `var/bin/nats-server` 元件）。
- **不用 LLM 探測匯流排**：`tests/` 中的一次性 `nim c -r` 指令碼
  （見 AGENTS.md "Debugging the bus"）。
- **Wails**：桌面 UI（以及任何 Wails 用戶端套件）透過其套件配方建置，
  配方必須執行 `wails build -tags webkit2_41`（Linux）——裸 `go build` 會產出
  樁。UI 的 SPA 開發伺服器位於 gokr/niffler-ui checkout（在那裡 `make dev`）。
- **監控 RAM**：用 `make ram`（或 `watch -n5 scripts/niffler-ram.sh`）：按棧
  統計——你的 clone、`nifflerprod` 和每個 bench 私有 harness 分開——harness +
  NATS + 所有 spawned 元件 + session runner + 客戶端。成員按可執行檔案路徑
  （`*/var/bin/*`、`niffler-ui`）判定，而不是程序樹：tui 是 autostarted harness
  的*父*程序，而 bench 執行的私有匯流排屬於 bench 驅動，因此 PPID 遍歷會兩者都
  漏掉。讀 PSS，不是 RSS：共享同一 `var/bin` 建置的棧會在 RSS 中重複計算檔案
  支撐頁。`bash` 工具的工作負載子程序（編譯器、測試二進位）按設計排除。

## Troubleshooting

| 症狀 | 原因 / 修復 |
|---|---|
| 桌面應用內 UI 顯示 "Running in a browser" | `nats.ts` 繫結不匹配——`window.go.main.Bridge` 必須匹配 Go 結構體名（ui/README.md） |
| UI 橫幅：bus unreachable | core autostart 仍在進行或失敗——在終端啟動 `./var/bin/niffler` 檢視引導錯誤 |
| 引導時 `core: WARNING missing binary for <name>` | 執行 `make build` |
| llm error HTTP 401/403 | `NIF_OPENAI_API_KEY` 缺失或錯誤——檢查 `.env` 和 shell 環境 |
| 無頭模式下 "approval denied" | 預期行為：沒有可達的人類。附著 UI，用 `make run`，或有意識地設定 `NIF_AUTO_APPROVE=1` |
| 兩個 store 爭搶同一資料檔案（`var/store.db` 或 `var/barrel-db`） | 單寫者規則——每個 root 只有一個 core；在臨時 `NIF_ROOT` 副本中實驗 |
| 引導拒絕："this harness has conversation history in var/barrel-db" | 預設引擎改為 SQLite 而你的歷史仍在 barrel——執行 `niffler-store-migrate --root <path>`（錯誤會列印它），或設定 `NIF_STORE_BACKEND=barrel` 繼續用舊引擎 |
| 孤立的 `nats-server` | 只有其 core 被 SIGKILL（退出 defer 被跳過）時才可能——殺掉 `var/nats-pid` 中的 pid，否則 `pkill -f nats-server` |
| 元件引導時崩潰、在退避迴圈中重啟 | 經 UI/終端 `core.remove` 它，或 `make recover` |
| agent 改動了原始碼 | `git restore components/ core/ sdk/` 然後 `make build`（見 Recovery） |
