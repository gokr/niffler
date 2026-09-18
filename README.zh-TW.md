# Niffler

[English](README.md) · [简体中文](README.zh.md) · 繁體中文 ·
[網站](https://gokr.github.io/niffler/) · [Discord](https://discord.gg/ThJFEAJUAk)

> 🤖 AI 自動翻譯，可能落後於英文版；以 [English](README.md) 為準。

Niffler 是一個極簡、可自我擴充的 agent harness。核心與每項能力都是獨立
程序，透過 NATS 上的 JSON 信封通訊。Agent 可以在對話進行期間編譯並啟動
新的元件。專案應從自己的 clone 執行，該 clone 是實例的 home。

## 為什麼選擇 Niffler

- **模組化直達程序邊界。** 像 Pi 和 DeepSeek Harness，但更深入一層：每項能力
  都是獨立的作業系統程序，透過統一的 wire 協議（NATS 上的 JSON 信封）通訊；
  Agent 可以在對話中編譯、啟動和移除元件，無需清理程式碼，也不會留下孤兒
  程序。見 [ARCHITECTURE.md](docs/ARCHITECTURE.md)。
- **開箱即用。** `fabric`（可程式化工具編排）、`agent`/`expert`（子代理與
  顧問）、`git`、`mcp`、`lsp`、`repomap`（Aider 的 tree-sitter + PageRank
  移植）、`skills`、`plugins`、`processes`、`observe`/`logfile`——其他 harness
  通常交給第三方外掛的功能。見[內建元件](docs/MANUAL.md#shipped-components)。
- **開放模型，所有 Provider。** 任何 OpenAI 相容端點——本機、開放權重或
  託管——透過 `.env` 或 store 持久化的 Provider 註冊表接入；也支援
  ChatGPT/Claude 訂閱 OAuth 和 models.dev 模型目錄。見
  [Provider](docs/MANUAL.md#provider-registry-provider) 和
  [模型目錄](docs/MANUAL.md#model-catalog-models)。
- **工具漸進揭露。** 每個對話只有一個小而凍結的直接工具集，其餘工具都在
  `discover`/`invoke` 一步之內，作為歷史追加而不是提示詞膨脹。見
  [手冊](docs/MANUAL.md#progressive-tool-discovery)。
- **人在迴路中。** 工具可要求審批，帶 manifest 摘要和每對話的 `ask`/`auto`
  門控模式；無人可達時直接拒絕，絕不悄悄放行。見
  [審批](docs/MANUAL.md#approvals)。
- **多語言。** 主體是 Nim 和 Go，但架構不綁定任何語言：提供 Nim、Go 和
  TypeScript SDK，還有一個不用 SDK 的 bash 範例。見
  [ARCHITECTURE.md](docs/ARCHITECTURE.md)。
- **匯流排就是 API。** `niffler-tui`、桌面 UI、`cli` 和 `console` 都是平等的
  匯流排客戶端；可以同時連接多個，各自獨立建置和安裝（TUI 本身就是外掛）。見
  [啟動與停止](docs/MANUAL.md#starting-and-stopping)。
- **為長時間執行而設計。** 凍結的提示詞/工具前綴讓 provider 快取持續命中；
  持久化壓縮和有界溢位復原讓對話不中斷；軟性 `/limit` 預算之外還有硬性失控
  保護。見[上下文視窗](docs/MANUAL.md#context-window)。
- **本機優先，clone 即實例。** 對話和元件狀態保存在 `var/`（預設 SQLite），
  harness 自行執行 NATS 匯流排，不依賴中心服務。見
  [佈局](docs/MANUAL.md#layout-of-a-running-system)。

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
- [目前計畫](docs/research/PLAN.md) — 尚未完成的工作。
- [研究索引](docs/research/README.md) — 設計歷史和先例研究，不是操作手冊。
- [Fabric 指南](docs/FABRIC_GUIDE.md) — 可程式化編排和 subagent。
- [模型來源外掛](docs/MODEL_SOURCES.md) — 修正模型目錄的元件範例。
- [設定設計](docs/research/SETTINGS.md) — 尚未發布的設定方案。

## 開發元件

Nim、Go 和 TypeScript 元件使用 `sdk/` 中的 SDK。正常擴充流程是：寫原始碼，呼叫
`build`，再呼叫 `spawn`。修改架構前請閱讀
[AGENTS.md](AGENTS.md)、[元件生命週期](docs/MANUAL.md#self-extension-and-component-lifecycle)
和 [WIRE.md](docs/WIRE.md)。社群元件透過 `plugins` 安裝，詳見
[手冊中的外掛章節](docs/MANUAL.md#component-ecosystem-plugins)。

## 專案理念

- **開放模型，所有 Provider。** 本地、開放權重和託管模型走同一條一等路徑：
  預設使用 OpenAI 相容協議，廠商只提供訂閱登入時用 OAuth，模型中介資料由
  models.dev 目錄提供；限額、能力和價格都是資料。加入一個 OpenAI 相容的
  Provider 只需一筆設定，而不是一段程式碼。
- **改進靠度量，不靠口號。** `bench/` 用相同的任務和模型，把 Niffler 與
  pi、opencode、CodeWhale、Claude Code 放在一起比較達標時間、token 成本和
  補丁品質（full30、SWE-bench Verified、DeepSWE 任務）。功能要有證據才
  落地——有時也要靠證據才能保持關閉，例如 repo map 的自動注入就因 A/B 結果
  不一致而預設關閉——報告提交在 `bench/reports/`。
- **中文是我們的一等語言。** README 提供英文、簡體中文和繁體中文，Web UI
  完整本地化（`en`/`zh`/`zh-TW`），字典是強型別的——漏譯會讓型別檢查失敗。
- **帶著自豪與感激地「偷」。** 我們從能找到的最好的 harness 中吸收想法——
  Pi、DeepSeek Harness、CodeWhale、OpenCode、Reasonix、Aider、OpenHands
  等等——再逐條對照 Niffler 的設計約束；研究文件會標註來源和固定的提交，
  內建的第三方程式碼保留其授權條款，全部記錄在
  [docs/research/](docs/research/)。
