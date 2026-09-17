# Niffler

[English](README.md) · [简体中文](README.zh.md) · 繁體中文 ·
[網站](https://gokr.github.io/niffler/) · [Discord](https://discord.gg/ThJFEAJUAk)

Niffler 是一個極簡、可自我擴充的 agent harness。核心與每項能力都是獨立
程序，透過 NATS 上的 JSON 信封通訊。Agent 可以在對話進行期間編譯並啟動
新的元件。專案應從自己的 clone 執行，該 clone 是實例的 home。

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
