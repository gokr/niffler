# Niffler

[English](README.md) · [简体中文](README.zh.md) · 繁體中文 ·
[網站](https://gokr.github.io/niffler/) · [Discord](https://discord.gg/ThJFEAJUAk)

> 🤖 AI 自動翻譯，可能與英文版存在偏差；以 [English](README.md) 為準。
> 章節標題保留英文，以便跨文檔錨點保持有效。

Niffler 是一個極簡、可自我擴充的 agent harness。核心與每項能力都是獨立
程序，透過 NATS 上的 JSON 信封通訊。Agent 可以在對話進行期間編譯並啟動
新的元件。專案應從自己的 clone 執行，該 clone 是實例的 home。

## Why Niffler

- **模組化到行程邊界。** 就像 Pi 和 DeepSeek Harness，但再低一層：每個能力都是自己的 OS 行程，位於單一線路協定之後（透過 NATS 傳遞 JSON 封套），而代理會在對話中途建置、生成與移除元件——不需拆除程式碼，也不會有洩漏的子行程。請參閱 [ARCHITECTURE.md](docs/ARCHITECTURE.md)。
- **電池內含。** `fabric`（可程式化的工具呼叫）、`agent`/`expert`（子代理與諮詢同儕）、`git`、`mcp`、`lsp`、`repomap`（Aider 的 tree-sitter + PageRank 移植）、`skills`、`plugins`、`processes`、`observe`/`logfile`——這些是其他 harness 留給外掛的工作。請參閱[隨附元件](docs/MANUAL.md#shipped-components)。
- **實驗性功能維持可選加入。** `jev`（基於本機決策模型的建議式探索）以惰性的隨需顧問形式隨附於 manifest，其執行時是你用 spawn 記錄啟用的受監督啟動器——`make build`/`make setup` 絕不被強加重量級相依。請參閱[建議式探索](docs/MANUAL.md#advisory-discovery-jev-and-the-von-launcher)。
- **開放模型，所有供應商。** 任何 OpenAI 相容端點——本機、開放權重或代管——透過 `.env` 或由儲存支援的供應商登錄檔；ChatGPT/Claude 訂閱 OAuth 以及由 models.dev 支援的目錄。請參閱[供應商](docs/MANUAL.md#provider-registry-provider)與[模型目錄](docs/MANUAL.md#model-catalog-models)。
- **漸進式工具揭露。** 一組小型、凍結的直接工具集；其他一切只需一次 `discover`/`invoke`，以歷史形式附加，而非提示詞膨脹。請參閱 [MANUAL](docs/MANUAL.md#progressive-tool-discovery)。
- **人類保持在迴圈中。** 需核准的工具，附帶 manifest 摘要與每個會話的 `ask`/`auto` 模式；在無法觸及人類時，呼叫會被拒絕，絕不會默默允許。請參閱[核准](docs/MANUAL.md#approvals)。
- **多語言。** 主要是 Nim 和 Go，但沒有元件被綁定到特定語言：Nim、Go 和 TypeScript 的 SDK，以及一個完全沒有 SDK 的隨附 bash 示範。請參閱 [ARCHITECTURE.md](docs/ARCHITECTURE.md)。
- **匯流排就是 API。** `niffler-tui`、桌面 UI、`cli` 和 `console` 是平等的匯流排用戶端；數個可以同時連接，且各自獨立建置與安裝（TUI 是自己的外掛）。請參閱[啟動與停止](docs/MANUAL.md#starting-and-stopping)。
- **為長時間執行而打造。** 凍結的提示詞/工具前綴讓提示詞快取保持溫熱；耐久的壓縮與有界的溢位復原讓會話保持存活；軟性 `/limit` 預算與硬性失控防護並存。請參閱[上下文視窗](docs/MANUAL.md#context-window)。
- **本機優先，複製即實例。** 對話與元件狀態位於 `var/`（預設為 SQLite），且 harness 執行自己的 NATS 匯流排，沒有中央服務。請參閱[佈局](docs/MANUAL.md#layout-of-a-running-system)。

目前版本是 [v0.3.0](https://github.com/gokr/niffler/releases/tag/v0.3.0)。請參閱 [CHANGELOG.md](CHANGELOG.md) 了解該版本以來的變更。

## Quick start

需求：Nim 2.2.12+ 與 Go。`make setup` 會安裝這些以及其他平台先決條件（Ubuntu/macOS）加上 Nimble 相依項目。Node.js 20+ 與 npm 僅在 TypeScript 元件時需要。Niffler 使用純 Nim 的 [natsnim](https://github.com/gokr/natsnim) 用戶端；不需要安裝 `libnats` 或 `cnats`。

```bash
git clone https://github.com/gokr/niffler.git
cd niffler
make setup                    # Ubuntu/macOS prerequisites and Nimble deps
cp .env.example .env          # add an LLM API key; edit other settings as needed
make build                    # core + components (no UI toolchain)
make install-tui              # PATH entries + the niffler-tui terminal client
niffler-tui                   # terminal chat; boots this clone's harness
```

`make install-tui` 就是 `make install WITH_TUI=1`：它會將 `niffler`、`niffler-cli`、`niffler-console` 以及 `niffler-tui` 包裝程式連結到使用者 bin 目錄（`NIF_BIN_DIR=~/bin` 可覆寫位置），並安裝 [niffler-tui](https://github.com/gokr/niffler-tui) 外掛。單純的 `make install` 會在終端機上詢問外掛事宜。

`niffler-tui` 是對話用戶端；`niffler`（或 `./var/bin/niffler`）是終端機管理殼層——狀態、目錄、會話，不是聊天 UI——而 `niffler --minimal` 只啟動最小化的 store/bash/LLM 設定檔。

存在一個以 Wails 為基礎的桌面 UI，但它是位於獨立儲存庫中的**實驗性副專案**——[gokr/niffler-ui](https://github.com/gokr/niffler-ui)。它目前無人維護，也落後於 `niffler-tui`，因此本 harness 既不建置、也不安裝、也不測試它（`make install-ui` 已移除；若想把玩，仍可用 `cli install gokr/niffler-ui` 以套件方式取得）。

`make doctor` 會檢查先決條件；`make down-here` 只會停止此複本的行程。

測試：`make test` 執行匯流排合約測試套件（每個測試一個私有匯流排）；`make gotest` 執行 Go 測試、vet 與競態檢查。

## Commands

以下都是 `make` 目標（Makefile 是入口）；桌面 UI 已是獨立外掛
（`gokr/niffler-ui`），其自身的建置目標在那個倉庫裡。

| 命令 | 作用 |
|---|---|
| `make setup` | 安裝平台依賴（Ubuntu/macOS）和 Nimble 依賴套件 |
| `make build` | core + 全部元件建置到 `var/bin`（不含 UI 工具鏈） |
| `make all` | `build`（預設目標；桌面 UI 已是獨立外掛） |
| `make run` | 建置後啟動 `./var/bin/niffler`（終端管理 shell） |
| `make install` | 安裝 `niffler`、`niffler-cli`、`niffler-console` 的 PATH 項目（終端上會詢問是否安裝 TUI） |
| `make install-tui` | `make install WITH_TUI=1`：上面的全部，外加 `niffler-tui` 聊天用戶端 |
| `make install-lsp` | 安裝 `lsp` 元件的預設語言伺服器 |
| `make test` | 完整測試門：匯流排契約測試套件（UI 自身的測試與型別檢查在 `gokr/niffler-ui`） |
| `make test-server` | 匯流排契約測試套件（每個測試自建私有 NATS + `NIF_ROOT`） |
| `make test-<name>` | 單一元件的契約測試，例如 `make test-fetch` |
| `make gotest` | Go 單元測試與 vet（重要模組帶 `-race`） |
| `make clean` | 清除建置產物（不要手工 `rm -rf var`） |
| `make down` | 停止機器上散落的 harness、元件和匯流排程序 |
| `make down-here` | 同上，但只限本 checkout（bench worktree 和其他 clone 不受影響） |
| `make recover` | 全部停止、重新建置、清理已 spawn 的元件記錄、重新啟動 |
| `make doctor` | 檢查依賴並回報缺失項 |
| `make uninstall` | 移除已安裝的 PATH 項目 |
| `make ram` | 回報執行中 stack（harness、元件、匯流排、客戶端）的記憶體用量 |
| `make install-jev` | 安裝 `jev` 顧問背後的 Von 執行環境（可選，約 5.4 GB） |
| `make smoke` | 遺留的一次性端對端腳本（優先用 `make test`） |

### Chat commands (web UI and `niffler-tui`)

在輸入框裡敲 `/` — `Tab` 補全。`/help` 會即時列印下面這份清單，帶每個命令的
參數和下一節的全部按鍵。內建命令：`/components`、`/discover`、`/profile`、
`/provider`、`/model`、`/effort`、`/approvals`、`/limit`、`/compact`、
`/connect`、`/status`、`/new`、`/session`、`/think`、`/tools`、`/locale`、
`/info` 和 `/help`；已安裝外掛貢獻的命令會由 `/help` 列在獨立標題下。

### Admin shell (`niffler`)

`niffler` 不是聊天 UI：它提供 `help`、`status`、`catalog`、`tools`、
`sessions`、`exit`/`quit`（或 `Ctrl-D`）。對話在 `niffler-tui` 和桌面 UI 裡，
腳本化操作走 `niffler-cli`（`catalog` / `wait` / `call` / `install`）。

## Keyboard shortcuts

Web UI（桌面應用和瀏覽器）：

| 按鍵 | 位置 | 作用 |
|---|---|---|
| `Enter` / `Esc` | 輸入框 | 送訊（補全彈窗開啟時 `Esc` 先關閉它） |
| `Shift+Enter` | 輸入框 | 換行而不送訊 |
| `↑` / `↓` | 輸入框 | 瀏覽命令歷史，未送出的草稿會保留 |
| `Tab` / `Shift+Tab` | 輸入框中的 `/…` | 開啟斜線補全 / 在候選項間循環 |
| `Enter` / `Esc` | 補全彈窗 | 接受反白命令 / 關閉彈窗 |
| `Ctrl+T` | 全域 | 循環切換推理顯示：full → brief → off |
| `Ctrl+E` | 全域 | 循環切換工具卡片：brief → full → off |
| `Ctrl+G` | 全域 | 循環切換思考強度 |
| `Enter` / `Esc` | 審核提示 | 核准 / 拒絕被門控的工具呼叫 |

管理 shell 跟隨終端：`↑`/`↓` 行歷史、`Tab` 補全、`Ctrl-D`（或 `exit`/`quit`）
離開、`Ctrl-C` 中斷。`niffler-tui` 保持同樣的 `Ctrl+T` / `Ctrl+E` / `Ctrl+G`
顯示循環。

## 文件

- [手冊](docs/MANUAL.md) — 安裝細節、設定、工具、供應商、UI、復原、測試與疑難排解（另有[简体中文](docs/MANUAL.zh.md) · [繁體中文](docs/MANUAL.zh-TW.md)）。
- [線路協定](docs/WIRE.md) — JSON 封套、主體、錯誤、取消與會話上下文。
- [架構](docs/ARCHITECTURE.md) — 為何核心、元件與 NATS 是分開的，以及貢獻者必須保留的不變條件。
- [開放工作](docs/PLAN.md) — 目前延後的工作。
- [研究索引](docs/research/README.md) — 設計歷史與先前技術研究；研究筆記不是操作指示。
- [Fabric 指南](docs/FABRIC_GUIDE.md) — 可程式化協調與子代理。
- [模型來源外掛](docs/MODEL_SOURCES.md) — 目錄修正元件的實作範例。
- [設定設計](docs/research/SETTINGS.md) — 尚未隨附的設定工作。

## Developing components

Nim、Go 與 TypeScript 元件使用 `sdk/` 中的 SDK。正常的擴充路徑是：撰寫原始碼、呼叫 `build`，然後呼叫 `spawn`。在變更架構或新增元件之前，請閱讀[元件生命週期](docs/MANUAL.md#self-extension-and-component-lifecycle)、[線路合約](docs/WIRE.md)與 [AGENTS.md](AGENTS.md)。

社群元件透過 `plugins` 元件安裝；請參閱[手冊的外掛章節](docs/MANUAL.md#component-ecosystem-plugins)。

## Philosophies

- **開放模型，所有供應商。** 本機、開放權重與代管模型獲得相同的一流路徑：OpenAI 相容的預設、在供應商不提供其他選擇時的訂閱 OAuth，以及由 models.dev 支援、將限制、能力與價格視為資料的目錄。新增 OpenAI 相容供應商是設定項目，而非程式碼路徑。
- **改進是被測量的，而非被斷言的。** `bench/` 在相同任務與模型上讓 Niffler 對上 pi、opencode、CodeWhale 與 Claude Code，在 full31、SWE-bench Verified 與 DeepSWE 套件中比較達到綠燈的時間、token 成本與修補品質。功能以該證據為依據上線——有時也附帶閘門，例如 repo map 的自動附加，預設開啟，但會扣下過小或空殼的 map，因為 A/B 測試結果不一致——報告則提交於 `bench/reports/` 之下。
- **中文在這裡是一流語言。** README 有英文、簡體中文與繁體中文，且網頁 UI 完全在地化（`en`/`zh`/`zh-TW`），附帶具型別的目錄——缺少翻譯會導致型別檢查失敗。
- **帶著驕傲與感激地借鏡。** 我們從其他 harness 中汲取能找到的最佳想法——Pi、DeepSeek Harness、CodeWhale、OpenCode、Reasonix、Aider、OpenHands……——並在隨附前逐一對照 Niffler 的不變條件重新檢查。這些研究會標明其來源與鎖定的 commit，內嵌的程式碼保留其授權，且一切都在 [docs/research/](docs/research/) 中。
