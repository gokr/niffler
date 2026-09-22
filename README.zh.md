# Niffler

[English](README.md) · 简体中文 · [繁體中文](README.zh-TW.md) ·
[网站](https://gokr.github.io/niffler/) · [Discord](https://discord.gg/ThJFEAJUAk)

> 🤖 AI 自动翻译，可能滞后于英文版；以 [English](README.md) 为准。

Niffler 是一个极简、可自我扩展的 agent harness。核心和每项能力都作为独立
进程运行，通过 NATS 上的 JSON 信封通信。Agent 可以在对话进行期间编译并启动
新的组件。项目应从自己的 clone 中运行，该 clone 是实例的 home。

## 为什么选择 Niffler

- **模块化直达进程边界。** 像 Pi 和 DeepSeek Harness，但更深入一层：每项能力
  都是独立的操作系统进程，通过统一的 wire 协议（NATS 上的 JSON 信封）通信；
  Agent 可以在对话中编译、启动和移除组件，无需清理代码，也不会留下孤儿进程。
  见 [ARCHITECTURE.md](docs/ARCHITECTURE.md)。
- **开箱即用。** `fabric`（可编程工具编排）、`agent`/`expert`（子代理与顾问）、
  `git`、`mcp`、`lsp`、`repomap`（Aider 的 tree-sitter + PageRank 移植）、
  `skills`、`plugins`、`processes`、`observe`/`logfile`——其他 harness 通常交给
  第三方插件的功能。见[内置组件](docs/MANUAL.md#shipped-components)。
- **开放模型，所有 Provider。** 任何 OpenAI 兼容端点——本地、开放权重或托管
  ——通过 `.env` 或 store 持久化的 Provider 注册表接入；也支持 ChatGPT/Claude
  订阅 OAuth 和 models.dev 模型目录。见
  [Provider](docs/MANUAL.md#provider-registry-provider) 和
  [模型目录](docs/MANUAL.md#model-catalog-models)。
- **工具渐进披露。** 每个对话只有一个小而冻结的直接工具集，其余工具都在
  `discover`/`invoke` 一步之内，作为历史追加而不是提示词膨胀。见
  [手册](docs/MANUAL.md#progressive-tool-discovery)。
- **人在回路中。** 工具可要求审批，带 manifest 摘要和每对话的 `ask`/`auto`
  门控模式；无人可达时直接拒绝，绝不悄悄放行。见
  [审批](docs/MANUAL.md#approvals)。
- **多语言。** 主体是 Nim 和 Go，但架构不绑定任何语言：提供 Nim、Go 和
  TypeScript SDK，还有一个不用 SDK 的 bash 示例。见
  [ARCHITECTURE.md](docs/ARCHITECTURE.md)。
- **总线就是 API。** `niffler-tui`、桌面 UI、`cli` 和 `console` 都是平等的
  总线客户端；可以同时连接多个，各自独立构建和安装（TUI 本身就是插件）。见
  [启动与停止](docs/MANUAL.md#starting-and-stopping)。
- **为长时间运行而设计。** 冻结的提示词/工具前缀让 provider 缓存持续命中；
  持久化压缩和有界溢出恢复让会话不中断；软性 `/limit` 预算之外还有硬性失控
  保护。见[上下文窗口](docs/MANUAL.md#context-window)。
- **本地优先，clone 即实例。** 对话和组件状态保存在 `var/`（默认 SQLite），
  harness 自行运行 NATS 总线，不依赖中心服务。见
  [布局](docs/MANUAL.md#layout-of-a-running-system)。

当前版本是 [v0.2.0](https://github.com/gokr/niffler/releases/tag/v0.2.0)，
变更记录见 [CHANGELOG.md](CHANGELOG.md)。完整操作说明请参阅
[docs/MANUAL.md](docs/MANUAL.md)。

## 快速开始

需要 Nim 2.2.12+ 和 Go；`make setup` 会安装平台依赖（Ubuntu/macOS）和
Nimble 依赖。只有 TypeScript 组件需要 Node.js 20+ 和 npm。Niffler 使用纯 Nim 的
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
make install-ui         # 通过插件生命周期安装 UI：clone 后针对本 harness 构建，
                        # 产物发布为 var/bin/niffler-ui（再用 make install 加入 PATH）
```

`make doctor`
检查依赖，`make down-here` 只停止此 clone 的进程。

测试：`make test` 运行总线契约测试套件（即完整测试门）；前端测试和
typecheck 位于 UI 自己的仓库；`make gotest` 运行 Go 测试、vet 和 race 检查。

## 文档

- [操作手册](docs/MANUAL.md) — 安装、配置、工具、Provider、UI、恢复、测试和排错（也有
  [English](docs/MANUAL.md) · [繁體中文](docs/MANUAL.zh-TW.md)）。
- [Wire 协议](docs/WIRE.md) — JSON 信封、subject、错误、取消和 session context。
- [架构](docs/ARCHITECTURE.md) — core、组件和 NATS 的边界及贡献者须遵守的约束。
- [当前计划](docs/research/PLAN.md) — 尚未完成的工作。
- [研究索引](docs/research/README.md) — 设计历史和先例研究，不是操作手册。
- [Fabric 指南](docs/FABRIC_GUIDE.md) — 可编程编排和 subagent。
- [模型源插件](docs/MODEL_SOURCES.md) — 修正模型目录的组件示例。
- [设置设计](docs/research/SETTINGS.md) — 尚未发布的设置方案。

## 开发组件

Nim、Go 和 TypeScript 组件使用 `sdk/` 中的 SDK。正常扩展流程是：写源码，调用
`build`，再调用 `spawn`。修改架构前请阅读
[AGENTS.md](AGENTS.md)、[组件生命周期](docs/MANUAL.md#self-extension-and-component-lifecycle)
和 [WIRE.md](docs/WIRE.md)。社区组件通过 `plugins` 安装，详见
[手册中的插件章节](docs/MANUAL.md#component-ecosystem-plugins)。

## 项目理念

- **开放模型，所有 Provider。** 本地、开放权重和托管模型走同一条一等路径：
  默认使用 OpenAI 兼容协议，厂商只提供订阅登录时用 OAuth，模型元数据由
  models.dev 目录提供；限额、能力和价格都是数据。添加一个 OpenAI 兼容的
  Provider 只需一条配置，而不是一段代码。
- **改进靠度量，不靠口号。** `bench/` 用相同的任务和模型，把 Niffler 与
  pi、opencode、CodeWhale、Claude Code 放在一起比较达标时间、token 成本和
  补丁质量（full30、SWE-bench Verified、DeepSWE 任务）。功能要有证据才
  落地——有时也要靠证据才能保持关闭，比如 repo map 的自动注入就因 A/B 结果
  不一致而默认关闭——报告提交在 `bench/reports/`。
- **中文是我们的一等语言。** README 提供英文、简体中文和繁体中文，Web UI
  完整本地化（`en`/`zh`/`zh-TW`），字典是强类型的——漏译会让类型检查失败。
- **带着自豪与感激地「偷」。** 我们从能找到的最好的 harness 中吸收想法——
  Pi、DeepSeek Harness、CodeWhale、OpenCode、Reasonix、Aider、OpenHands
  等等——再逐条对照 Niffler 的设计约束；研究文档会标注来源和固定的提交，
  内置的第三方代码保留其许可证，全部记录在 [docs/research/](docs/research/)。
