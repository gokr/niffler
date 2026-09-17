# Niffler

[English](README.md) · 简体中文 · [繁體中文](README.zh-TW.md) ·
[网站](https://gokr.github.io/niffler/) · [Discord](https://discord.gg/ThJFEAJUAk)

Niffler 是一个极简、可自我扩展的 agent harness。核心和每项能力都作为独立
进程运行，通过 NATS 上的 JSON 信封通信。Agent 可以在对话进行期间编译并启动
新的组件。项目应从自己的 clone 中运行，该 clone 是实例的 home。

## 为什么选择 Niffler

- **模块化与可扩展性直达进程边界。** Niffler 与 [Pi](https://pi.dev) 和
  [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 一样
  追求精简的 harness 理念，但更进一步：每项能力都是独立的操作系统进程，
  通过统一的 wire 协议（NATS 上的 JSON 信封）通信，而不是进程内插件。
  Agent 可以在对话进行中编写、编译并启动新组件，运行时替换实现，用
  `core.kill` 移除组件——无需清理代码，也不会留下孤儿进程。
- **更多「开箱即用」能力。** 内置组件涵盖了其他 harness 交给第三方插件的
  功能：`fabric`（模型用 Nim 程序编排工具）、`agent`/`expert`（子代理与
  顾问）、`git`、`mcp`（外部 MCP 服务器）、`lsp`（任意语言服务器，以数据
  配置）、`skills`、`plugins`、`repomap`、`processes`（后台任务）、
  `fetch`、`grep`、`edit`，以及观测总线的 `observe`/`logfile` 和 LLM 接入
  的 `models`/`provider`。
- **语言无关的架构。** 提供 Nim、Go 和 TypeScript SDK；为某语言添加支持
  只需一条配置或一个插件组件，无需修改共享组件。
- **总线就是 API。** 所有客户端——`niffler-tui` 终端客户端、Web UI、
  `niffler-cli` 脚本和 CI、`niffler-console`——都只是总线上的普通成员：
  任何能收发 JSON 信封的程序都可以观察、脚本化或驱动对话。
- **默认遵守缓存与成本纪律。** 对话的系统提示词和直接工具 schema 在创建时
  冻结，历史只追加，因此 provider 的 prompt cache 能持续命中；大型工具集
  通过 `discover`/`invoke` 按需获取，不会让每次请求都膨胀。
- **本地优先，clone 即实例。** clone 就是实例：对话和组件状态保存在
  `var/`（默认 SQLite），harness 自行管理 NATS 总线，不依赖任何中心服务。

当前版本是 [v0.2.0](https://github.com/gokr/niffler/releases/tag/v0.2.0)，
变更记录见 [CHANGELOG.md](CHANGELOG.md)。完整操作说明请参阅
[docs/MANUAL.md](docs/MANUAL.md)。

## 快速开始

需要 Nim 2.2.12+ 和 Go；`make setup` 会安装平台依赖（Ubuntu/macOS）和
Nimble 依赖。只有 TypeScript 组件和 Web UI 需要 Node.js 20+ 和 npm；可选的
桌面 UI 在 Linux 上还需要 Wails 和 WebKitGTK 4.1。Niffler 使用纯 Nim 的
[natsnim](https://github.com/gokr/natsnim)，不需要安装 `libnats` 或 `cnats`。

```bash
git clone https://github.com/gokr/niffler.git
cd niffler
make setup                    # Ubuntu/macOS 依赖和 Nimble 包
cp .env.example .env          # 填入 LLM API key
make build                    # 构建核心和组件（不含 UI 工具链）
make install-tui              # 写入 PATH 并安装 niffler-tui 终端客户端
niffler-tui                   # 终端聊天，按需启动此 clone 的 harness
```

`make install-tui` 等价于 `make install WITH_TUI=1`：把 `niffler`、
`niffler-cli`、`niffler-console` 和 `niffler-tui` 包装脚本链接到用户 bin
目录（可用 `NIF_BIN_DIR=~/bin` 指定），并安装
[niffler-tui](https://github.com/gokr/niffler-tui) 插件。直接运行
`make install` 则会在终端上询问是否安装该插件。

`niffler-tui` 是对话客户端；`niffler`（或 `./var/bin/niffler`）是终端管理
shell——status、catalog、sessions，不是对话 UI；`niffler --minimal` 只启动
最小的 store/bash/LLM 配置。

桌面 UI 是可选项：

```bash
make install-ui         # 构建 Wails UI，复制到 ~/.local/bin，并安装
                        # 启动器条目和图标（Linux；别名 make ui-install）
```

开发时可用 `make dev` 在浏览器运行前端（bridge 以桩实现）。`make doctor`
检查依赖，`make down-here` 只停止此 clone 的进程。

测试：`make test-ui`（前端，无需 NATS）、`make test-server`（总线契约）、
`make test`（完整测试门）、`make gotest`（Go 测试、vet 和 race 检查）。

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
