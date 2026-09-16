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

需要 Nim 2.2.12+、Go、Node.js 20+ 和 npm。桌面 UI 還需要 Wails；Linux
需要 WebKitGTK 4.1。Niffler 使用純 Nim 的
[natsnim](https://github.com/gokr/natsnim)，不需要安裝 `libnats` 或 `cnats`。

```bash
git clone https://github.com/gokr/niffler.git
cd niffler
make setup
cp .env.example .env       # 填入 LLM API key
make                       # 建置核心、元件和桌面 UI
./ui/build/bin/niffler-ui  # 啟動 UI，同時啟動本地 harness
```

只建置核心和元件使用 `make build`。`./var/bin/niffler` 是終端管理 shell，
不是對話 UI；`./var/bin/niffler --minimal` 只啟動 store、bash 和 LLM。
`make doctor` 檢查依賴，`make down-here` 只停止此 clone 的程序。

開發時可用 `make dev` 在瀏覽器執行前端。測試命令：`make test-ui`（前端）、
`make test-server`（總線契約）、`make test`（完整測試門）和 `make gotest`
（Go 測試、vet、race）。

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
