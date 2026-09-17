# Niffler

[English](README.md) · [简体中文](README.zh.md) · 繁體中文 ·
[網站](https://gokr.github.io/niffler/) · [Discord](https://discord.gg/ThJFEAJUAk)

Niffler 是一個極簡、可自我擴充的 agent harness。核心與每項能力都是獨立
程序，透過 NATS 上的 JSON 信封通訊。Agent 可以在對話進行期間編譯並啟動
新的元件。專案應從自己的 clone 執行，該 clone 是實例的 home。

## 為什麼選擇 Niffler

- **模組化與可擴充性直達程序邊界。** Niffler 與 [Pi](https://pi.dev) 和
  [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 一樣
  追求精簡的 harness 理念，但更進一步：每項能力都是獨立的作業系統程序，
  透過統一的 wire 協議（NATS 上的 JSON 信封）通訊，而不是程序內外掛。
  Agent 可以在對話進行中撰寫、編譯並啟動新元件，執行時替換實作，用
  `core.kill` 移除元件——無需清理程式碼，也不會留下孤兒程序。
- **更多「開箱即用」能力。** 內建元件涵蓋了其他 harness 交給第三方外掛的
  功能：`fabric`（模型用 Nim 程式編排工具）、`agent`/`expert`（子代理與
  顧問）、`git`、`mcp`（外部 MCP 伺服器）、`lsp`（任意語言伺服器，以資料
  設定）、`skills`、`plugins`、`repomap`、`processes`（背景工作）、
  `fetch`、`grep`、`edit`，以及觀測匯流排的 `observe`/`logfile` 和 LLM
  存取的 `models`/`provider`。
- **聚焦開源模型。** 只有一套適配器，沒有廠商鎖定：預設的 `openai-chat`
  協議使用標準 Chat Completions，任何 OpenAI 相容端點都能接入——DeepSeek、
  OpenRouter、本地 vLLM/llama.cpp/Ollama——透過 `.env` 或由 store 持久化的
  `provider` 註冊表設定，並可在執行時切換。需要託管模型時，也支援
  Anthropic Messages 以及 ChatGPT/Claude 訂閱 OAuth。
- **語言無關的架構。** 提供 Nim、Go 和 TypeScript SDK；為某語言加入支援
  只需一筆設定或一個外掛元件，無需修改共用元件。
- **匯流排就是 API。** 所有客戶端——`niffler-tui` 終端客戶端、Web UI、
  `niffler-cli` 腳本和 CI、`niffler-console`——都只是匯流排上的普通成員：
  任何能收發 JSON 信封的程式都可以觀察、腳本化或驅動對話。
- **UI 只是匯流排客戶端。** 客戶端本身不保存對話狀態，因此可以多個同時連線
  同一個 harness——終端客戶端、桌面應用、你自己的腳本——而且每個 UI 都獨立
  建置、獨立安裝。桌面 UI 隨本儲存庫發布（`make install-ui`）；終端客戶端
  則是獨立儲存庫中的外掛
  （[gokr/niffler-tui](https://github.com/gokr/niffler-tui)，用
  `make install-tui` 安裝）——這正好證明 UI 只是另一個元件。
- **預設遵守快取與成本紀律。** 對話的系統提示詞和直接工具 schema 在建立時
  凍結，歷史只會追加，因此 provider 的 prompt cache 能持續命中；大型工具集
  透過 `discover`/`invoke` 隨需取得，不會讓每次請求都膨脹。
- **本地優先，clone 即實例。** clone 就是實例：對話和元件狀態保存在
  `var/`（預設 SQLite），harness 自行管理 NATS 匯流排，不依賴任何中央
  服務。

目前版本是 [v0.2.0](https://github.com/gokr/niffler/releases/tag/v0.2.0)，
變更記錄見 [CHANGELOG.md](CHANGELOG.md)。完整操作說明請參閱
[docs/MANUAL.md](docs/MANUAL.md)。

## 快速開始

需要 Nim 2.2.12+ 和 Go；`make setup` 會安裝平台依賴（Ubuntu/macOS）和
Nimble 依賴。只有 TypeScript 元件和 Web UI 需要 Node.js 20+ 和 npm；可選的
桌面 UI 在 Linux 上還需要 Wails 和 WebKitGTK 4.1。Niffler 使用純 Nim 的
[natsnim](https://github.com/gokr/natsnim)，不需要安裝 `libnats` 或 `cnats`。

```bash
git clone https://github.com/gokr/niffler.git
cd niffler
make setup                    # Ubuntu/macOS 依賴和 Nimble 套件
cp .env.example .env          # 填入 LLM API key
make build                    # 建置核心和元件（不含 UI 工具鏈）
make install-tui              # 寫入 PATH 並安裝 niffler-tui 終端客戶端
niffler-tui                   # 終端聊天，視需要啟動此 clone 的 harness
```

`make install-tui` 等同於 `make install WITH_TUI=1`：把 `niffler`、
`niffler-cli`、`niffler-console` 和 `niffler-tui` 包裝腳本連結到使用者 bin
目錄（可用 `NIF_BIN_DIR=~/bin` 指定），並安裝
[niffler-tui](https://github.com/gokr/niffler-tui) 外掛。直接執行
`make install` 則會在終端詢問是否安裝該外掛。

`niffler-tui` 是對話客戶端；`niffler`（或 `./var/bin/niffler`）是終端管理
shell——status、catalog、sessions，不是對話 UI；`niffler --minimal` 只啟動
最小的 store/bash/LLM 組態。

桌面 UI 是可選項：

```bash
make install-ui         # 建置 Wails UI，複製到 ~/.local/bin，並安裝
                        # 啟動器項目和圖示（Linux；別名 make ui-install）
```

開發時可用 `make dev` 在瀏覽器執行前端（bridge 以樁實作）。`make doctor`
檢查依賴，`make down-here` 只停止此 clone 的程序。

測試：`make test-ui`（前端，無需 NATS）、`make test-server`（匯流排契約）、
`make test`（完整測試門）、`make gotest`（Go 測試、vet 和 race 檢查）。

## 文件

- [操作手冊](docs/MANUAL.md) — 安裝、設定、工具、Provider、UI、復原、測試和排錯。
- [Wire 協議](docs/WIRE.md) — JSON 信封、subject、錯誤、取消和 session context。
- [架構](docs/ARCHITECTURE.md) — core、元件和 NATS 的邊界及貢獻者須遵守的約束。
- [目前計畫](docs/PLAN.md) — 尚未完成的工作。
- [研究索引](docs/research/README.md) — 設計歷史和先例研究，不是操作手冊。
- [Fabric 指南](docs/FABRIC_GUIDE.md) — 可程式化編排和 subagent。
- [設定設計](docs/SETTINGS.md) — 尚未發布的設定方案。

## 開發元件

Nim、Go 和 TypeScript 元件使用 `sdk/` 中的 SDK。正常擴充流程是：寫原始碼，呼叫
`builder.build`，再呼叫 `core.spawn`。修改架構前請閱讀
[AGENTS.md](AGENTS.md)、[元件生命週期](docs/MANUAL.md#self-extension-and-component-lifecycle)
和 [WIRE.md](docs/WIRE.md)。社群元件透過 `plugins` 安裝，詳見
[手冊中的插件章節](docs/MANUAL.md#component-ecosystem-plugins)。
