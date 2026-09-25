# Niffler

[English](README.md) · 简体中文 · [繁體中文](README.zh-TW.md) ·
[网站](https://gokr.github.io/niffler/) · [Discord](https://discord.gg/ThJFEAJUAk)

> 🤖 AI 自动翻译，可能与英文版存在偏差；以 [English](README.md) 为准。
> 章节标题保留英文，以便跨文档锚点保持有效。

Niffler 是一个极简、可自我扩展的 agent harness。核心和每项能力都作为独立
进程运行，通过 NATS 上的 JSON 信封通信。Agent 可以在对话进行期间编译并启动
新的组件。项目应从自己的 clone 中运行，该 clone 是实例的 home。

## Why Niffler

- **模块化到进程边界。** 类似 Pi 和 DeepSeek Harness，但低一个层级：每项能力都是独立的操作系统进程，位于同一套线协议之后（通过 NATS 传输的 JSON 信封），智能体在对话过程中构建、生成和移除组件——无需拆卸代码，不会泄漏子进程。参见 [ARCHITECTURE.md](docs/ARCHITECTURE.md)。
- **开箱即用。** `fabric`（可编程工具调用）、`agent`/`expert`（子智能体和咨询对等体）、`git`、`mcp`、`lsp`、`repomap`（Aider 的 tree-sitter + PageRank 移植）、`skills`、`plugins`、`processes`、`observe`/`logfile`——其他 harness 留给插件完成的工作。参见[随附组件](docs/MANUAL.md#shipped-components)。
- **实验性功能保持可选加入。** `jev`（基于本地决策模型的建议式发现）以惰性的按需顾问形式随附在清单中，其运行时是你用 spawn 记录启用的受监督启动器——`make build`/`make setup` 从不被迫承担重量级依赖。参见[建议式发现](docs/MANUAL.md#advisory-discovery-jev-and-the-von-launcher)。
- **开放模型，支持所有提供商。** 任何 OpenAI 兼容端点——本地、开放权重或托管——通过 `.env` 或存储支持的提供商注册表；ChatGPT/Claude 订阅 OAuth 和 models.dev 支持的目录。参见[提供商](docs/MANUAL.md#provider-registry-provider)和[模型目录](docs/MANUAL.md#model-catalog-models)。
- **渐进式工具披露。** 一个小的、冻结的直接工具集；其他一切只需一次 `discover`/`invoke`，作为历史追加而非提示膨胀。参见 [MANUAL](docs/MANUAL.md#progressive-tool-discovery)。
- **人类始终在环。** 审批门控工具，带清单摘要和每会话的 `ask`/`auto` 模式；当无法联系到人类时，调用被拒绝，绝不静默允许。参见[审批](docs/MANUAL.md#approvals)。
- **多语言。** 主要是 Nim 和 Go，但没有组件绑定到某种语言：Nim、Go 和 TypeScript 的 SDK，以及一个完全不用 SDK 的随附 bash 演示。参见 [ARCHITECTURE.md](docs/ARCHITECTURE.md)。
- **总线即 API。** `niffler-tui`、桌面 UI、`cli` 和 `console` 是平等的总线客户端；多个可以同时连接，各自独立构建和安装（TUI 本身就是一个插件）。参见[启动和停止](docs/MANUAL.md#starting-and-stopping)。
- **为长时间运行而构建。** 冻结的提示/工具前缀保持提示缓存热；持久压缩和有界溢出恢复保持会话存活；软 `/limit` 预算与硬失控防护并存。参见[上下文窗口](docs/MANUAL.md#context-window)。
- **本地优先，克隆即实例。** 对话和组件状态位于 `var/`（默认 SQLite），harness 运行自己的 NATS 总线，没有中心服务。参见[布局](docs/MANUAL.md#layout-of-a-running-system)。

当前版本是 [v0.2.0](https://github.com/gokr/niffler/releases/tag/v0.2.0)。自该版本以来的变更参见 [CHANGELOG.md](CHANGELOG.md)。

## Quick start

要求：Nim 2.2.12+ 和 Go。`make setup` 安装这些以及其他平台先决条件（Ubuntu/macOS）和 Nimble 依赖。Node.js 20+ 和 npm 仅用于 TypeScript 组件和 Web UI；可选的桌面 UI 在 Linux 上还需要 Wails 和 WebKitGTK 4.1。Niffler 使用纯 Nim 的 [natsnim](https://github.com/gokr/natsnim) 客户端；无需安装 `libnats` 或 `cnats`。

```bash
git clone https://github.com/gokr/niffler.git
cd niffler
make setup                    # Ubuntu/macOS prerequisites and Nimble deps
cp .env.example .env          # add an LLM API key; edit other settings as needed
make build                    # core + components (no UI toolchain)
make install-tui              # PATH entries + the niffler-tui terminal client
niffler-tui                   # terminal chat; boots this clone's harness
```

`make install-tui` 即 `make install WITH_TUI=1`：它将 `niffler`、`niffler-cli`、`niffler-console` 和 `niffler-tui` 包装器链接到用户 bin 目录（`NIF_BIN_DIR=~/bin` 覆盖位置）并安装 [niffler-tui](https://github.com/gokr/niffler-tui) 插件。普通的 `make install` 在终端上会询问该插件。

`niffler-tui` 是对话客户端；`niffler`（或 `./var/bin/niffler`）是终端管理 shell——状态、目录、会话，不是聊天 UI——而 `niffler --minimal` 仅启动最小 store/bash/LLM 配置文件。

桌面 UI 是可选的：

```bash
make install-ui         # install the desktop UI plugin (gokr/niffler-ui): the
                        # plugin manager clones it, the builder builds it against
                        # this harness, and the binary lands in var/bin
```

当 `niffler-ui` 存在时，`make install` 会将其链接到 PATH。UI 自己的开发服务器、单元测试和类型检查位于 [niffler-ui](https://github.com/gokr/niffler-ui) 仓库。`make doctor` 检查先决条件；`make down-here` 仅停止此克隆的进程。

测试：`make test` 运行总线契约套件（每个测试一个私有总线）；`make gotest` 运行 Go 测试、vet 和竞态检查。

## Documentation

- [Manual](docs/MANUAL.md) — 安装细节、配置、工具、提供商、UI、恢复、测试和故障排除（还有[简体中文](docs/MANUAL.zh.md) · [繁體中文](docs/MANUAL.zh-TW.md)）。
- [Wire protocol](docs/WIRE.md) — JSON 信封、主题、错误、取消和会话上下文。
- [Architecture](docs/ARCHITECTURE.md) — 为什么核心、组件和 NATS 是分离的，以及贡献者必须保持的不变量。
- [Open work](docs/research/PLAN.md) — 当前推迟的工作。
- [Research index](docs/research/README.md) — 设计历史和先前技术研究；研究笔记不是操作说明。
- [Fabric guide](docs/FABRIC_GUIDE.md) — 可编程编排和子智能体。
- [Model source plugins](docs/MODEL_SOURCES.md) — 目录校正组件的完整示例。
- [Settings design](docs/research/SETTINGS.md) — 尚未发布的设置工作。

## Developing components

Nim、Go 和 TypeScript 组件使用 `sdk/` 中的 SDK。正常的扩展路径是：编写源代码，调用 `build`，然后调用 `spawn`。在更改架构或添加组件之前，请阅读[组件生命周期](docs/MANUAL.md#self-extension-and-component-lifecycle)、[线协议](docs/WIRE.md)和 [AGENTS.md](AGENTS.md)。

社区组件通过 `plugins` 组件安装；参见[手册的插件部分](docs/MANUAL.md#component-ecosystem-plugins)。

## Philosophies

- **开放模型，支持所有提供商。** 本地、开放权重和托管模型获得同等的一等路径：OpenAI 兼容默认、当供应商不提供其他方式时的订阅 OAuth，以及 models.dev 支持的目录，将限制、能力和价格作为数据保存。添加 OpenAI 兼容提供商是配置条目，而非代码路径。
- **改进是衡量的，而非断言的。** `bench/` 在相同任务和模型上运行 Niffler 对比 pi、opencode、CodeWhale 和 Claude Code，在 full30、SWE-bench Verified 和 DeepSWE 套件中比较 time-to-green、token 成本和补丁质量。功能基于该证据落地——有时也基于它保持关闭，比如 repo map 的自动追加，因为 A/B 测试结果不一致而默认禁用——报告提交在 `bench/reports/` 下。
- **中文在这里是一等语言。** README 有英文、简体和繁体中文，Web UI 完全本地化（`en`/`zh`/`zh-TW`）并带类型化目录——缺失翻译会导致类型检查失败。
- **带着自豪和感激地借鉴。** 我们采纳在其他 harness 中找到的最佳想法——Pi、DeepSeek Harness、CodeWhale、OpenCode、Reasonix、Aider、OpenHands 等——并在发布前对照 Niffler 的不变量重新检查每一项。研究注明其来源和固定提交，vendored 代码保留其许可证，一切都在 [docs/research/](docs/research/) 中。
