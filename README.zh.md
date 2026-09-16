# Niffler

[English](README.md) · 简体中文 · [繁體中文](README.zh-TW.md) ·
[网站](https://gokr.github.io/niffler/) · [Discord](https://discord.gg/ThJFEAJUAk)

Niffler 是一个极简、可自我扩展的 agent harness。核心和每项能力都作为独立
进程运行，通过 NATS 上的 JSON 信封通信。Agent 可以在对话进行期间编译并启动
新的组件。项目应从自己的 clone 中运行，该 clone 是实例的 home。

当前版本是 [v0.2.0](https://github.com/gokr/niffler/releases/tag/v0.2.0)，
变更记录见 [CHANGELOG.md](CHANGELOG.md)。完整操作说明请参阅
[docs/MANUAL.md](docs/MANUAL.md)。

## 快速开始

需要 Nim 2.2.12+、Go、Node.js 20+ 和 npm。桌面 UI 还需要 Wails；Linux
需要 WebKitGTK 4.1。Niffler 使用纯 Nim 的
[natsnim](https://github.com/gokr/natsnim)，不需要安装 `libnats` 或 `cnats`。

```bash
git clone https://github.com/gokr/niffler.git
cd niffler
make setup
cp .env.example .env       # 填入 LLM API key
make                       # 构建核心、组件和桌面 UI
./ui/build/bin/niffler-ui  # 启动 UI，同时启动本地 harness
```

只构建核心和组件使用 `make build`。`./var/bin/niffler` 是终端管理 shell，
不是对话 UI；`./var/bin/niffler --minimal` 只启动 store、bash 和 LLM。
`make doctor` 检查依赖，`make down-here` 只停止此 clone 的进程。

开发时可用 `make dev` 在浏览器运行前端。测试命令：`make test-ui`（前端）、
`make test-server`（总线契约）、`make test`（完整测试门）和 `make gotest`
（Go 测试、vet、race）。

## 文档

- [操作手册](docs/MANUAL.md) — 安装、配置、工具、Provider、UI、恢复、测试和排错。
- [Wire 协议](docs/WIRE.md) — JSON 信封、subject、错误、取消和 session context。
- [架构](docs/ARCHITECTURE.md) — core、组件和 NATS 的边界及贡献者须遵守的约束。
- [当前计划](docs/PLAN.md) — 尚未完成的工作。
- [研究索引](docs/research/README.md) — 设计历史和先例研究，不是操作手册。
- [Fabric 指南](docs/FABRIC_GUIDE.md) — 可编程编排和 subagent。
- [设置设计](docs/SETTINGS.md) — 尚未发布的设置方案。

## 开发组件

Nim、Go 和 TypeScript 组件使用 `sdk/` 中的 SDK。正常扩展流程是：写源码，调用
`builder.build`，再调用 `core.spawn`。修改架构前请阅读
[AGENTS.md](AGENTS.md)、[组件生命周期](docs/MANUAL.md#self-extension-and-component-lifecycle)
和 [WIRE.md](docs/WIRE.md)。社区组件通过 `plugins` 安装，详见
[手册中的插件章节](docs/MANUAL.md#component-ecosystem-plugins)。
