# Niffler Manual

[English](MANUAL.md) · 简体中文 · [繁體中文](MANUAL.zh-TW.md)

运行、配置和恢复 Niffler harness 所需的一切，另加随附组件的参考章节。设计理由见
[research/REBOOT.md](research/REBOOT.md)；线协议见
[WIRE.md](WIRE.md)；core/组件边界见
[ARCHITECTURE.md](ARCHITECTURE.md)；进行中的工作汇总在
[research/PLAN.md](research/PLAN.md)。

> 🤖 AI 自动翻译，可能与英文版存在偏差；以 [English](MANUAL.md) 为准。
> 章节标题保留英文，以便跨文档锚点保持有效。
> 本文件于 2026-09-23 由英文版（docs/MANUAL.md）完整重新生成。

## Contents

- [Layout of a running system](#layout-of-a-running-system)
- [Store engines](#store-engines)
- [State and configuration](#state-and-configuration) · [Environment variables](#environment-variables) · [The `.env` file](#the-env-file)
- [The bus in one screen](#the-bus-in-one-screen) · [Approvals](#approvals)
- [Context window](#context-window) · [Self-extension and component lifecycle](#self-extension-and-component-lifecycle)
- [Component ecosystem (`plugins`)](#component-ecosystem-plugins) · [Skills](#skills)
- [Provider registry (`provider`)](#provider-registry-provider) · [Fetch](#fetch) · [`grep` in detail](#grep-in-detail)
- [External MCP servers (`mcp`)](#external-mcp-servers-mcp)
- [Language servers (`lsp`)](#language-servers-lsp) · [Repository inspection (`git`)](#repository-inspection-git) · [Background processes (`processes`)](#background-processes-processes)
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

| 路径 | 它是什么 |
|---|---|
| `core/` | 控制平面：系统 harness（`niffler.nim`：总线引导、监督器、目录、分发）+ 会话运行器（`session.nim`）及其驱动的回合循环（`conversation.nim` —— 最大的模块 —— 外加 `compaction.nim`、`approval.nim`、`retry.nim`、`uireg.nim`、`tty.nim`） |
| `components/` | 随附的组件源码 —— 每个组件一个目录（Nim、Go、TypeScript 和一个 bash 演示）；清单是下面的[随附组件](#shipped-components)表，这是必须保持最新的部分。有两个目录不是总线公民：`components/nats` 构建 `var/bin/nats-server`，当需要启动总线时由 core 生成；`components/ctxtest` 是嵌套调用测试（`t_fabric`、`t_agent`）为自己编译的夹具 |
| `sdk/` | Nim SDK（`sdk/niffler`）+ `sdk/go`（Go）+ `sdk/ts`（TypeScript/Node.js，npm 包 `niffler-sdk`）；`sdk/envelope.nim` 中的信封就是产物 |
| `docs/` | 本手册、线协议规范（`WIRE.md`）、设置设计（`research/SETTINGS.md`）、核心边界理由（`ARCHITECTURE.md`）、fabric 用户指南（`FABRIC_GUIDE.md`）、待办工作（`research/PLAN.md`）以及 `research/`（设计历史） |
| `manifest.yaml` | 引导清单：core 生成哪些组件、重启策略，以及可选的无状态 `replicas` 数量；`--minimal` 将其过滤为 `store`、`bash` 和 `llm` |
| `var/` | **运行时状态，已 gitignore，可丢弃** —— 仓库才是快照 |
| `var/bin/` | 构建出的二进制文件（系统核心 + 会话运行器 + 组件），以及 `builder.build` 编译的一切 —— agent 构建的组件也落在这里，与系统组件并列。由 `make build` 重建 |
| `var/store.db` | SQLite 存储的数据文件（默认引擎）—— **单写入者**：恰好一个 `store` 进程可以打开它。较旧的、未迁移的 harness 仍使用 `var/barrel-db`；已迁移的根目录会保留该文件不动，与 `var/store.db` 并列。每个引擎锁定自己的文件 —— `var/store.db.lock`、`var/barrel-db.lock` |
| `var/nats-url` | 最后生成的总线的总线地址；UI 桥读取它以找到 core |
| `var/nats-monitor-url` | 当 core 生成总线时的 HTTP 监控端点；对于复用/远程总线则不存在 |
| `var/logs/`、`var/captures/` | 轮转的结构化日志和显式的 observe 探针导出（见[观察与日志](#observation-and-logs)） |
| `var/toolout/` | `bash` 溢出文件（`<session>/<pid>-<epoch>-<counter>.out`），当命令输出超过内联上限时写入 —— `read` 可以分页读取的绝对路径；1 小时后清扫，因此旧回合的路径可能已消失 |
| `var/approval-sources/`、`var/mcp-results/`、`var/review-receipts/`、`var/fabric-cache/`、`var/plugins/` | 审批提示载荷、MCP 桥结果、`review_receipt` 指纹、编译后的 fabric 程序和已安装的插件克隆 —— 全部可丢弃 |
| `var/models/`、`var/processes/`、`var/repomap-tags/`、`var/fetch/` | 组件状态：models.dev 目录缓存、后台进程记录、repomap 标签缓存、溢出的 fetch 正文 |
| `var/nats-pid` | 生成的 bus core 的 pid（仅用于崩溃清理 —— 存活的 core 在退出时会停止自己的总线） |
| `var/build/` | agent 构建组件的源文件（builder 的暂存目录）：Nim 为一个 `<name>.nim`，Go 和 TypeScript 为整个项目目录（`go.mod`、`package.json`/`tsconfig.json`、`node_modules/`、`dist/`）。它是 agent 构建组件源码的**唯一**副本 —— 持久化的 `component` 记录不携带任何源码，因此 `make clean` 会使其成为孤儿 |
| `nimcache/` | 构建产物；`make clean` 会删除它们（连同 `var/`） |

### Shipped components

| 组件 | 语言 | 清单 | 它做什么 |
|---|---|---|---|
| `store` | Nim/Go | 必需 | 总线上的文档存储（`put/get/list/del`，基于 rev 的并发）。所有四个工具都是按需的，且 `del` 额外被隐藏 —— core 删除记录，模型不能。引擎以相同名称注册相同的四个工具（`put`/`get`/`list`/`del`；barrel 引擎额外注册一个隐藏的 `selftest` —— `/doctor` 扇出到的那个 —— Go 引擎不实现它）：`store-sqlite`（Go，SQLite + goose 迁移，`var/store.db`）是**默认**；`barrel`（`var/bin/store`）和 `tidb` 仍可通过 `NIF_STORE_BACKEND` 选择 —— 见[存储引擎](#store-engines) |
| `bash` | Nim | 必需 | 经典工具：带超时 + 输出上限的 shell 命令。命令作为自己进程组的领导者运行，因此超时或取消的回合会杀死整棵树（退出码 124 / 130）—— 没有孤儿子进程。结果携带 `text`（一个 `(exit N)` 状态行 —— 非零 = 失败；124 = 超时，130 = 已取消，126 = cwd 无法进入（该工具也用 126 表示找到但不可执行），127 = `bash` 不在 `PATH` 上，128 + 信号表示命令杀死了自己（139 = SIGSEGV，143 = SIGTERM）—— 后跟合并的 stdout/stderr；这是 LLM 转录显示的内容）加上机器字段 `exit_code`、`cancelled`，以及当超大输出溢出到 `var/toolout/` 下的文件时的 `spill {path, bytes, lines}`（绝对路径在 `spill.path` 中；可用 `read` 分页，1 小时后清扫）。`run_in_background: true` 将长时间运行的命令（服务器、监视器）交给 `processes` 组件而不是阻塞 —— 见[后台进程](#background-processes-processes) |
| `repomap` | Nim | 可选 | 排序的工作区地图（docs/research/REPOMAP.md）：约 1KB 的承重文件及其关键定义，由 tree-sitter + 原生 Nim 标签图与个性化 PageRank 构建（aider repomap 移植）。`repo_map {workspace?, focus?, mentionedIdents?, budget?}` 是 onDemand 且 read-effect。工作区打开时自动追加（在 `ev.workspace.opened` 上的一条仅追加历史条目）**默认开启但受门控**（`docs/research/REPOMAP-GATES.md`）：工作区必须至少有 50 个覆盖文件，且其渲染的地图必须至少有 800 字节、25 个符号和 5 个带符号的文件。小型/存根地图会被扣留并记录为 `repo map withheld`；设置 `NIF_REPOMAP_AUTOAPPEND=0` 可禁用追加。显式的 `repo_map` 工具无论这些门控如何都可用。缓存：`var/repomap-tags/`（以 mtime 为键）。可选组件 —— 缺失意味着没有地图，其他一切不变。参数、标签层级和追加载荷：[`repomap` 详解](#repomap-in-detail) |
| `processes` | Nim | 可选 | 有所有者的长时间运行命令：`process_start`（分离，自己的进程组，立即返回一个 id）、`process_poll`（排空增量输出）、`process_kill`（停止进程组）、`process_list` —— 见[后台进程](#background-processes-processes) |
| `builder` | Nim | 必需 | 用 `build {lang, name, source, files?, defines?}` 编译 agent 编写的 Nim/Go/TypeScript 源码，并用 `build_package {name, lang, sourceRoot, project, steps, artifact}` 构建 manifest-v2 插件项目（审批门控，按需）。包项目保留自己的依赖清单和锁文件；builder 暂存它们，仅展开受控的 SDK/输出占位符，执行有界的 argv 配方，验证声明的 `executable`/`node` 产物，并返回发布的二进制/运行时包。配方可以组合工具链（例如 `npm ci` 后跟 `wails build`）；配方使用有界的 argv 工具集，不能调用 shell 包装器。`info` 返回 SDK 路径、全局工具命名规则以及两种构建流程 |
| `llm` | Go | 必需 | 流式聊天适配器 —— 三个隐藏工具，都不在会话的直接工具集中：`chat`（一次推理，`ev.llm.token` 增量，取消；`runner` 豁免，超时 `NIF_LLM_TIMEOUT_MS`）、`llm_resolve`（客户端调用的无凭据解析探针）和 `llm_models_source`（`models` 目录调用的 `x-models-source` v1 实时 id 源）—— 协议：OpenAI 兼容的 Chat Completions、OpenAI Codex（ChatGPT OAuth）Responses 和 Anthropic Messages；`components/llm-openai` 中的 `llm-openai` 是最小的非流式示例（它只读取 `NIF_OPENAI_API_KEY`、`NIF_OPENAI_BASE_URL`、`NIF_OPENAI_MODEL` 和 `NIF_OPENAI_CONTEXT` —— 不读取 `NIF_OPENAI_PROVIDER` —— 并且总是发送 `max_tokens: 32768`，一个没有旋钮的硬编码值）；通过 `manifest.yaml` 换入它 —— 在同一次编辑中注释掉 `llm`，因为 `chat` 是全局唯一的工具名，重复注册会被拒绝；`make build` 无论如何都会构建 `var/bin/llm-openai`。不要期望聊天契约之外的任何东西：没有 `ev.llm.token` 流式，没有取消，没有 `finish_reason`，没有 `llm_resolve`（core 在最后一个上优雅降级） |
| `models` | Go | 可选 | models.dev 提供商/模型目录、原子缓存、严格解析，以及插件纠正/发现层（见[模型目录](#model-catalog-models)） |
| `provider` | Go | 可选 | 存储支持的 LLM 提供商注册表：`provider_add`/`list`/`switch`/`active`/`remove`/`export`/`import`，订阅 OAuth 登录（`provider_oauth_start`/`complete`/`cancel`），`ev.provider.switch` 通知 |
| `plugins` | Nim | 可选 | 生态系统前门：主题搜索 + 包的安装/更新/移除 |
| `skills` | Nim | 可选 | Agent Skills（SKILL.md）：发现、加载、资源访问、基于 git 的安装/移除 |
| `fetch` | Nim | 可选 | Web 内容检索：http/https、HTML→文本提取、带文件溢出的尺寸上限 |
| `edit` | Nim | 可选 | 文件工具：`read`（规范的 `reads` 数组 —— 一次调用最多 12 个文件/范围（每项 2000 行、256 KB、每行 2 KB —— 更长的行变成 `bash: sed -n …` 通知；每次调用总计 512000 字节，剩余部分报告为不使批次失败的逐项错误），可分页，单文件 `path` 语法糖；对 >1000 行的文件进行整体读取且其类型有语言服务器时，返回 lsp 符号大纲 —— 用 offset/limit 开窗，或用 `offset: 1` 无论如何整体读取，`NIF_READ_OUTLINE_LINES` 调整/禁用 —— 对本会话已完整读取过且字节完全相同的 ≥512 字节文件进行整体重读时，返回 `[unchanged] <path>: N bytes, M lines, digest <sha1>` 而不是文本；`force: true`（或任何 offset/limit 窗口）强制重新转储，窗口读取和小文件总是重新转储）、`edit`（只更改*现有*文本文件 —— 缺失路径是 `E_NOT_FOUND`，空文件是 `E_EMPTY`，两者都指向 `write` 作为创建内容的方式；接受 `{old_string, new_string, replace_all?}` 对的 `edits[]` 数组 —— 没有单独的多编辑工具 —— 全部针对*原始*文件匹配，检查重叠和无变化，然后以一次原子重命名写入；受保护的回退级联是尾随空白 → 缩进漂移 → unicode 标点 → 按 Levenshtein 相似度 ≥ 0.65 的块锚点 → 双重转义文本，每一层仍必须恰好匹配一次；陈旧门控位于匹配*之前* —— 当会话最后观察到的文件摘要与磁盘不同（外部编辑，或读取/写入后的 `bash` 变更）时，`edit` 以 `E_STALE` 拒绝，而不是匹配模型从未见过的文本：重新读取并重做。无会话调用者（`cli`、其他组件）不被跟踪并跳过门控）、`write`（原子整体文件：创建父目录、跟随符号链接、保留目标权限、将载荷上限设为 `NIF_WRITE_MAX_BYTES` = 900000）、`undo_last_edit`（每文件单级 —— 仅上一次编辑，不是栈 —— 跨重启持久化并以绝对路径为键，精确还原内容、BOM 和行尾；当文件在编辑后被修改或删除时以 `E_UNDO_STALE` 拒绝，此时陈旧记录被*丢弃*（重新读取并向前编辑）；撤销记录在文件之前写入，因此存储失败会以 `E_UNDO_UNAVAILABLE` 拒绝编辑，而不是失去还原能力；审批门控的变更）；锚定块移动位于 [niffler-hashline](https://github.com/gokr/niffler-hashline) 插件中 |
| `lsp` | Nim | 可选 | 语言服务器接缝：一个 `lsp` 工具 —— `diagnostics`（无需测试运行的编译器/lint 错误）、`documentSymbol`（文件大纲：每个符号及其种类、名称和从 1 开始的位置）、`workspaceSymbol`（在服务器索引上进行仓库范围的符号搜索 —— 模糊 `query`，跨文件结果）、`goToDefinition`、`findReferences`、`goToImplementation`、`hover`、`warmup` —— 加上 `lsp_servers`（列出合并的注册表）和 `lsp_registry`（`add`/`remove` 一个条目，审批门控）—— 在任何配置的 stdio 语言服务器上（默认 gopls、nimtortoise、typescript-language-server、pyright、rust-analyzer、clangd、bash-language-server、jdtls、intelephense、solargraph、csharp-ls）。注册表是数据（`$XDG_CONFIG_HOME/niffler-lsp/servers.json`）：添加语言是一个配置条目或 agent 可以自己做的 `lsp_registry add` —— 绝不是代码（AGENTS.md：语言无关核心）。按需工具 |
| `git` | Nim | 可选 | 只读仓库检查：在固定 argv 上的 `git_status`/`git_diff`/`git_log`/`git_show`/`git_blame`（免审批；变更留在 bash 中）加上 `review_receipt` —— 在 `var/review-receipts/` 下的本地 diff 指纹写入/检查对，用于推送前审查交接（从不调用模型；当 diff 自收据以来发生变化时检查失败）。按需工具 —— worker 通过 `discover` + `invoke` 到达它们，保持直接工具集小 |
| `agent` | Nim | 可选 | 子代理会话，九个工具：`agent_run`/`agent_spawn`（全新或继续的子代理、后台作业、持久结算通知）加上 `agent_status`/`agent_wait`/`agent_stop`/`agent_steer`/`agent_ask`/`agent_notices`/`agent_list` —— 见 [Fabric 与子代理](#fabric-and-subagents) |
| `expert` | Nim | 可选 | 顾问对等体：并发跟随一个或多个会话，LLM 评判，回合绑定转向（见[专家顾问对等体](#expert-advisory-peer-expert)） |
| `fabric` | Nim | 可选 | 可编程工具调用：模型编写一个编排工具的 Nim 程序；只有其 `finish()` 值进入会话（见 [Fabric 与子代理](#fabric-and-subagents)） |
| `grep` | Nim | 可选（4 个副本） | ripgrep 支持的搜索：`grep`（内容，path:line:match，直接，输出上限）和 `files`（排序列表，按需）；感知 .gitignore，无需 shell 引用；无状态队列组副本重叠同组件搜索 —— 参数、上限、退出码和效果分类在 [`grep` 详解](#grep-in-detail) |
| `systemprompt` | Nim | 可选 | 会话宪法：会话运行器每个会话从 `svc.systemprompt.call` 获取一次系统提示（见[系统提示（`systemprompt`）](#system-prompt-systemprompt)） |
| `compaction` | Nim | 可选 | 默认可替换的 `compaction_propose` 实现：验证运行器拥有的分页快照，选择允许的切割，并返回结构化检查点候选；只有运行器验证并提交投影 —— 该工具本身是 `hidden` + `x-harness.runner: true`（read-effect，120 秒），因此没有模型能看到它，只有运行器或其他组件调用它；组件缺失或被杀死时，摘要关闭，确定性阶梯（无损修剪，然后有损回退梯级）仍然运行 |
| `recall` | Nim | 可选 | 按需的 `context_recall` 解析器，用于规范消息、完整溢出文档和当前持久检查点 —— 加上 `mode: search`，对会话的整个规范历史（包括被修剪/压缩掉的消息）进行 grep |
| `cli` | Nim | — | 用于脚本/CI 的按需总线驱动（`catalog`/`wait`/`call`/`install`）—— 一个从不发布 `reg.publish` 的纯客户端，因此它从不出现在 `catalog` 中，`cli wait cli` 也永远不会成功 |
| `console` | Nim | — | 按需总线查看器（在 stdout 上渲染每个信封） |
| `observe` | Nim | 可选 | 有界实时总线环、监听/跟踪探针、安全捕获导出和 NATS 监控（见[观察与日志](#observation-and-logs)）—— 所有十二个工具都是按需的，且没有一个声明 `x-harness.effect`，因此 fabric 批处理主机即使对 `observe_events`/`observe_logs` 也按写入调度 |
| `logfile` | Nim | 可选 | 轮转 JSONL 接收器和有界持久日志搜索（见[观察与日志](#observation-and-logs)）—— 两个工具都是按需的，且都没有声明 `x-harness.effect`，因此 fabric 批处理主机即使对 `logfile_search` 也按写入调度 |
| `hooks` | Nim | 默认关闭 | 当选定的总线事件触发时运行操作员 shell 命令（仅观察；stdin 上的 JSON，环境配置；见[钩子](#hooks)） |
| `mcp` | Go | 可选 | 外部 MCP 服务器（Model Context Protocol）：存储支持的注册表（`mcp_servers`/`mcp_search`/`mcp_add`/`mcp_edit`/`mcp_remove`/`mcp_refresh`），每个服务器一个受监督的桥（子进程是单独的 `mcp-bridge` 二进制 —— `var/bin/mcp-bridge`，由 `make build` 构建，路径可用 `NIF_MCP_BRIDGE_BIN` 覆盖；它没有清单条目，从不手动启动）；工具成为普通的目录工具，可通过 `discover` + `invoke` 到达（见[外部 MCP 服务器](#external-mcp-servers-mcp)） |
| `nats-server` | Go | **不在清单中** | 总线本身作为一等组件：官方 `nats-server` main 的忠实重建（固定在 `components/nats/go.mod`），由 `make build` 构建到 `var/bin/nats-server`，core 优先于 PATH 安装使用它，因此不需要 NATS 先决条件。故意*不是*总线组件 —— core 在总线存在之前启动它，它不注册任何工具，`core.spawn` 无法启动它。Niffler 添加一个标志 `--max_payload <bytes>`（core 传递 8388608），在 Linux 上它设置 `PR_SET_PDEATHSIG`，使没有孤儿总线比其 harness 活得更久。无需为它安装任何东西：`make install-nats` 只是这么说，`make doctor` 报告 `nats-server: OK` 或解释它从源码构建 |
| `dialog` | bash | — | 完全用 bash 编写的演示组件 —— nats CLI + jq，无 SDK，无编译步骤：`dialog_show` 弹出桌面对话框（zenity、notify-send 或日志回退），`dialog_ask` 向用户询问是/否问题并返回答案（`dialog_show` → `{ok, shown: yes|no, via: zenity|notify|log, kind}` —— `shown` 是后端的真实结果：失败的对话框或日志回退是 `no`，绝不是假的 `yes`；`dialog_ask` → `{ok, answer: yes|no|timeout|no-display}` —— `timeout` 意味着有人看到了对话框并让它过期，`no-display` 意味着没有人能回答）。两个工具都不是审批门控或按需的，因此当 `dialog` 运行时启动的每个会话的直接工具集中都会包含它们，且在没有显示（`DISPLAY` 未设置或 zenity 缺失）时 `dialog_ask` 立即回答 `no-display` 而不询问任何人。随附在 `var/bin/dialog`（`make build`）中但**不自动启动**；用 `spawn {name: "dialog", binary: ".../var/bin/dialog"}`（core 的工具）生成它。先决条件：nats CLI 和 `jq` 是硬性的 —— 缺少任何一个组件根本无法回答；`zenity`（或 `notify-send`）仅用于可见部分，且仅在设置了 `DISPLAY` 时。`make setup` 安装全部三个，`make doctor` 检查它们 |

`components/ctxtest/` 是“每个组件一个目录 = 一个随附组件”的例外：它是契约测试自己的夹具 —— 一个存根 `chat` LLM 加上嵌套调用探针 —— 测试自己将其编译为注册为 `ctxtest` 和 `ctxsink` 的二进制文件。它不在此表中，不在 `manifest.yaml` 中，且从不被 `make build` 构建。

### `bash` in detail

上面的 bash 行是摘要；这是模型所依据的契约。`bash {command, timeoutMs?, cwd?, run_in_background?}` 将 `bash -c <command>`（`$PATH` 解析，无覆盖）作为新进程组的领导者运行，stderr 按到达顺序合并到 stdout，子进程继承组件的环境（`NIF_ROOT`、`.env`、core 导出的一切）和 stdin，且高于 stderr 的描述符在生成前关闭。每次调用一个新 shell 意味着 `cd` 不持久；`cwd`（会话工作区）实现为 `cd -- <cwd> || exit $?`，因此缺失的工作区目录会使调用失败，而不是在别处运行。

两个超时容易混淆。参数（`timeoutMs`，默认 30 秒）约束*命令* —— 超时会杀死整个进程组并报告退出码 124 —— 而 schema 的 `x-harness.timeoutMs`（60 秒）约束*core* 等待回复的时间。因此命令可以合法地比分发预算活得更久：使用 `timeoutMs: 120000` 时调用者看到的是分发超时，而不是整齐的 124。

输出由两个编译时常量约束，**没有环境旋钮** —— 组件中唯一的 `getEnv` 是 `NIF_ROOT`，因此更大的转录预算意味着重建它：最多捕获 2,000,000 字节，最多 12,000 字节的转录到达模型，保留头部和尾部，中间替换为
`[... truncated <omitted> of <total> bytes (capped at <max>) — <hint> ...]`，
其中提示告诉*模型*缩小命令或分页溢出文件，而不是让人类提高设置。更大的捕获溢出到 `var/toolout/`（绝对路径在 `spill.path` 中，1 小时后清扫）。当完全无法捕获任何东西时 —— 未终止的 heredoc、不平衡的引号 —— 转录携带
`[no output captured — the command failed to parse or start; check quoting and
heredoc termination]` 而不是裸退出码。Heredoc 本身受支持：包含 `<<` 的命令被包装，使重定向从自己的行开始。

取消的形状与行中描述相同，有一个补充：`cancel.bash` 仅在其时间戳的 **30 秒**内被遵守，针对*不同*会话的取消被暂存 —— 该会话的下一个排队请求变成合成的 `(exit 130 — cancelled by request)` **而不运行命令**。退出码是工具的契约：124 超时，130 已取消，126 cwd 无法进入，127 `PATH` 上没有 `bash`，128 + 信号表示命令杀死了自己。`bash` 不声明 `x-harness.effect`，因此 fabric 批处理主机将其分类为**写入**并独占运行它，绝不在读并发上限内。

### `repomap` in detail

上面的 `repomap` 行是摘要。`repo_map` 工具是仅发现的 —— 不在会话的冻结直接集中，可通过 `discover` + `invoke` 到达 —— 携带 `x-harness.effect: read` 且无需审批。合格的工作区在打开时通过仅追加历史收到一张地图；更小或存根工作区什么也得不到，除非模型要求。`budget` 以 token 为单位，默认 1024，最多 4096。

`focus` 围绕会话正在处理的文件对图进行排序 —— 并省略它们自己的定义，因为它已经有了 —— 而 `mentionedIdents` 提升路径或定义与任务命名的符号匹配的文件。

标签覆盖分两层：tree-sitter 用于 Go、Python、TypeScript、JavaScript、C、C++、Rust 和 Ruby（语法 vendored 在 `components/repomap/csrc/` 下，每语言查询在 `components/repomap/queries/` 下），以及用于 `.nim`/`.nims` 的原生 Nim 标签器，因为 Nim 语法的生成解析器有 40 MB。这些层之外的扩展不贡献符号，因此无法标记的语言的地图是空的而不是错误的。

馈送图的普查遍历工作区一次，跳过隐藏目录、`docs/`、`var/`、`logs/`、`vendor/`、`node_modules/`、构建输出（`dist/`、`build/`、`target/`、`nimcache/`、……）和其他垃圾目录，并在 5000 个文件或 5 秒后停止。单次构建在工具的 120 秒信封内上限为 90 秒。因此仅文档或否则很小的工作区映射为空 —— 追加路径记录 `repo map withheld`，工具回答 `No map: …`。

**追加注入什么。** 每个会话一条用户角色消息：一个方括号前言，命名工作区并警告它是在会话开始时拍摄的快照，然后是地图。它进入普通的仅追加历史 —— 运行器在会话的下一个 LLM 请求之前将其折叠进去，绝不进入冻结前缀 —— 因此后续压缩可能将其修剪掉，`repo_map` 按需重新创建它。组件将完成的地图发布到 `svc.session.<id>.map`（运行器的排空主题）；它随后进行的追加对观察者可见为 `ev.session.<id>.map {sessionId, workspace, bytes}`。

### `grep` in detail

上面的 `grep` 行是摘要。两个工具都以固定 argv 运行 ripgrep —— 模式作为 `--` 之后的参数传递，绝不通过 shell —— 因此引号、反斜杠和空格无需转义，这是相对于 `bash grep` 的可靠性优势。`rg` 通过 `PATH` 解析；当它缺失时两个工具都回答退出码 127 并给出指向 `bash grep -rn` 的安装提示。`.gitignore` 和隐藏/二进制文件默认跳过，`hidden: true` 添加隐藏文件而 `.gitignore` 仍然适用，`glob` 缩小范围而不取消隐藏。`path` 在分发时是工作区相对的，结果以绝对路径返回。

`grep {pattern, path?, glob?, context? (≤50), case_insensitive?, hidden?,
max_results? (default 200), timeoutMs? (default 30000)}` 返回 `path:line:match`
行；`files {path?, glob?, hidden?, max_results? (default 500), timeoutMs?}`
返回排序的路径。`max_results` 上限为 10000 行，文本上限为 32 KB（保留头部和尾部，并带有说明切掉多少的标记），超过 300 列的行被省略为 `[Omitted long matching line]`（rg 的 `--max-columns 300`）。`exit_code` 是契约：0 匹配，1 无（`[no
matches]`/`[no files]`），2 坏正则，124 超时，127 rg 缺失。`grep`
声明 `parallel: true` 而 `files` 不声明，且两者都不声明
`x-harness.effect` —— fabric 批处理主机将两者都按写入调度。四个无状态清单副本通过一个队列组为它们服务。

### Minimal boot profile (`--minimal`)

正常清单是完整的、自扩展的 harness。对于最小的有用持久运行时，启动：

```bash
./var/bin/niffler --minimal
```

这将清单引导集过滤为恰好三个服务组件：

- `store` —— 会话/消息持久化和组件记录
- `bash` —— 一个通用机器工具
- `llm` —— OpenAI 兼容的模型访问和流式

Core 和 NATS 仍然运行，第一个会话启动其正常的临时 `var/bin/session <id>` 运行器。`builder`、`plugins`、`skills`、`fetch`、`models`、`provider`、专用文件工具以及观察/日志不启动。通过 `core.spawn` 创建的持久化组件故意不恢复，但它们的存储记录不被删除；稍后的正常引导会恢复它们。最小模式只是引导配置文件，不是策略边界 —— 调用者仍可在运行期间使用 `core.spawn`。

因为 `provider` 和 `models` 都不存在，正常会话回合直接从 `NIF_OPENAI_API_KEY`、`NIF_OPENAI_BASE_URL` 和 `NIF_OPENAI_MODEL` 解析后端。当确切的上下文窗口重要时设置 `NIF_OPENAI_CONTEXT`；否则 `llm` 使用其小型内置模型表，然后 128K 回退 —— 但该表仍列出已停用的 `deepseek-chat`/`deepseek-reasoner` id，因此 `NIF_OPENAI_CONTEXT` 是今天在 DeepSeek 上唯一正确的答案。

```bash
NIF_OPENAI_API_KEY=sk-... \
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1 \
NIF_OPENAI_MODEL=deepseek-chat \
NIF_OPENAI_CONTEXT=1000000 \
./var/bin/niffler --minimal
```

桌面 UI 的自动启动使用正常配置文件。要将 UI 与最小配置文件一起使用，先启动上面的命令，然后启动 `niffler-ui`；它附加到现有的 core。`--minimal --recover` 也有效：恢复先重建并清除生成的组件记录，然后引导三组件配置文件。这只是运行时选择；`make build` 仍构建完整的随附集。

### Session runners

一个会话 = 一个进程（`var/bin/session <sessionId>`），由系统 harness 按需生成。客户端继续调用 `svc.core.call`（工具 `session`）；系统确保每个会话 id 一个运行器，并将回合转发到 `svc.session.<sessionId>.call`。该转发是异步的 —— core 的泵拥有收件箱 —— 因此一个长回合不能阻塞另一个会话的运行器；就绪是运行器出现在目录中，在生成后轮询最多 10 秒。运行器是受监督的子进程（重启策略 `never`），这是字面意思：死掉的运行器不会重启 —— 下一个会话调用从存储重新确保它，尸体在等待中途被收割，因此替换立即生成。它宣布自己为组件 `session-<id>`，零工具，在启动时从 `catalog {op: snapshot}` 播种其目录，写入会话头使会话在第一条消息之前可见，并发出与经典 in-core 循环相同的 `ev.session.<id>.*` 事件。会话是临时的：历史存在于存储中，因此新的运行器在下次调用时恢复会话。`NIF_RUNNER_IDLE_S`（默认 600 秒）内没有会话调用的运行器优雅退役，并在下次调用时重新创建；空闲时钟在回合完成时打戳，因此长回合算作活动，而不是空闲。杀死运行器只杀死那个会话 —— 进程是隔离单元。回合从不以任何方式嵌套。除了 `.call`，运行器服务五个每会话主题，每个携带相同的会话 id：`.steer`（回合中转向）、`.advise`（专家建议，从空闲槽回答）、`.map`（repo-map 自动追加）、`.diag`（由 `edit` 推送的异步诊断）和 `.tool`（fabric 和子代理使用的嵌套会话调用代理）。

删除会话是一个门控的 core 工具，对 LLM 隐藏：`conversation_delete` 先停止该会话的运行器（否则活回合会复活记录），然后移除头、消息、冻结工具集、子代理谱系和作业记录。

stdin/stdout tty（`make run`）是**管理 shell**，不是会话 UI：它只检查 harness 本身 —— `help`、`status`、`catalog`、`tools`、`sessions`、`exit` —— 带方向键历史和 tab 补全（见 `core/tty.nim`）。LLM 聊天位于 `niffler-tui` 终端客户端和 Web UI 中；脚本通过 `cli` 组件进行。

### Clients and the UI registry

每个交互式前端在总线上注册为零工具组件并保持租约存活：core 的隐藏 `ui` 工具 —— `register`、`renew`、`release`、`owner`，加上用于每会话所有权的 `claim`/`release_session` —— 跟踪哪个窗口拥有哪个会话（名为 `ui` 的组件是桌面桥，不是此工具）。租约持续 20 秒，过期租约在每次请求时惰性清扫 —— 不存在定时器线程。显示编号（“Niffler 1”、“Niffler 2”）在 harness 生命周期内单调。这是协调，不是认证：它决定哪个窗口渲染会话，仅此而已。在 `/restart` 之后，继任者从交接记录（TTL 120 秒，以总线 + 工作区为键）采用其前任的 ui id，因此会话及其“Niffler N”标签存活。

### Store engines

存储的**总线契约就是产物**：`put/get/list/del`、`expectRev` 乐观并发、按 id 排序的列表（docs/WIRE.md）。多个引擎实现该契约，并以组件 `store` 注册，提供完全相同的工具——消费者永远不会知道当前运行的是哪个引擎。选择是启动时的一次决定：`NIF_STORE_BACKEND=sqlite|barrel|tidb`（默认 `sqlite`）；core 据此解析清单条目中的二进制，遇到未知值则拒绝启动。未设置 `NIF_STORE_BACKEND` 是默认，不是强制要求：当 `var/bin/store-sqlite` 从未构建时，core 会发出警告并启动清单中的二进制（`var/bin/store`，即 barrel）。显式设置的值则是强制要求——二进制缺失只会发出警告，绝不会被静默替换为另一个引擎的数据库。

- **sqlite**（默认，`var/bin/store-sqlite`，Go）：在 SQLite 上实现同一套文档契约。文档以 JSON TEXT 原样存储；`put` 是一条原子语句（文档与 rev 一起移动——KV 引擎的双键崩溃窗口不复存在）；schema 通过内嵌的 goose 迁移管理；纯 Go 驱动（`modernc.org/sqlite`，无 cgo）。数据文件 `var/store.db`（WAL），可用任何 SQLite 工具内省（`sqlite3 var/store.db 'select kind, count(*) from docs group by kind'`），也可从 DuckDB 以只读方式挂载用于离线分析。自上下文压缩落地以来成为默认：上下文投影需要原子写入和可范围读取的列表（docs/research/COMPACTION.md §2）。SQLite 的 pragma 是代码内置的，不可配置（`_txlock=immediate`、WAL、`synchronous(NORMAL)`、10 秒 `busy_timeout`、单个池化连接），goose 迁移在启动时自动应用。
- **barrel**（`var/bin/store`）：内嵌的 BitBarrel KV（Bitcask 风格），位于 `var/barrel-db`——设计上无 schema，零依赖，久经考验。仍完全支持（`NIF_STORE_BACKEND=barrel`）；其 `put` 是双键序列（先文档，后 rev）：两者之间崩溃可能导致内容更新而修订号未更新，而对于*新*文档，文档键写入时根本没有 rev 键，`get` 和 `list` 会将其读作不存在（`rev == 0`）——该文档在再次写入之前不可达。
- **tidb**（`var/bin/store-tidb`，Go）：在 MySQL 协议（go-sql-driver）上实现同一套 schema——一个网络共享存储，任意数量的 harness 都可以从它提供服务。`NIF_STORE_TIDB_DSN` 指向集群（`root@tcp(host:4000)/niffler`；单节点 docker：`docker run -p 4000:4000 pingcap/tidb`）。`value` 保持 MEDIUMTEXT，而非原生 JSON 类型——二进制 JSON 会规范化键顺序和数字精度，破坏原样文档契约；索引查询稍后以 TEXT 上的生成列形式出现（一次 goose 迁移）。`kind`/`id` 为 utf8mb4_bin：字节精确相等、字节序列表排序和区分大小写的 LIKE 前缀（与其他引擎的契约对等）。无 flock——集群按设计就是共享状态；行锁（`SELECT … FOR UPDATE`，悲观事务）仲裁写入者，rev 计数器仍是乐观并发检查。也可用于普通 MySQL 8。DSN 用户需要 goose 创建版本表并应用迁移所需的权限；连接/读/写超时是硬编码的（5 秒 / 60 秒 / 30 秒），引擎持有单个池化连接（一个会话，因此 `FOR UPDATE` 事务的语句保持在一起）——一个集群上的 N 个 harness 持有 N 个连接，不共享连接池。

除根目录和引擎选择之外，各引擎不接受任何配置：文件路径、锁路径、pragma、超时和连接池大小都是代码内置的（`NIF_ROOT` 决定根目录，`NIF_STORE_BACKEND` 决定引擎，`NIF_STORE_TIDB_DSN` 决定集群）。

基于文件的引擎（`sqlite`、`barrel`）以相同方式强制单写入者：一个进程拥有该文件（flock；崩溃时由内核释放），其他所有进程通过信封通信。`tidb` 没有文件可锁——集群按设计就是共享状态，行锁加 rev 计数器在 harness 之间仲裁。

`list` 是一个**页**，不是完整视图：`limit` 默认为 100，并被钳制到 1000，回复携带 `hasMore` 以及 `nextAfter` id 游标。将 `nextAfter` 作为 `after` 传回以遍历其余部分——`after` 是排他的，当 `hasMore` 为 false 时 `nextAfter` 不存在。存储保留完整历史，因此一段长对话无法在一次调用中装下；core 自身的全 kind 读取（resume、`session_info`、`conversation_delete`）会自动分页。

存储契约是对每个引擎运行同一套测试：`make test-store`（所选/默认引擎）、`make test-store-sqlite`、`make test-store-tidb`（需要 `NIF_STORE_TIDB_DSN`，否则打印 SKIP）；`t_store_paging` 固定了 resume 和迁移所依赖的 `after`/`hasMore`/`nextAfter` 游标语义。

### Migrating between engines

**切换引擎不会移动数据。** 升级后，历史位于 `var/barrel-db` 的 harness 会拒绝启动，而不是打开一个空的 `var/store.db` 并看起来像丢失了所有对话：

```
core: this harness has conversation history in var/barrel-db, but the
      default store engine is now SQLite and no var/store.db exists yet.
core: migrate first (nothing is moved automatically):
core:     niffler-store-migrate --root /path/to/harness
core: scan for other un-migrated roots (benchmarks, clones):
core:     niffler-store-migrate --scan
core: or keep using the old engine: NIF_STORE_BACKEND=barrel
```

`niffler-store-migrate`（位于 `var/bin`）**离线**运行——它启动自己私有的 NATS 服务器和存储进程，因此无需启动任何 harness，并且它从不编辑源数据。存储契约无法枚举 kind（`list` 需要一个 kind），因此它读取**它所探测的 kind** 的每个文档——该候选列表是对 harness 当前写入的每个 kind 的经过验证的普查（`agentjob`、`agentnotice`、`approval`、`compaction_input`、`component`、`context_projection`、`contextreceipt`、`conversation`、`fabricprog`、`mcp`、`message`、`plugin`、`profile`、`session`、`sessionmeta`、`slash`、`spill`）——收尾验证则按 kind 遍历它实际**搬运**的 kind，逐一对照目标。之后添加到 harness 的 kind 仍会被静默跳过，直到普查被扩展（总线无法看到它），这就是为什么该列表维护在存储的 kind 表旁边。
当前接线的方向是 barrel → `sqlite`（默认）或 barrel → `tidb`（带 `--to tidb`）；仅含 SQLite 的根会被拒绝，提示 "root already uses sqlite — nothing to migrate"。每个文档被重放到全新的目标中，然后按 kind 验证。各标志（`--root`、`--to <engine>`、`--dry-run`、`--scan [<top>]`、`--all [<top>]`、`--force`）由工具自身的 `--help` 描述；`--force` 覆盖已存在的目标数据库（旧数据库被移到一旁，命名为 `<name>.<timestamp>.aside`），每个阶段背后的设计见 [research/STORE_V2.md](research/STORE_V2.md) 的 "Moving data between engines"。

`--scan` 查找顶层目录、同级克隆和基准测试树（`var/bench/**/niffler-root`）。迁移拒绝在同时持有 `var/barrel-db` 和 `var/store.db` 的根上运行——这是迁移完成后留下的状态，此时重新运行会失败并提示 "ambiguous source; move one aside first"（将过时的 `var/store.db` 移到一旁即可重复）。回滚只需 `NIF_STORE_BACKEND=barrel`，因为 barrel 文件未被改动；反方向移动数据——从 SQLite 或 TiDB 迁出——尚未接线。

## State and configuration

Niffler 没有单一的配置文件。状态分布在五个地方，按生命周期选择：启动决策是环境，身份/选择是存储，每对话选择是对话头，显示是浏览器，一切派生的东西都在 `var/`（可重新生成——删除它并执行 `make build` + 一次启动即可重建整个世界）——**但 agent 构建的组件除外**：`builder.build` 仅将其源码保存在 `var/build/` 下，仅将其二进制保存在 `var/bin/` 下，持久化的 `component` 记录两者都不存储，因此当这些输出消失而存储仍在时，下次启动会警告 `stored component <name> has missing binary` 并跳过它。用 `builder.build` + `core.spawn` 重建它，或用 `core.remove` 删除该记录。

| Where | What | Lifetime |
|---|---|---|
| **Environment / `.env`** | 所有 `NIF_*` 变量（见下表）：启动与总线、LLM 连接、每组件调优。`.env`（根目录，gitignored）保存密钥和本地覆盖；shell 环境优先；带默认值的参考副本在 `.env.example` | 进程生命周期——组件在启动时读取一次环境，因此更改需要 `core.kill` + `core.spawn`。*在启动 core 的 shell 中导出的*变量会被每个子进程继承，需要重启 harness |
| **The store**（kind 表见 [The store](#the-store)） | 对话头、消息、`provider` 注册表（含凭据）、冻结的每对话工具集、slash 表、插件/组件安装记录、子代理作业/血缘记录、fabric 程序、MCP 服务器配置 | 持久——harness 的数据库 |
| **Conversation header**（`conversation` kind） | 每对话选择：provider、providerOverride、model、modelOverride、thinking、profile、title、预算/token 计量——通过 `session` 调用设置（UI 中的 `/model`、`/effort`），并在轮次结果中回显 | 每对话 |
| **Home / project files** | skills 树（项目 `.agents|.claude|.opencode/skills` > 内置 `skills/` > home `~/.niffler/skills` + agent 标准目录 > `~/.config/opencode/skills`，最后是编译进二进制的树作为最后手段）；LSP 注册表 `~/.config/niffler-lsp/servers.json`（`NIF_LSP_REGISTRY`） | 持久，用户可编辑 |
| **Home files (edit undo store)** | `$XDG_CONFIG_HOME/niffler-edit/undo.json`（否则 `~/.config/niffler-edit/undo.json`）：每个文件上次编辑前的字节，加上每对话的已见状态摘要。每个被编辑文件一条记录，无大小上限也无淘汰——它随被编辑的不同文件数量增长，随时可安全删除（删除它只会丢失撤销历史和未更改读取的存根，绝不丢失文件内容） | 持久，用户可编辑 |
| **`var/`**（gitignored） | `bin/` 构建的二进制，`logs/` 总线 JSONL 和每组件 JSONL（`.1`…`.N` 轮转）加上子进程日志，`models/` 目录缓存，`nats-url`/`nats-pid` 总线认领，`processes/` 假脱机（每次启动的 `pN.out`/`pN.err`，启动时清空；id 从持久化计数器继续，而不是从 `p1` 重新开始），`repomap-tags/` 每文件标签缓存（以绝对路径的 sha1 为键的 `{mtime, tags}` JSON；空结果从不缓存），`fetch/`、`captures/`、`store.db`（SQLite 引擎的文件）或 `barrel-db`（barrel 引擎的）——取决于 `NIF_STORE_BACKEND` 选择了哪个——加上其 `.lock`，同一时间只能有一个 `store` 进程持有 | 运行时，可重新生成 |
| **Browser localStorage** | 仅显示：推理/工具卡详情级别、locale（`niffler-think`、`niffler-tools`） | 每浏览器 |
| **Repo files** | `manifest.yaml`（随附的组件注册表）、`skills/`（内置 skills）、构建文件（`config.nims`、`*.nimble`、`Makefile`） | 版本化 |

值得了解的优先级规则：shell 环境优先于 `.env`；活动的 `provider` 优先于 `NIF_OPENAI_*`；对话的冻结工具集快照优先于实时目录（这正是 resume 字节稳定的原因）；skill 树按项目 > 内置 > home > config 的顺序遮蔽。`lsp` 组件还额外将构建文件（`go.mod`/`go.work`、`tsconfig.json`/`package.json`、`*.nimble`/`config.nims`、`Cargo.toml`）视为仓库*标记*——从哪里开始遍历，而不是它解析的配置，而 `repomap` 将此类标记文件作为裸条目列在其映射中；`skills` 仅使用固定目录。

此表中的环境变量部分是将迁移到存储中作为全局设置并配以 `/settings` 命令的候选——其设计（优先级 `conversation header > store settings > env > code default`，哪些键在第 1 阶段迁移，哪些永远留在环境）见 `research/SETTINGS.md`。

## Environment variables

所有组件加载 `.env`（从 harness 根目录和 cwd，已存在的 shell 环境始终优先——见下文）并继承 core 的环境。`NIF_BIN_DIR`、`NIF_BUILD_LOCK`、`NIF_STORE_BIN`、`NIF_REPO_ROOT` 和 `NIF_LSP_BIN` 是仅用于构建和脚本的旋钮（`NIF_NATS_CLI` 是例外——生成的 bash 组件 `dialog` 将其作为最后手段的 nats CLI 读取）：它们引导 `make` 和 `scripts/`，随附组件从不查询它们——仅测试用的 `ctxtest` 夹具读取 `NIF_REPO_ROOT` 以加载 fabric 示例——因此它们不属于下面运行时表的一部分。`NIF_LSP_BIN` 在那里仍有一行：它是 `make install-lsp` 的目标目录，其默认值（`~/.local/bin`）也是 `lsp` 组件搜索的位置。完整集合：

| Variable | Meaning | Default |
|---|---|---|
| `NIF_ROOT` | harness 根目录（仓库）。未设置时 core 从其二进制位置推导，并为所有子进程设置它。组件用它来查找 SDK、`var/`、`.env`。每个组件都以 **cwd = NIF_ROOT** 运行，因此 agent 的 `bash pwd` 始终是 home——无论你从哪里启动 harness | `<binary location>/../..` |
| `NIF_NATS_URL` | 总线地址。在**环境**中（测试、bench、脚本）：仅附加——core 使用恰好那个总线。在 **`.env`** 中声明（或众所周知的 `nats://127.0.0.1:4222`）：克隆的 **home 总线**——空闲时认领，仅当应答的 core 服务此根目录时才附加（身份通过目录的 `root` 字段），对外来 core 或裸 nats-server 大声让出（改用隔离的随机总线；先回收记录的遗留 `var/nats-pid`），并写入 `var/nats-url` | 自动 |
| `NIF_NATS_SPAWN` | `1` 强制在随机端口上使用隔离的 core 拥有的总线——绝不用 4222，绝不附加（开发克隆和测试）。有显式 `NIF_NATS_URL` 时 URL 优先 | 未设置 |
| `NIF_AUTOSTART` | 当 UI 不得不生成 core 时由 SDK 的 `ensureHarness` 设置：该 core 在最后一个交互式客户端离开时退出（见 Starting and stopping） | 未设置 |
| `NIF_AUTOSTART_IDLE_S` | 最后一个交互式离开后，自动启动的 core 退出前的秒数 | `10` |
| `NIF_AUTOSTART_BOOT_S` | 自动启动的 core 在放弃前等待其第一个交互式客户端的秒数 | `60` |
| `NIF_ENSURE_ATTACH` | `0` 使 `ensureHarness` 跳过附加并始终生成 core（测试） | `1` |
| `NIF_STORE_BACKEND` | 启动时选择的存储引擎：`sqlite`（默认 → `var/bin/store-sqlite`）、`barrel`（→ `var/bin/store`）、`tidb`（→ `var/bin/store-tidb`）；其他任何值都拒绝启动。所有引擎以组件 `store` 注册，提供完全相同的工具——见 [Store engines](#store-engines)。未迁移的 barrel（历史在 `var/barrel-db`，尚无 `var/store.db`）使 core 拒绝启动并给出 `niffler-store-migrate` 指令；此处的 `barrel` 是逃生舱。**未设置**值且其引擎二进制缺失（`var/bin/store-sqlite` 不存在）时警告并回退到 `var/bin/store`——显式请求绝不回退 | `sqlite` |
| `NIF_STORE_TIDB_DSN` | `tidb` 存储引擎的 TiDB/MySQL DSN，例如 `root@tcp(127.0.0.1:4000)/niffler`（docker 单节点：`docker run -p 4000:4000 pingcap/tidb`）。该引擎必需——无本地默认；组件没有它会拒绝启动。除非 DSN 设置 `time_zone`，会话被强制为 UTC。账户需要 goose 的 DDL 迁移权限，每次启动时应用（先是一个全新的数据库，然后每个新迁移随发布应用）；连接/读/写超时（5 秒/60 秒/30 秒）和单个池化连接是代码内置的，不可通过环境调优 | 未设置 |
| `NIF_GIT_MIRROR` | 当 `plugins` 组件克隆包时替换 `https://github.com` 的主机前缀（例如 `https://cnb.cool` 或 Gitee 镜像）——API/搜索端点仍留在 GitHub | 未设置 |
| `NIF_NPM_REGISTRY` | `builder` ts 组件安装的 npm registry（例如 `https://registry.npmmirror.com`） | npm 默认 |
| `NIF_OPENAI_API_KEY` | LLM 适配器（`llm`）的 API 密钥。任何对话轮次都需要；完全没有密钥时适配器在任何 HTTP 请求之前就拒绝（`provider "default": no API key (set NIF_OPENAI_API_KEY or NIF_LLM_PROVIDERS apiKey)`），这与密钥存在但被拒绝（HTTP 401/403）是不同的症状 | — |
| `NIF_OPENAI_BASE_URL` | OpenAI 兼容端点 | `https://api.openai.com/v1` |
| `NIF_OPENAI_MODEL` | 模型名称 | `deepseek-chat` |
| `NIF_OPENAI_PROVIDER` | 默认 LLM 连接的 models 目录 provider id；未设置时推断常见端点 | 推断 |
| `NIF_OPENAI_CONTEXT` | llm 向 core 的上下文守卫报告的显式上下文窗口（token）。解析顺序：存储的 provider `context` → 此值 → `models` 目录 → `llm` 的内置表（`deepseek-chat`/`deepseek-reasoner` 1M，`syn:large:text` 524288，`zai-org/glm-5.3-flash` 524288——代码内置，因此新模型需要改源码）→ 128000（`llm-openai` 替换示例仅解析 `NIF_OPENAI_CONTEXT` → 一个两项的 `deepseek-chat`/`deepseek-reasoner` 表 → `128000`，并在每次调用时重新读取该变量） | `models` 目录，然后内置表，然后 `128000` |
| `NIF_AGENT_MODEL_WEAK` / `NIF_AGENT_MODEL_MEDIUM` / `NIF_AGENT_MODEL_STRONG` | 请求 `modelTier` 时新子代理使用的确切模型 id；子代理层级被钳制到父代理配置的层级 | 未设置 |
| `NIF_AGENT_DEFAULT_TIER` | 当父代理的确切模型不在配置的阶梯中时使用的层级上限（`weak`、`medium` 或 `strong`） | `strong` |
| `NIF_AGENT_WAKES` | 后台子代理在对话空闲时结算后，对话可运行的连续自主唤醒轮次数（docs/WIRE.md "Autonomous wake"）；人类的下一条消息重置预算，`0` 禁用唤醒（通知随后等待下一轮次的拉取排空） | `3` |
| `NIF_AGENT_NOTICE_HOLD` | `0` 允许轮次在其最后一步期间收到结算通知时仍关闭（通知等待下一轮次的排空）；默认情况下轮次被多保持一步，以免在刚完成的子代理之上关闭（docs/WIRE.md "Busy-parent inbox"） | `1` |
| `NIF_LLM_PROVIDERS` | 命名 provider 的 JSON 对象 `{nickname: {baseUrl, apiKey, model, context, catalog, protocol?, authType?, accountId?, stripPrefix?}}`，由 `chat` 工具的 `provider` 参数解析。`protocol` 为 `openai-chat`（默认）、`anthropic` 或 `openai-codex`；`authType` 默认为 `api_key`；`stripPrefix` 为按规范 id 路由的网关重写带命名空间的 id（`alibaba/glm-5.2` → `glm-5.2`）；`accountId` 是 Codex 通道头部携带的 ChatGPT 账户 id，当记录未持有时从 OAuth token 推导（两者都没有时，调用失败并提示 `OpenAI Codex OAuth token has no ChatGPT account id; sign in again`）。格式错误的 JSON 和缺失的 `apiKey` 各自显式使调用失败。provider 注册表（`provider` 组件）激活时取代默认 | `{}` |
| `NIF_MODELS_URL` | models.dev 兼容的目录基础或 JSON 端点 | `https://models.dev/api.json` |
| `NIF_MODELS_PATH` | 固定的本地基线目录：设置期间，此文件*就是*基线——组件从不下载 `NIF_MODELS_URL`（即使 `models_refresh {force: true}` 也不），并在下次刷新时拾取文件更改。插件源和 `NIF_MODELS_OVERRIDE` 仍然适用 | 未设置 |
| `NIF_MODELS_OVERRIDE` | 在每个插件源之后应用的本地 JSON Merge Patch | 未设置 |
| `NIF_MODELS_OFFLINE` | `1` 阻止组件下载 models.dev；缓存/种子基线和每个插件源仍被使用，源工具仍被调用。与 `NIF_MODELS_REFRESH_INTERVAL=0` 结合可获得完全静态的目录 | 未设置 |
| `NIF_MODELS_CACHE_DIR` | 目录和源补丁缓存 | `$NIF_ROOT/var/models` |
| `NIF_MODELS_CACHE_TTL` | 重新获取基线前的最小年龄；`0` 禁用缓存窗口，因此每次刷新都重新获取它 | `5m` |
| `NIF_MODELS_REFRESH_INTERVAL` | 后台刷新间隔；`0` 禁用 | `1h` |
| `NIF_FETCH_DIR` | 大型 fetch 结果和临时提取文件 | `$NIF_ROOT/var/fetch` |
| `NIF_FETCH_ALLOW_PRIVATE` | `1`（也接受 `true`/`yes`）允许 `fetch` 工具联系 loopback/私有/link-local 目的地；仅用于受信任的本地开发服务 | 未设置（阻止） |
| `NIF_SKILLS_BUNDLED_DIR` | `skills` 组件内置树的显式位置，替换 `<repo>/skills` 及其 `$NIF_ROOT/skills` 回退。不存在的路径使发现服务编译内置的副本（目录 `(baked)`） | `<repo>/skills` |
| `NIF_MCP_DIRECT_THRESHOLD` | 配置为 `expose: direct` 的 MCP 服务器可直接发布的缓存工具数量；更大的服务器推迟到渐进式发现 | `10` |
| `NIF_MCP_BRIDGE_BIN` | mcp-bridge 二进制的显式路径 | `<root>/var/bin/mcp-bridge` |
| `NIF_PROCESSES_SPOOL_CAP` | `processes` 假脱机大小，超过后后台进程的输出文件在下次轮询时被截断到其尾部——保留的尾部为 `min(2 MiB, cap div 2)`，且该值不被验证，因此上限为零或以下会清空假脱机 | `33554432` |
| `NIF_PROCESSES_POLL_CHUNK` | 一次 `process_poll` 每流返回的最大新字节数（保持在假脱机上限以下，以便突发总是被拆分；钳制到 1 KiB-1 MiB） | `65536` |
| `NIF_LSP_REGISTRY` | 语言服务器用户注册表（`servers.json`）的绝对路径 | `$XDG_CONFIG_HOME/niffler-lsp/servers.json` |
| `NIF_LSP_WARM_MAX` | 在 `ev.workspace.opened` 时每工作区预启动的重型（持有索引）语言服务器 | `2` |
| `NIF_LSP_WARM_CHEAP` | 预启动的廉价（非索引）服务器，来自它们自己的预算——它们绝不挤占重型选择 | `1` |
| `NIF_LSP_WARM_TOTAL` | 每工作区预启动进程的上限 | `4` |
| `NIF_LSP_BIN` | `make install-lsp` 使用的安装目录（服务器包装器和用户本地 JDK）；也作为默认回退 bin 目录解析 | `~/.local/bin` |
| `NIF_LSP_BIN_DIRS` | 在 PATH 之外搜索服务器二进制的额外目录（冒号分隔；前导 `~` 表示你的 home 目录） | — |
| `NIF_TRAFILATURA` | Trafilatura 可执行文件路径/名称；`off` 禁用外部提取 | 在 `PATH` 上自动检测 `trafilatura` |
| `NIF_LOG_LEVEL` | SDK 结构化日志发布阈值（`debug`、`info`、`warn`、`error`） | `info` |
| `NIF_LLM_MAX_RETRIES` | 对瞬时 LLM 失败（429/5xx/过载/连接断开）的额外尝试次数，带指数退避；每次重试宣告 `ev.session.<id>.retry`。认证/配额/错误请求错误始终快速失败 | `2` |
| `NIF_LLM_MAX_STREAM_RETRIES` | 流式响应中途断开时的额外尝试次数——与一般情况分开预算，因为断开的流可能已经计费了输出 | `2` |
| `NIF_LLM_MAX_CONNECT_RETRIES` | 连接/拨号失败的额外尝试次数 | `2` |
| `NIF_LLM_RETRY_AFTER_CAP_MS` | 从服务器 `retry-after` 提示遵守的上限：`llm` 包装 HTTP 客户端，解析 `Retry-After`（秒或 HTTP 日期）并将 `; retry-after-ms: <n>` 附加到 provider 的错误，以便 core 可以遵守等待，而无需每个适配器依赖同一个客户端库；提示的等待超过此上限时被钳制，无效或缺失的头部使错误保持不变 | `3600000` |
| `NIF_LLM_TIMEOUT_MS` | 一次 `llm` `chat` 完成的上限；慢速推理模型（例如通过 llmgateway 的 GLM thinking=max）在单个响应上可能超过默认值 | `300000` |
| `NIF_CTX_RESERVE` | 上下文准入保留的输出 token；默认为模型解析的目录输出上限，未知时为 `16384`；`0` 禁用保留 | 目录输出上限 |
| `NIF_COMPACTION_TOOL` | 运行器选择的契约 v1 候选工具；空禁用摘要但不禁用 prune/trim/错误准入 | `compaction_propose` |
| `NIF_COMPACTION_TIMEOUT_MS` | 整个候选调用截止时间，钳制到 5000–600000 毫秒；运行器将其作为分派界限（`budget.timeoutMs`）传递，候选工具自身的 `x-harness.timeoutMs` 是同样的 600000 上限，因此直到钳制值的配置才是运行器实际等待的（高于钳制的值仍只延长组件的辅助调用截止时间——运行器先放弃，快照等待 600 秒清扫） | `90000` |
| `NIF_COMPACTION_MAX_LLM_CALLS` | 授予一次尝试的辅助摘要调用预算，钳制到 1–16；报告调用次数超过授予的候选被拒绝为无效，授予的数量缩放请求的 `maxTotalInputTokens`/`maxTotalOutputTokens`。随附的 `compaction` 组件始终恰好进行一次辅助调用并报告 `llmCalls: 1`——该预算是为迭代的摘要器准备的 | `4` |
| `NIF_COMPACTION_MAX_SUMMARY_TOKENS` | 每次调用检查点输出上限，钳制到 128–32768，随附组件下限为 128 | `4096` |
| `NIF_OBSERVE_RING` | observe 全局环中保留的消息数；接受范围 1–10000，超出则组件以非零退出 | `2000` |
| `NIF_OBSERVE_RING_BYTES` | 全局环中保留的近似线上字节数；接受范围 65536–104857600 | `16777216` |
| `NIF_OBSERVE_ENTRY_BYTES` | 每条被观察消息保留的最大字节数；接受范围 1024–1048576，更大的消息保留为上限四分之三的 base64 预览 | `65536` |
| `NIF_OBSERVE_MAX_PROBES` | 同时保留的活动 + 已停止探针；接受范围 1–256，达到界限时下一个 `observe_listen`/`observe_trace` 失败并提示 `probe limit reached` | `32` |
| `NIF_OBSERVE_PROBE_BYTES` | 每探针保留的字节数；接受范围 65536–16777216，条目按最旧优先淘汰，单个超过上限的条目计入 `dropped` | `2097152` |
| `NIF_OBSERVE_CAPTURE_DIR` | `observe_dump` 的受限目录 | `$NIF_ROOT/var/captures` |
| `NIF_OBSERVE_CAPTURE_BYTES` | 生成的捕获聚合配额；最旧的文件被修剪。接受范围 65536–1073741824，当即使修剪也无法容纳一次转储时，工具失败并提示 `capture directory quota is exhausted` | `67108864` |
| `NIF_OBSERVE_MONITOR_URL` | 外部/复用总线的显式 nats-server HTTP 端点 | core 发现文件 |
| `NIF_LOGFILE_DIR` | JSONL 输出目录——绝对路径按原样使用，相对路径针对 harness 根目录解析 | `$NIF_ROOT/var/logs` |
| `NIF_LOGFILE_SUBJECTS` | 要持久化的逗号分隔 NATS 模式，启动时验证：格式错误或超过 512 字节的模式、超过 64 个唯一模式或空列表使组件以非零退出 | `ev.log.>` |
| `NIF_LOGFILE_MAX_BYTES` | 轮转前每个 JSONL 文件的活动字节数；接受范围 256–104857600，超出则组件以非零退出 | `10485760` |
| `NIF_LOGFILE_KEEP` | 保留的轮转代数（`0` 禁用）；接受范围 0–100，超过该值的代数在每次启动时删除 | `5` |
| `NIF_LOGFILE_MAX_FILES` | 回退到 `bus.jsonl` 之前的组件特定文件数；接受范围 1–1024，启动时已存在的 JSONL 文件计入其中 | `64` |
| `NIF_LOGFILE_SCAN_BYTES` | 一次 `logfile_search` 检查的最大字节数，接受范围 1024–104857600，在该搜索的所有文件间共享 | `16777216` |
| `NIF_LOGFILE_DIRECTORY_ENTRIES` | 每次查询枚举的最大候选 JSONL 路径数；接受范围 100–100000，也适用于 `logfile_paths`，截断报告为 `directoryTruncated` | `10000` |
| `NIF_AUTO_APPROVE` | `1` → 审批门（见下文）被绕过，每个 `/limit` 继续问题都以是回答（它隐含 `NIF_AUTO_CONTINUE`）。仅用于无头自动化；绝不要在你关心的会话中设置它 | 未设置 |
| `NIF_AUTO_CONTINUE` | `1` → 达到对话软限制之一（`/limit`）的轮次继续而不询问（`NIF_AUTO_APPROVE=1` 隐含它）。仅用于无头自动化 | 未设置 |
| `NIF_MAX_TURN_ROUNDS` | 每轮次的硬 LLM 轮次上限；显式的每会话 `maxRounds` 可以收窄它 | `1000` |
| `NIF_MAX_DIRECT_TOKENS` | 对话直接工具集的估计 token 上限，用于 `invoke {sticky: true}` 提升；会超过它的提升被推迟并在工具结果中报告 | `4000` |
| `NIF_PROFILE` | 新对话的默认命名工具 profile，当 `session` 调用不携带 `profile` 参数时使用 | 未设置 |
| `NIF_AGENT_MAX_DEPTH` | 限制 `agent_spawn` 委托可以嵌套的深度（core 在分派时强制执行；agent 组件镜像它）。`0` 禁止委托；生成工具在上限处仍可见 | `1` |
| `NIF_HOOKS_EVENTS` | hooks 组件监视的逗号分隔总线主题，带 NATS 通配符（`*` 一个 token，尾随 `>` 其余）。启动时读取——配置更改是 `core.kill` + `core.spawn` | `ev.session.*.turn` |
| `NIF_HOOKS_<SUBJECT>` | 为一个被监视主题运行的 shell 命令（点和通配符变为 `_`，`*.` 和 `>.` 折叠：`ev.session.*.turn` → `NIF_HOOKS_EV_SESSION_TURN`，`ev.log.>` → `NIF_HOOKS_EV_LOG__`）；事件负载作为 JSON 通过 stdin 管道传入 | 未设置 |
| `NIF_HOOKS_TIMEOUT_MS` | 每 hook 超时，钳制到 100–60000 毫秒；超时杀死 hook 并记录退出码 124 | `10000` |
| `NIF_MCP_REGISTRY_URL` | 外部 MCP 服务器目录的基础 URL（气隙/代理设置） | `registry.modelcontextprotocol.io` |
| `NIF_MCP_PROBE_TIMEOUT_MS` | `mcp_add`/`mcp_edit` 中一次真实连接探测的超时（桥自身的 `--probe` 模式也读取它，因此手动运行的探测遵守它）：设置（正值）时它优先于 30 秒默认值和服务器自身的 `timeoutMs` | `30000` |
| `NIF_READ_OUTLINE_LINES` | 整读行阈值，超过后 read 返回语言服务器符号大纲而非原始窗口；`0` 禁用大纲 | `1000` |
| `NIF_REPOMAP_AUTOAPPEND` | 工作区打开时的 repo-map 自动追加默认开启，仍受普查/内容准入门约束（`docs/research/REPOMAP-GATES.md`）。`0` 选择退出；`1` 显式选择加入。`repo_map` onDemand 工具不受影响 | `1` |
| `NIF_REPOMAP_MIN_CENSUS` | 追加的普查文件下限：覆盖源文件更少的工作区从不被映射（docs/research/REPOMAP-GATES.md）。门是仅追加的——`repo_map` 从不被门控，小映射是对显式问题的好答案 | `50` |
| `NIF_REPOMAP_MIN_BYTES` | 追加内容门：渲染的映射低于此字节数即为存根并被扣留。门是仅追加的——`repo_map` 从不被门控 | `800` |
| `NIF_REPOMAP_MIN_SYMBOLS` | 追加内容门：渲染的符号行最小值。门是仅追加的——`repo_map` 从不被门控 | `25` |
| `NIF_REPOMAP_MIN_FILES` | 追加内容门：带符号文件最小值。门是仅追加的——`repo_map` 从不被门控 | `5` |
| `NIF_RUNNER_IDLE_S` | 会话运行器在此时间内没有会话调用则退役；下一次调用生成一个新的（子代理子进程按需重新确保） | `600` |
| `NIF_WRITE_MAX_BYTES` | `write` 工具整文件负载的上限 | `900000` |
| `NIF_OAUTH_CALLBACK_HOST` | 本地 OAuth 回调监听器的主机（端口固定为 1455/53692） | `127.0.0.1` |
| `NIF_LOG_MAX_MB` | core 在 `var/logs` 中子进程日志保留上限（MB） | `200` |
| `NIF_LOG_RETENTION_DAYS` | core 在清扫前保留子进程日志的天数 | `7` |
| `NIF_SPAWN_WAIT_MS` | `core.spawn` 在新组件于目录中注册之前等待多久才使调用失败（钳制 250–120000）；当目录记录拒绝时等待提前结束，因此该旋钮仅约束静默组件 | `5000` |

**构建和脚本旋钮**——由 harness 周围的脚本读取，组件从不读取：`NIF_BIN_DIR`（`scripts/install.sh` 将 PATH 条目链接到的 bin 目录）、`NIF_BUILD_LOCK`（`scripts/with-build-lock.sh` 加 flock 的锁文件——构建时排他，测试运行时共享）、`NIF_NATS_CLI`（`components/dialog/dialog.sh` 驱动的 nats CLI——此处唯一一个组件确实读取的条目：仅当 `nats` 既不在 `PATH` 上也不在 `$HOME/go/bin` 中时才查询它）、`NIF_CONF_KEEP`，加上测试辅助 `NIF_STORE_BIN` 和 `NIF_REPO_ROOT`。`NIF_LSP_BIN` 和 `NIF_LSP_BIN_DIRS` 是运行时变量，留在上表中。锁仅覆盖 `make`：`builder.build` 在其之外运行，因此运行时组件构建可能与 `make build` 竞争——而 `make clean` 在其下删除 `var/bin` 和 `var/build`。当 agent 正在构建组件时停止 harness。

每个 Niffler 变量都带有 `NIF_` 前缀，因此 harness 从不与使用裸约定的工具（`NATS_URL`、`OPENAI_API_KEY`）冲突。

### The `.env` file

`.env`（仓库根目录，gitignored）保存本地密钥/配置：

```bash
NIF_OPENAI_API_KEY=sk-...
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1
NIF_OPENAI_MODEL=deepseek-chat
```

加载规则（Nim、Go 和 TypeScript SDK 中相同）：已存在的 shell 环境**始终优先**于 `.env`；SDK 先加载当前目录的 `.env`，再加载 harness 根目录的，键的首次定义优先。桌面 UI 桥以相反顺序加载它们（harness 根目录，然后 cwd——`ui/bridge.go`），因此那里根文件优先。所以 `NIF_OPENAI_API_KEY=other ./var/bin/niffler` 覆盖文件，如果你想使用文件值，在启动前 `unset NIF_OPENAI_API_KEY`。`.env` 必须是普通常规文件：符号链接或硬链接的副本被拒绝，文件上限为 1 MiB，值从不进行 `$VAR` 展开。

仓库根目录中的 `.env.example` 是参考副本——每个变量都被注释掉，其默认值作为注释值——但它在两个方向上都不详尽（上表中的少数条目在其中缺失，且它携带 harness 在正常操作中不读取的测试/工具变量）；该表是权威。

## The bus in one screen

Core 只讲一种协议：NATS 上的 JSON 信封（详见
[WIRE.md](WIRE.md)）。主题——你在运维中会遇到的主干，而非完整清单（每个组件
还会发布自己的事件族：来自 SDK 的 `ev.log.<component>`、`ev.lsp.warm`、
`ev.agent.*`、`ev.fabric.*`）：

```
reg.publish            component announces itself: {name, version, pid, tools:[{name, schema}]}
reg.depart             graceful shutdown announcement
svc.<component>.call   queue-grouped tool call request/reply
svc.session.<id>.steer   fire-and-forget mid-turn message injection ({content})
svc.session.<id>.advise  turn-bound advisory request/reply (the expert peer):
                         accepted only while the named turnId is live
svc.session.<id>.map     repomap → runner: the workspace map to append once
ev.workspace.opened    core → components: {workspace, conversationId} — a
                       conversation's workspace, for pre-warm and the repo-map append
ev.session.<id>.turn        {sessionId, turnId, phase: start|done, content?, error?}
                       #   per-conversation event namespace: a client watching
                       #   one conversation subscribes ev.session.<id>.>, an
                       #   observer subscribes ev.session.> for everything
                       #   (ev.session.*.token for every token stream)
ev.session.<id>.assistant   {sessionId, turnId?, content, provider?, model?, context?, usage?}
ev.session.<id>.status      {sessionId, turnId?, provider?, model?, context?, usedTokens?}
ev.session.<id>.token       {sessionId, turnId?, content, reasoning}  (live token deltas)
ev.session.<id>.toolcall    {sessionId, turnId?, callId?, phase: start|done, tool, args, result|error, durationMs?}
ev.session.<id>.advice      {sessionId, turnId?, source, content, reason} an advisory was
                             folded in (`reason` is the judge's one-line justification)
ev.session.<id>.notice      {sessionId, turnId?, kind?, content?, jobId?, child?,
                             status?} runtime machinery was folded in (subagent
                             settlement, background process exit, autonomous wake);
                             `content` is the rendered text UIs show
ev.session.<id>.done        {sessionId, turnId?, reply} | {sessionId, turnId?, error}
ev.session.<id>.context     {sessionId, turnId?, promptTokens, usedTokens, context, warning?|trimmed?}
ev.catalog.updated     direct (prompt-facing) tool projection after any
                       registration change; `catalog {op: snapshot}` still
                       returns everything incl. hidden/on-demand schemas
ev.models.updated      effective provider/model/source counts after refresh
ev.provider.switch     provider component → bus: {nickname, previous, source, at}
ev.provider.changed    redacted provider registry invalidation event
ev.llm.token           llm adapter → core: {sessionId, content, reasoning} deltas
ev.sys.drain           core → components: stop taking calls, finish, exit
ev.log.<component>     structured SDK logs: {component, level, msg, ctx?, at}
ev.lsp.warm            lsp → bus when a workspace warmup settles: {workspace, warmed, skipped}
ev.agent.started|done|notice  agent: a background job started, a job became
                       terminal, a settlement was folded into the turn
ev.fabric.started|phase|log|call.started|call.done|done
                       one fabric program's lifecycle, correlated by `runId`
llm.cancel.<sessionId> abort an in-flight streaming call (see Streaming below)
svc.approval.<name>.request  directed approval to the component driving the
                           turn (derived from the call envelope's `caller`);
                           driver acks {id, ack: true}, then answers {id, ok}
ev.approval.request    core → UI: {id, tool, args, caller?, fallback?} —
                       human gate, broadcast (see Approvals below)
ev.approval.reply      UI → core: {id, ack?} | {id, ok}
ev.approval.resolved   core → UIs: {id, ok} — gate verdict; dismiss stale modals
cancel.<component>     cancellation side-channel: a runner publishes it when a
                       turn cancel lands while a dispatch is in flight; bash
                       kills the command's process group (see WIRE.md)
```

**流式传输。** `llm` 组件在生成时流式发送 token：
`ev.llm.token` 增量（内容 + 推理）→ core 将其作为
`ev.session.<id>.token` 转发给当前回合 → UI 将它们追加到实时
助手气泡中。仅当调用携带非空 `sessionId` **且**保持 `emitTokens` 开启时，
才会发布增量帧——辅助调用方在内部流式传输以便取消，但将其部分输出
排除在对话之外（压缩传入 `emitTokens: false`；专家评判的调用甚至
不进行流式传输，因此无论如何都不会发出任何内容）——并且每个包含内容或推理的
流块发出一个帧。这些调用方发送的 `purpose` 参数仅用于遥测
（provider、model、effort、ttft 和 tok/s 会随其记录），
绝不改变 provider 行为。最终的
`ev.session.<id>.assistant` 事件始终携带
完整内容，因此丢失的最后一帧会自我修复。通过发布到
`llm.cancel.<sessionId>` 来中止进行中的调用——或者，当调用方
传入了 `cancelId` 时，发布到 `llm.cancel.<cancelId>`：该订阅仅为流式调用
（`stream: true`，core 始终设置）武装，并使用
`cancelId`，以会话 id 作为其默认值。辅助调用方依赖
这种分离——压缩取消
`llm.cancel.compaction.<sessionId>.<attemptId>`——因此用户的回合停止
既不能杀死摘要调用，也不会被摘要调用杀死。

历史记录被逐字重放给 provider，这就是为什么适配器
在输出时修复它：被中断的流（或有缺陷的写入器）留下的未终止的
助手 `tool_calls` 载荷，其字符串和容器会被闭合，
无法挽救的载荷变为 `{}`——否则严格的后端会拒绝整个
请求。修复只读取文本，绝不执行任何内容。

在总线上挂载 `nats sub '>'` 可以实时看到 harness 的思考过程。
或者更好：**console 组件**（`./var/bin/console`，不在
清单中——请在第二个终端中自行启动）订阅
所有内容并以可读方式渲染线上流量：带有 subject + tool +
args 的调用、结果、错误、事件、审批。有两个限制值得了解：裸的
`reg.publish`/`reg.depart` 载荷会打印为空主体的
`event <subject>` 行（使用 `observe_subjects` 或 `catalog` 查看哪个
组件启动了），并且每个 SDK 结果打印时工具名为空——
请将其与上方的调用行关联。这就是你跟踪实时安装
或卡住的工具调用的方式：

当总线死亡时，console 会在 nats 客户端的重连预算内保持静默
（数十秒到约 4 分钟），然后打印其 `console: bus connection
lost` 行并每 2 秒重试，每次重新读取 `var/nats-url`——一个
在新随机端口上重启的 harness 会被自动发现。

```bash
./var/bin/console    # in a separate terminal while the harness runs
```

它没有选项：它渲染总线上的每个信封，每条消息一行，
调用参数和错误截断为 300 个字符，结果和事件
载荷截断为 500，助手文本截断为 2000——仅在 tty 上着色。对于有界、
可过滤、持久的视图，请使用 `observe`/`logfile`。

**cli 组件**（`./var/bin/cli`）从脚本或管道驱动同一总线
——非交互式，对 CI 友好（成功时退出 0，失败时退出 1，
用法错误或 JSON 错误时退出 2）；
它是脚本化界面，tty 管理 shell 是交互式界面：

```bash
./var/bin/cli catalog                        # components + their tools
./var/bin/cli wait <component> [secs]        # wait for registration
./var/bin/cli call <tool> '<json args>'      # dispatch, print the result
./var/bin/cli install <repo>[@<ref>]         # plugin_install + verify
```

`catalog` 打印一行开头的 `# harness: <root> @ <gitHash>`，指明
是哪个克隆的 core 做出了应答，然后每个组件一行 `component: tool, tool`
（无序）；当 core 不应答或目录为空时，它退出 1。
`cli install` 克隆、通过 builder 构建、启动每个组件并
等待每个服务名称出现在 core 已接受的目录中；交互式
组件通过其构建进行验证。`wait <component> [secs]` 轮询 core 的
已接受目录（默认 60 秒；`0` 执行单次读取）。CLI 目录和工具
查找也使用 core 的
权威目录，绝不使用原始注册广播。插件仓库的 CI
通过这一个命令运行 harness 本身来证明一个包。`file://` 仓库 URL
从本地 git 仓库安装（封闭测试、镜像）。`call` 首先等待最多
60 秒让 core 接受该工具，然后等待 `--timeout=<secs>`（默认 30 秒）
以获取回复——这是 cli 自己的预算，绝不是工具的 `x-harness.timeoutMs`，因此
慢工具需要显式延长（`cli --timeout=600 call build …`）。
基于名称的验证
无法区分已存在的已接受组件与同名的
新启动进程。

它是一个普通的 bus 客户端：`cli call` 直接分发到
`svc.<component>.call`（只有目录读取经过 core），因此它的调用
绕过了审批门、工作区和会话注入、工具的
`x-harness.timeoutMs` 以及隐藏/按需过滤器——`cli call del …` 和
`cli call chat …` 可以工作。将其视为运维工具：给予它你
启动 harness 所用 shell 的同等信任。

## Approvals

schema 携带 `x-harness.approval: "always"` 的工具——目前包括
`bash`、`build`（`builder` 组件）、core 的 `spawn`、`kill` 和
`remove`、`edit`、`write`、`undo_last_edit`、`fabric`、`agent_run`、
`agent_spawn`、`agent_ask`、`expert_follow`、`lsp_registry`、`mcp_add`、
`mcp_edit`、`mcp_remove`、`mcp_refresh`、`plugin_install`、`plugin_update`、
`plugin_remove`、`process_start`、`process_kill`、`skill_install`、
`skill_remove`、`provider_add`、`provider_update`、`provider_export`、
`provider_import`、`provider_use_environment`、`observe_send`、
`observe_request`、`observe_dump`、`observe_monitor`——在执行前
需要人工审批；配置了
`approval: always` 的 MCP 桥接服务器的每个工具都以相同方式受门控，并且诸如
`provider_update`/`provider_use_environment` 之类的隐藏条目在被直接调用时仍然受门控，
因此该列表不是封闭的（包括 core 未注册的 `conversation_delete` 接口）：

- **终端 harness**（`make run`）：出现 `[approval]` 提示，包含工具
  名称和参数；回答 `y`/`n`（仅当 core 位于终端且未附加 UI 时
  才回退到 tty 提示）。
- **Web UI / 交互式组件**：请求被路由到驱动该会话的
  特定组件——core 从调用
  信封自我声明的 `caller` 中推导出它，并发布到该组件的
  私有主题 `svc.approval.<name>.request`。驱动方确认它
  （`{id, ack: true}`）以确认正在询问人类，显示一个包含
  工具名称和参数的模态框，并回答 `{id, ok}`。
- **驱动方消失 / 非交互式**：如果驱动方在 1.5 秒内未确认
  （`ackTimeoutSecs`），请求会在 `ev.approval.request` 上重新广播，并带有
  `fallback: true`，以便任何交互式客户端可以介入；如果没有交互式
  客户端注册，则跳过重新广播并立即拒绝该调用。直接
  （非会话）调用立即广播。
- **两者皆无**（未附加 UI 的服务模式）：调用被**拒绝**，
  并给出明确的错误——调用方看到 `approval denied for tool '<name>'`
  （core 自己的工具：`approval denied for <name>`）作为正常的工具错误，
  回合继续，不会静默重试任何内容——绝不静默批准。
- 当裁决到达时，core 发布 `ev.approval.resolved {id, ok}`，以便
  每个客户端关闭任何过期的模态框。
- 没有客户端应答的工具审批在 5 分钟后超时
  （`timeoutMs`，300 秒）并被拒绝（日志显示 `timed out after Ns —
  denying`）；`/limit` 继续询问有自己的较短窗口（120 秒）。
- `NIF_AUTO_APPROVE=1` 绕过该门（无头自动化）。
- Core 自己的破坏性工具命名为 `spawn`、`kill`、`remove` 和
  `conversation_delete`；它们在 `handleCoreTool` 内部按名称受门控，而不是
  通过 schema，因此 `x-harness.approval` 只出现在组件工具上。
- 该门位于 core 的分发器中，因此它只保护 core 中介的
  调用方：模型，以及任何通过 `svc.core.call` 到达的调用方。
  直接到达组件的调用方会在未被询问的情况下运行 `approval: "always"`
  工具——`plugins` 安装路径自己调用 `svc.builder.call`
  （其自身的 `plugin_install` 调用才是携带审批的调用），而
  `./var/bin/cli`、`dialog` 或发布到 `svc.<component>.call` 的测试
  永远不会进入该门。将此类调用方视为启动 harness 的
  shell 的信任级别。

程序形态的调用（`fabric`，或带 `code` 的 `agent_run`/`agent_spawn`）
按*内容*审批，而非按工具名称：core 将源代码加上选定的 `tools` 和
`maxCalls` 哈希为一个摘要，将完整源代码写入
`var/approval-sources/<digest>.nim`（权限 0600）并在
提示中显示该路径，以便审批者阅读全部内容而非截断的摘录
（`tests/t_approval_manifest.nim`）。

### Conversation controls: `/approvals`, `/limit` and `/compact`

这三个控制属于你（人类），绝不属于模型，并且适用于一个
会话。它们都通过 session 调用设置（Web UI 将它们暴露为
`/approvals`、`/limit` 和 `/compact`；任何 bus 客户端都可以直接调用 `session`）。
`approvals` 和 `limits` 设置随会话持久化，因此恢复的会话会保留它们；
`/compact` 是一个动作，而非设置。

- **`/approvals auto`**——此会话停止询问：每个
  受门控的工具都被授予，core 在其日志中大声说明
  （`core: approval auto-granted for <tool> (this conversation is in approval
  mode: auto)`），因为静默授予正是该门存在所要防止的。
  该设置持久化在会话头（`approvals`）中，因此
  会话运行器中恢复的会话会记录相同的行。`/approvals ask`（或带
  空参数的 `/approvals`）恢复正常的门。对于你已决定
  端到端信任的会话使用它；针对更窄的信任，仍可使用
  按工具的“不再询问”记录。客户端的自动批准操作会写入一条持久
  记录（存储类型 `approval`，id `<sessionId>:<key>`——由客户端写入，而非
  core）；对于程序形态的调用，键为 `<tool>:<digest>`，因此笼统的
  “始终批准 fabric”绝不会覆盖新写入的源代码。当此类记录
  匹配时，该门绝不会闪现对话框。
- **`/limit rounds=N tokens=N seconds=N`**——回合的软预算：LLM
  轮数、累计 token 数和墙钟秒数。秒数在
  每次工具分发前检查（一次 `bash` 调用可能比整个回合还长）；轮数和
  token 数在下一个 LLM 轮次前检查。当达到其中一个时，回合不会
  死亡：
core 通过同一审批通道询问你**“继续吗？”**（UI
显示一个 Continue/Stop 提示，指明该限制），*是*会将该限制
再延长一步。*否*、无应答或无可达客户端会以一条
独特的 `limit-<dimension>` 记录结束回合，该记录指明限制和
提高它的命令。`/limit clear` 移除全部三项。
- **`/compact`**——*立即*运行压缩器，而不是等待
自动压力阶梯：core 向配置的压缩组件请求
在允许的切点上的检查点，原子地安装它，并发出
通常的 `ev.session.<id>.context {reason: "reset:compact"}`。不运行 LLM 回合，也不
追加用户消息。该提交将测量的提示大小归零（此
投影尚未经过 provider），因此手动路径也会
发布一个状态帧——`usedTokens` 是本地估计值，`estimated:
true`，加上窗口——否则上下文仪表会一直显示
压缩前的数字，直到下一个回合测量它。下一个请求的
测量用量会替换该估计值。辅助摘要继承会话的
已解析 provider/model；它不会静默跟随之后的全局 provider
切换。回复报告 `compacted: true` 以及 `beforeTokens`、`afterTokens`
和 `generation`，或者报告 `compacted: false` 以及精确的拒绝/失败
原因（例如 `no permitted cut exists yet`、`input-budget-exceeded`、
`summary-output-truncated`、无效的候选详情，或压缩器不可用）。
拒绝绝不会静默回退到有损裁剪。

重要的区别：这些限制是*你的*，因此它们可以协商；
作业范围的预算（`maxRounds`/`maxCalls`/`maxTokens`，`agent`
组件将其冻结到子代理的会话中，以及 `NIF_MAX_TURN_ROUNDS`）
保持硬性——子代理绝不能通过游说获得更多预算。
`NIF_AUTO_CONTINUE=1` 对每个继续询问都回答是（无头
自动化，与 `NIF_AUTO_APPROVE=1` 精神相同）。

在回合运行期间到达的会话调用会立即被拒绝，
并给出 `busy`（“会话正处于回合中——请在回合结束后重试”）
而不是等待：回合绝不嵌套，而选择等待的客户端只会
耗尽自己的超时（这就是为什么在长回合期间 `/export` 看起来像坏了一样）。

## Context window

Core 会监视对话使用了模型上下文窗口的多少，并以*简单直接*的方式采取行动——不做摘要，也不做超出模型所报告范围之外的 token 计算：

- 有效窗口在每一轮之前由隐藏的 `llm_resolve {model?}` 解析，因此新选择的模型的限制会在推理之前到达上下文守卫。按提供方的 `context` 和 `NIF_OPENAI_CONTEXT` 会覆盖模型目录；如果 `models` 被移除，一个小型内置表和保守的 128K 会作为回退保留。结果包含不含密钥的提供方、模型、目录、上下文和输出来源信息，以及供交互式客户端使用的提供方 `protocol`、`authType` 和 `hasKey`；它仍然需要一个可解析的提供方，因此当既没有存储的凭据也没有环境凭据时，它会失败，而不是报告一个窗口。参见 [Model catalog](#model-catalog-models)。

- **输出**窗口与上下文窗口一起解析，并以 `output`/`outputSource` 返回：目录中的 `model.limit.output`，否则是一个刻意设定的 32768 默认值——如果没有显式上限，提供方会应用其自己的服务端上限，并在流中途截断长回答。每次调用的 `maxTokens` 只会降低已解析的值（专家裁判的微小裁决），而 Codex 通道完全忽略它。

- `session {sessionId, content?, provider?, model?, thinking?, title?, cwd?, profile?, discovery?, tools?, maxRounds?, maxCalls?, maxTokens?}` 接受会话作用域的 provider 和模型覆盖。`provider` 指定一个已存储的 provider 昵称（为空则清除，回到 harness 全局默认）；仅指定模型的调用会在同一次头写入中解析并固定其所属的 provider，因此 provider 和模型总是一起出现——模型不会在事后因为另一个 UI 切换了全局默认而被发送到不支持它的 provider。无法解析的显式 `provider` 是一个指名它的错误，而不是静默回退（docs/WIRE.md "Provider/model pins are one selection"）。仅指定模型的调用会持久化并解析该选择而不进行推理；存在但值为空会清除它。`profile` 指定一个已存储的工具配置，仅在对话的第一次调用时解析为直接工具集（`NIF_PROFILE` 提供默认值）；未知配置会使调用失败，而恢复会忽略该参数。`thinking` 是推理强度，取值为 `""`、`low`、`medium`、`high`、`max` 之一；`""` 是提供方默认值（UI 将其显示为 "auto"），并且是唯一能清除先前选择的值。它作为 `reasoning_effort` 转发给提供方——且仅在非空时转发，因此不支持该字段的提供方永远不会看到它；`llm` 适配器将该值映射到每种协议自己的形式（Codex `reasoning {effort, summary}`，Anthropic `thinking` 加上 `output_config.effort`）——并携带在对话头上。
  `discovery {…}` 是显式的客户端发现：它运行 `discover`，将模式记录到持久发现摘要中，并将它们作为用户消息追加——没有 LLM 轮次，也不会提升到直接工具集。
  Core 将该选择存储在对话头中，并在一个轮次内的所有工具轮次中固定已解析的模型。
- 每会话控制项在第一次调用时冻结并持久化在头中：`tools`（子级可以分派的工具允许列表；最多接受 32 个名称，且接受的参数不会在 `session` 工具模式中声明）、`maxRounds`（每轮 LLM 轮次数，1–`NIF_MAX_TURN_ROUNDS`，收窄硬上限）、`maxCalls`（每轮工具分派总数，1-500——每次分派尝试都计数，无论成功还是错误），以及 `maxTokens`（每轮提供方报告的累计 token 数，在每一新轮次之前检查）。预算耗尽会以预算耗尽错误结束该轮次——子代理驱动（`agent_run`/`agent_spawn`）将其作为失败呈现，而绝不是文本回复。
- `cwd` 固定对话的**工作区**：`NIF_ROOT` 内的一个现有目录（相对路径相对于根解析），创建后不可变，并持久化在头中，以便恢复的运行器以相同方式解析上下文和路径。会话运行器在分派时重写路径形状的工具参数：bash 以 `cwd` 设置为工作区运行，edit/grep/read 在那里解析相对路径，git 工具以工作区仓库为范围。当工作区与根不同时，系统提示组件会追加一条工作区通知。默认工作区是 `NIF_ROOT` 本身。
- 每次聊天调用后，core 记录提示 token，并使用 `usage.total_tokens`（或提示 + 完成回退）作为当前最佳占用。提供方、模型、上下文、占用和覆盖也会镜像到对话头中，因此计量器在重启后无需加载整个记录即可存活。
- Core 发出 `ev.session.<id>.status`，包含已解析的提供方/模型/上下文和当前 `usedTokens`；客户端直接渲染 `usedTokens / context`。当提供方报告缓存输入（`prompt_tokens_details.cached_tokens`）时，状态事件还会携带对话的累计缓存拆分作为 `cache {prompt, read, hitRate}`（提示和缓存 token 的总和，比率为百分比）；对话头保留相同的数字作为 `cachePrompt`、`cacheRead` 和 `cacheHitRate`。由于提示前缀被冻结，大多数提示 token 在第一次请求后应被缓存，因此低比率是一个值得注意的信号（Web UI 在每条消息上显示 `⚡ <cached>/<prompt> cached`，并在 `/info` 中显示累计拆分；TUI 在其头中显示 `cache NN%` 标记，并在 `/status` 中显示相同的拆分）。
- 持久化消息携带永远不会到达 LLM 的审计元数据：每条消息上的 `createdAt`，所有地方的 `turnId`，以及 assistant、tool 和 error 记录上的 `startedAt` / `durationMs`（当 LLM 调用本身失败时会持久化一条 `error` 记录，重放会跳过 error 角色）。
- 准入在**每一次**提供方请求之前运行，包括每个工具循环轮次。在存在报告的用量之前，它用保守的 chars/4 估算为整个请求（消息加上冻结的工具模式）定价。保留的余量是目录中模型声明的输出上限（`limit.output`，例如 DeepSeek 的 384000）——提供方在准入时会将请求的 `max_tokens` 计入其窗口，因此固定的 16K 保留量曾让一个 736,803 token 的提示溢出 1,048,576 的提供方限制，而仅提示本身就适合。`NIF_CTX_RESERVE` 覆盖推导出的保留量。Core 在到达有效线的 75% 处警告一次（`ev.session.<id>.context {reason: "warn:threshold"}`）；到达该线时——绝不晚于窗口的 90%——core 执行一个有界阶梯：确定性工具结果修剪 → 配置的压缩器 → 最旧完整轮次裁剪 → 显式 `context-recovery-required`。在传输线上，`llm` 组件还会将请求的输出限制为序列化提示（消息加上工具模式）所留下的余量，因此任一层中的估算漂移都无法将一个适合的提示推过提供方的限制。它绝不会在知情的情况下发送超窗口请求。
- 触发器以**提供方的尺度而非估算的尺度**衡量：每个成功响应都会重新测量一个校准偏移（报告的 `prompt_tokens` 减去同一请求的本地估算），准入、警告和修剪将候选定价为估算 + 偏移。原始的 chars/4 代理可能比更密集的分词器滞后数万个 token——在一个 524K 窗口的对话中观察到，"90%" 线在约 99% 时静默触发，而 core 称为 86% 的请求在 400 处被拒绝。该偏移是模型作用域的（在模型更改时清除，从下一个响应重新学习），在恢复时从存储的用量播种，限制在 `[0, window]`，并且从不持久化——它会在第一个响应时重新测量。
- 随附的 `compaction_propose` 是可替换的：设置 `NIF_COMPACTION_TOOL=<tool>` 以选择另一个 contract-v1 实现，或将其设置为空以在保留确定性守卫的同时禁用摘要。该值是一个**工具名称**，而不是组件名称：运行器在目录中解析它，并分派到注册它的任何组件，因此替换项可以位于任何组件中。空值或未注册的值会跳过自动阶梯中的该级，并使 `/compact` 回答 `compacted: false`，并带有 `reason: "no compaction component available (NIF_COMPACTION_TOOL=<value>)"`。`NIF_COMPACTION_TIMEOUT_MS`、`NIF_COMPACTION_MAX_LLM_CALLS` 和 `NIF_COMPACTION_MAX_SUMMARY_TOKENS` 限制每次尝试。该接缝是一个版本化契约：候选工具以 `{version: 1, sessionId, attemptId, trigger, snapshot: {ref, generation, canonicalHigh, digest}, budget: {…}}` 被调用，并回答 `{version: 1, status: "declined", attemptId, reason}`（带有三个稳定原因之一：`no-useful-cut`、`input-budget-exceeded`、`indivisible`），或回答 `{version: 1, status: "candidate", attemptId, baseGeneration, snapshotDigest, cutBefore, covered, checkpoint, provenance: {model, llmCalls}}`，其中 `checkpoint` 恰好携带 `objective`、`constraints`、`decisions`、`completedWork`、`currentBlocker`、`nextSteps` 和可选的 `files`。任何其他内容都会作为无效被拒绝并落到修剪——`provenance.llmCalls` 高于授予的 `NIF_COMPACTION_MAX_LLM_CALLS` 也是如此，并且一个发现请求的 `attemptId`、`digest` 或 `generation` 与其读取的快照不一致的组件会以 `stale-snapshot` 拒绝该调用。运行器写入一个临时的分页 `compaction_input` 快照，验证候选的 generation/digest/cut/schema/size，针对快照重新哈希被覆盖的节点，并自行测量严格缩减（渲染后的检查点的估算 token 必须低于被覆盖跨度的估算 token），然后以乐观的 `expectRev` 提交一个 `context_projection` 文档。快照页为 512000 字节，因此一条巨大的消息不会使总线消息过大；检查点是有界的（objective 和列表项 ≤ 4000 字符，每个列表 ≤ 32 项，≤ 64 个文件，编码后 ≤ 65536 字节），并由运行器拥有的 `checkpoint-v1` 模板渲染，因此由一个压缩器存储的检查点在另一个压缩器下会以相同方式重新加载。该组件从不写入对话或投影记录。
- 成功的投影发出 `reason: "reset:compact"`；无模型修剪发出 `reset:prune`；有损回退发出 `reset:trim`。`reset:tools` 仍然保留给实际的粘性工具模式提升。这些是唯一有意的提示前缀重建，并使缓存未命中可归因。压缩级还会报告非重置原因，这些原因从不重建前缀：`compact:failed`（分派错误或超时）、`compact:declined`（带有 `detail` = 稳定拒绝原因）、`compact:invalid`（模式、边界、声称的调用预算或严格缩减失败）和 `compact:stale`（被覆盖跨度在尝试下发生变化）；成功的 `reset:compact` 事件携带 `generation`、`covered`、`beforeTokens` 和 `afterTokens`。
- 规范 `message` 文档是不可变的且仅追加。修剪和压缩只更改提供方投影；重启的运行器会验证并重新加载持久检查点加上保留的规范尾部，而 `context_recall` 解析 canonical/spill/current-checkpoint 引用；`checkpoint` 引用返回投影的结构化检查点及其 `generation`（不是分页文本），忽略 `mode`/`offset`/`limit`，并且当它命名一个已被取代的 generation 时会被拒绝——该状态已被吸收到当前检查点中，而当前检查点才是要读取的那个——并且其 `mode: search` 会 grep 对话的整个规范 `message` 历史——每条消息，包括修剪或压缩丢弃的跨度，其中没有通知会命名单个引用（搜索只读取 `message` 文档；spill 正文和检查点从不被搜索，它们的引用会解析它们）。缺失或损坏的投影引用会显式失败，而不是静默重放一个过大的跨度。
- `context_recall {ref?, mode?, query?, session?, role?, offset?, limit?}` 是这些通知背后的解析器：`ref` 是一个 `{source, id}` 对象或它们的数组（`source` 是 `canonical`、`spill` 或 `checkpoint`），`mode: full`（默认）在每文档 256 KB 上限下用 `offset`/`limit` 分页一个文档，`mode: match` 对一个文档的行进行 grep——仅受 `limit` 行数限制，没有字节上限，因此匹配一个巨大单行结果的查询会完整返回该行——而 `mode: search` 在对话中 grep 提及 `query` 的消息（`role` 过滤它们；`session` 选择要搜索的对话——会话租借的调用只能命名它自己的对话，因此运行器调用无法读取另一个对话的历史，而直接总线调用者保持不受限制的访问），并返回有界的一行命中，其 `id` 随后可以作为 `canonical` 引用读回。默认值：2000 行，50 个匹配，20 个命中；该工具是按需的且为读效果，并且它被 `runner` 豁免，因此子代理始终可以到达它。
- 提供方报告的 `context-overflow` 恰好获得一次有回执支持的恢复尝试。相同的 prune → compactor → trim 顺序会被重新测量；第二次溢出是终局的，绝不是无界重试循环。当容量未知且拒绝不携带可解析的窗口时，该尝试会盲目缩减（无损修剪，然后裁剪到最新请求），并且只有在候选确实缩小时才会发出重试——不可缩减的候选会终局结束，而不是重新发送被拒绝的内容。适配器将提供方溢出措辞（包括某些主机返回的裸 `"Context limit exceeded"` 正文）规范化为稳定的 `context-overflow` 前缀；运行器的分类器将原始措辞作为回退携带。
- 有损裁剪是**持久的**：它在对话头中记录其裁剪到的规范 seqNo（`trimThrough`），普通恢复会遵守它，因此重启会重建裁剪后的投影，而不是在计量器恢复裁剪后用量时重新膨胀完整的裁剪前上下文。被丢弃的轮次保留在规范历史中供 `context_recall` 使用，并且省略通知是持久的：恢复的运行器从 `trimThrough` 重建裁剪后的投影并重新插入通知（范围诚实——它命名第一个保留 seq 以下的规范跨度，而不是实时运行的确切 `coveredFrom`/`coveredTo` 对），因此重启会保留一个指向投影所丢弃内容的可见指针。`mode: search` 是回到裁剪历史的方式——通知不携带 recall 引用，因为整轮丢弃覆盖许多消息。

- 修剪步骤是字节精确且无模型的：超过 8192 字节的工具结果会被重写为其前 4096 字节、一个 `[tool result middle pruned: N bytes omitted — recall the original with context_recall {"ref": {"source": "spill", "id": "<convId>:<seq>"}}]` 标记，以及其最后 1024 字节——绝不两次，并且当结果不会缩小时绝不进行。标记的 `source` 恰好在结果由 spill 支持且提升的文档被重新验证时为 `spill`，否则为 `canonical`，并且其 `id` 是通知引用的规范 seqNo，因此可以直接传回 `context_recall`。这三个数字是常量，不是配置。`context_recall` 本身是按需的，不是隐藏的：`discover` 列出它，`invoke` 接受它，裸名称仍然会分派，但用 `tools` 允许列表冻结的对话会像拒绝该列表之外的任何工具一样拒绝它——这是修剪或 spill 通知的指令无法被遵循的唯一情况。

## Self-extension and component lifecycle

代理在运行时、对话中途添加能力：

1. 编写一个组件源（Nim：`import niffler/sdk`，类型化工具模式；Go：`import sdk "niffler.dev/sdk"`；TypeScript：`sdk/ts` 包——参见系统提示）。TypeScript 构建需要 PATH 上有 `node` 和 `npm`（缺少一个会以 `node and npm are required on PATH for ts components` 拒绝），围绕对 `<root>/sdk/ts` 的 `file:` 依赖生成 `package.json`/`tsconfig.json`，并且其 `var/bin/<name>` 是一个 node 包装器，通过绝对路径 `require` `var/build/<name>/dist/main.js`——将该 "binary" 复制到别处，或删除 `var/build/`，会破坏组件，且没有错误消息解释原因
2. `build {lang, name, source, files?, defines?}`（`builder` 组件）将其编译到 `var/bin/`（`files` 添加更多 Go 源，`defines` 传递编译器定义）。检查其结果，而不是假设二进制存在：成功时为 `{ok, lang, name, binary, log}`，失败时为 `{ok: false, lang, error}`，其中 `error` 是编译器自己的输出尾部（2000 字节）。不报告退出代码，因此在内部预算（Nim、Go 和 `npm install` 300 秒，`tsc` 120 秒）处被杀死的构建读起来完全像一个编译错误，带有它已产生的任何输出
3. `spawn {name, binary, replicas?}`（core）启动它；它自行注册；新对话直接暴露其工具（当不是按需时），现有对话通过 `discover` + `invoke` 到达它们（参见 [Progressive tool discovery](#progressive-tool-discovery)）。`spawn` 仅在该注册落入目录后才报告 ok：被拒绝的注册（目录的原因）或超过 `NIF_SPAWN_WAIT_MS` 的静默组件会使调用失败，并带有原因和子级日志的有界尾部，并回滚该尝试——副本停止，没有任何持久化——因此该名称可立即用于修正后的重新 spawn。一个已注册但其存储记录无法写入（存储宕机）的组件也会失败，并带有 `registered: true`：它现在运行，并在下次启动后消失，这不是单纯的成功
4. `kill {name}` 临时停止每个副本（下次启动时恢复）；`remove {name}` 停止该组并删除其持久记录。运行器以相同方式被杀死（`kill {name: "session-<id>"}`），但会在下一次会话调用时回来，而不是在下次启动时。重建不会到达正在运行的进程——旧二进制继续执行——因此获取新代码是 `kill` 然后 `spawn`；在此之前，`spawn` 回答 `component already supervised: <name>`

一个稳定下来的 fabric 程序走相同的路线：`fabricprog` 是草稿本，`builder.build` + `core.spawn` 是毕业（参见 [FABRIC_GUIDE.md](FABRIC_GUIDE.md)）。

`replicas` 是可选的（1–16，默认 1）并且会被持久化。仅将其用于无状态或外部协调的组件：所有副本共享同一个 `svc.<name>.call` NATS 队列组，因此并发请求每个进程分发一个。绝不要复制单写入者的 `store`，或像 `edit` 这样其变更/撤销状态是进程本地的组件。默认 Nim SDK 泵保持串行。其初始 NATS 连接在总线绑定时最多重试 60 秒，然后失败进入监督器的正常退避；关闭会中断该等待。当副本不合适时，组件可以显式拥有原生并发：对于长寿命/共享状态的 Nim 工作器，优先使用 `std/threads` + `std/locks`，对于隔离作业使用 `taskpools`，并且绝不使用 `asyncdispatch`。在 Go 中，普通的 `Tool` 处理器保持独占；经过审计的处理器可以使用 `ToolConcurrent`（默认限制为 16 个在途，可通过 `ConcurrentLimit` 配置）。并发处理器必须同步共享状态，并且不得同步调用其自己组件上的串行化工具。分派由每个组件的投递循环调度：NATS 回调只负责入队，因此长处理器（流式 chat）永远不会阻塞无关调用的投递；串行化处理器只在没有并发处理器运行时才开始，而不是驻留一个写锁——否则排在其后的读取者也会被阻塞。这个服务端选择独立于面向运行器的 `x-harness.parallel` 提示：声明 `parallel: true` 的工具可以在同一条 assistant 消息中与其他标记为并行的工具并发分派（`grep` 和 `read` 会；`files` 虽然是只读的，但不会，因此被 `invoke` 的 `files` 会串行化）。

**重启策略**：每个受监督的子级都携带一个——`never` 或 `on-failure`（默认；重启的子级在 1 秒后尝试，每次连续崩溃翻倍，上限为 8 秒）。清单按组件设置它（`manifest.yaml`），`spawn` 始终使用 `on-failure`，而会话运行器始终是 `never`。

**形状的持久性**：spawn 的组件记录在存储中（kind `component`）并在正常启动时恢复。一个存储记录，其名称也在 `manifest.yaml` 中声明，在恢复时会被跳过——随附定义胜出，静默地——因此替换随附组件意味着编辑清单；同名下的 `kill` + `spawn` 仅对当前启动有效。`--minimal` 保持这些记录不变，但不恢复它们。`core` 本身、总线、目录和监督器不可移除——这种不对称就是架构（ARCHITECTURE.md）。

## Component ecosystem (`plugins`)

`plugins` 组件是生态系统的入口——社区组件包就是普通的 GitHub 仓库，根目录下带一个 `niffler.json` 清单（一个仓库 = 一个包 = N 个组件）。清单 v1 保留紧凑的 `{name, components: [{name, lang, main, sources?, env?, defines?, interactive?}]}` 形式。清单 v2 使用 `{manifestVersion: 2, components: [{name, lang, project, build: {steps: [[argv...]], artifact: {path, runner}}}]}`：包自己持有 `package.json`/锁文件、`go.mod`/`go.sum` 或 Nimble 文件；Niffler 只提供 SDK 占位符和构建器接缝。`lang` 是给 Nim、Go 或 TypeScript SDK 的元数据；配方可以组合外部包工具（例如 Go/Wails 客户端使用 npm 和 wails）。构建器拒绝不支持的命令和 shell 包装步骤，项目/产物路径必须留在克隆目录内，声明零组件的清单会被拒绝。打上 GitHub 主题 `niffler-component` 标签的仓库无需任何注册表即可被发现：

| Tool | What it does |
|---|---|
| `plugin_search {query?}` | GitHub 主题搜索；返回仓库、描述、星标，以及最终胜出的 `query` 和每次尝试的诊断信息——GitHub 对词做 AND 运算，所以零命中的查询会用更少的词重试 |
| `plugin_installed` | 本 harness 上已安装的包 |
| `plugin_install {repo, version?}` | 克隆到 `var/plugins/<pkg>@<ref>/`，通过构建器构建每个组件（v1 用 `build`，v2 用 `build_package`），然后 `spawn` 每个服务组件（需审批）。安装一个已有记录的包是错误，而不是重新安装——请用 `plugin_update`，或先 `plugin_remove`；克隆是浅克隆（`--depth 1`），v1 Go 包会带一个未跟踪的 `go.work` 供手动构建 |
| `plugin_update {package}` | 更新到最新发布标签：移除，按新 ref 重新安装；没有发布（跟踪分支）的包就地拉取（对现有克隆执行 `git pull --ff-only`），当拉取移动了 HEAD 或已安装产物过期/缺失时重新构建 |
| `plugin_remove {package}` | 对每个受监督组件执行 `core.remove`，删除克隆，删除记录 |

- 安装/更新/移除都带有 `x-harness.approval: "always"`——它们运行第三方代码，每一次单独的 spawn/remove 都会再次由 core 审批。除非你信任发布者，否则绝不要用 `NIF_AUTO_APPROVE=1` 运行它们。
- 默认 ref 是最新发布标签，否则是默认分支。`version` 显式固定一个标签或分支。
- 组件始终通过 `builder` 从源码构建——与 agent 编写的组件走同一条路径。运行 Niffler 本身已提供工具链（Nim/Go 和 NATS SDK），因此不需要 NATS C 库；每个平台用自己的工具链编译。Go 入口可以声明 `"sources": ["component/helper.go", ...]`；这些必须是非符号链接的 `.go` 文件，**与 `main` 位于同一目录**（plugins 清单读取器拒绝子目录中的路径，且只有 basename 会传给构建器），最多 64 个文件、总计 2 MB，构建器将它们与 `main` 作为一个包一起编译。Nim 或 TS 条目上的 `sources` 键在读取清单时会被拒绝。
- 清单 v2 包在自己的生态文件中声明依赖：TypeScript 用 `package.json`/`package-lock.json`，Go 用 `go.mod`/`go.sum`，Nim 用 `.nimble`/锁文件。配方从声明的项目目录运行，因此 `npm ci`/`npm run build`、`go mod download`/`go build`、`nimble install`/`nim c`，或先 `npm ci` 再 `wails build`，都使用包正常的依赖语义。Wails 桌面客户端是一个带 `executable` 产物的 Go 组件，可以标记为 `interactive`。`${NIF_SDK_ROOT}`、`${NIF_SDK_GO}`、`${NIF_SDK_TS}`、`${NIF_PROJECT}` 和 `${NIF_OUTPUT}` 是仅有的构建器替换项。步骤是 argv 数组，不是 shell 字符串，构建器拒绝路径穿越、符号链接输入、超大项目、不安全的 runner 和未声明的产物。
- 清单条目中带 `"interactive": true` 的组件会构建到 `var/bin`，但不会传给 `core.spawn`。它是终端客户端（例如 TUI），由用户手动启动，因此不受监督，也不会在启动时重启。在移除或更新其包之前，请手动停止任何正在运行的客户端。
- 清单条目可以携带 `defines`（一组 `-d:` 风格的前置参数）和 `env`（一组 `NAME=value` 字符串）。两者都原样传递——`defines` 传给构建器（仅 Nim：Go 或 TS 构建会接受并静默忽略它们），`env` 传给 spawn——因此包可以自带配置而无需编辑清单。
- 安装记录存放在存储中（kind `plugin`，id = 包名）；它们会像所有组件记录一样被 `--recover` 清除——重新安装时，全新启动会从记录的 repo/ref 重新克隆。
- GitHub API 以未认证方式使用（60 req/h/IP）。
- 发布：添加 `niffler-component` 主题并打发布标签（`v1.0.0`）。[`gokr/niffler-weather`](https://github.com/gokr/niffler-weather) 示例中的发布工作流会自食其果：它启动一个 harness 并通过 `plugin_install` 安装该包，因此每个标签都证明该包能干净安装。
- 包可以通过注册一个带 `x-models-source: {version: 1, priority: ...}` 的隐藏工具来扩展或修正模型元数据。`models` 组件会自动发现它，并在该组件存在期间应用其 JSON Merge Patch。参见 [Source plugins](#source-plugins)。
- 树内有三种参考形态：`gokr/niffler-weather` 包（Nim）、MCP 桥（一个被 spawn 的 Go 组件），以及 `components/dialog/dialog.sh`——一个完全没有 SDK 的纯 bash 组件。

## Skills

`skills` 组件为 agent 提供可复用的工作流指导——开放的 [Agent Skills](https://agentskills.io) 格式（带 YAML frontmatter 的 SKILL.md 文件），与 Claude Code、opencode 和 Cursor 使用的约定相同。Niffler 读取的键是 `name`、`description`、`version`、`license`、`tags` 和 `allowed-tools`（后两者是列表）；`allowed-tools` 是模型读取的元数据，绝不是强制限制。读取/加载通过总线是只读的，唯一的写入是两个受管目录中需审批的 `skill_install`/`skill_remove` 对；没有任何工具会把技能加入提示——加载是通过工具结果进行的渐进式披露。

全部八个工具都是**按需**的（`x-harness.onDemand`）：没有一个位于会话冻结的直接工具集中，因此第一次取用某个工具需要一次 `discover` + `invoke` 跳转（参见 [Progressive tool discovery](#progressive-tool-discovery)）。加载技能会将其文本追加到历史——这里没有任何东西会重写冻结的提示前缀，因此 `skill_load` 的代价是一次缓存读取，而不是缓存未命中。

发现范围覆盖仓库中随附的技能，以及标准 agent 目录（每个技能名以首个匹配为准——项目优先于随附，随附优先于 home，home 优先于 config）：

| Source | Directories |
|---|---|
| project | `$NIF_ROOT/.agents/skills`、`$NIF_ROOT/.claude/skills`、`$NIF_ROOT/.opencode/skills` |
| bundled | `<repo>/skills`——编译此二进制文件时所用的检出目录（一个构建期路径）；`$NIF_ROOT/skills` 是迁移部署的兜底，`NIF_SKILLS_BUNDLED_DIR` 覆盖两者——永不可移除 |
| home | `~/.agents/skills`、`~/.claude/skills`、`~/.opencode/skills`、`~/.niffler/skills` |
| config | `~/.config/opencode/skills`（`npx skills add -g -a opencode` 安装的位置） |

在同一来源内，目录按列出的顺序尝试，因此 `~/.agents/skills/nats` 优先于 `~/.claude/skills/nats` 被提供。发现是**每次调用都全新遍历**——没有缓存注册表，没有存储记录，没有刷新操作——因此 `skill_install` 或另一个 agent 的 `npx skills add` 会立即可见。遍历不会进入**符号链接目录**：仅通过符号链接到达被扫描目录的技能不会被发现，`skill_audit` 也不会列出它；**符号链接的 SKILL.md** 文件同样不会被产出，因此 SKILL.md 是指向别处真实文件的链接的技能也不可见（诸如 `~/.claude/skills → ~/.agents/skills` 这样的符号链接农场因此不可见——当链接目标本来就被扫描时无害，不被扫描时则悄无声息）。

随附技能（`todo-markdown`——把 todo 状态保存在仓库 TODO.md 中，而不是工具状态中；`niffler-tools`——哪个工具适合哪项工作；`niffler-fabric`——构造 fabric 程序；`niffler-harness`——操作正在运行的 harness 本身）让 Niffler 开箱即用；把一个同名技能放入项目或 home 目录即可遮蔽其中一个。

当**没有**任何随附树可达时——例如部署只带 `var/bin` 而没有仓库检出，`<repo>/skills` 和 `$NIF_ROOT/skills` 都不存在——发现会回退到**编译进二进制文件**的随附 SKILL.md 文件。这些条目报告来源 `bundled`、目录 `(baked)`；它们不携带资源（`skill_resources` 为空——随附技能都不带任何资源），且永不可移除。磁盘始终按名称胜出，因此检出目录不受该回退影响。

| Tool | What it does |
|---|---|
| `skill_list {query?, source?}` | 可用技能（name、description、version、license、tags、allowedTools、source、dir——`license`/`allowedTools` 是惰性元数据）；按子串或来源过滤；编译内置的回退条目报告目录 `(baked)` |
| `skill_search {query, owner?}` | 在线搜索 skills.sh 注册表（`npx skills find` 的后端）：name、repo source、install count、slug 和 url（每次调用最多 20 条命中；少于 2 个字符的查询在任何网络调用之前就被拒绝，调用失败会返回 HTTP 错误文本）；`source`+`name` 对可直接喂给 `skill_install` |
| `skill_load {name}` | 技能的 markdown 正文（frontmatter 以字段形式返回）+ 其资源列表进入会话（加载机制）；超过 200 000 字节的正文会被截断并带 `truncated: true` |
| `skill_resources {name}` | 技能的 `references/`、`scripts/`、`assets/` 文件，一层深度——`references/sub/x.md` 中的文件，或符号链接文件，既不会被列出也不可读 |
| `skill_resource {name, path}` | 按需读取一个资源 |
| `skill_audit` | 只读、未合并的磁盘上每个 SKILL.md 的清单——外加仅由编译内置回退提供的名称（目录 `(baked)`）：标记每个名称的活跃胜出者和每个被遮蔽/无效的副本（无效 = SKILL.md 不可读、frontmatter 无法解析，或即使回退到目录名后仍无名称——省略 `name:` 的 SKILL.md 会以其目录名被接受；发现结果在 `skill_list` 中合并，因此遮蔽只在这里可见） |
| `skill_install {repo, skill?, global?}` | 克隆一个 git 仓库，把选定的 SKILL.md 树复制到 `~/.niffler/skills`（默认）或 `$NIF_ROOT/.opencode/skills` |
| `skill_remove {name}` | 仅从 Niffler 管理的目录中删除一个技能 |

- `skill_search` 是对 `https://skills.sh/api/search` 的只读 HTTP 调用（未认证）；它不受审批门控。每次调用最多返回 20 条命中，`owner` 缩小同一查询的范围——它不是单独的命名空间。安装流程是：搜索 → `skill_install {repo, skill}` → 审批对话框 → 完成。

- 用 `npx skills add <owner>/<repo>`（skills.sh 生态 CLI）安装的技能会落在上述标准目录中，无需重新安装即可被发现；`skill_install` 的存在是为了让 Niffler 在没有 Node 的情况下通过普通 git 也能工作。它只复制 SKILL.md 树——不运行任何代码——并接受 `owner/name`、github.com URL 和 `file://` 本地仓库（封闭测试）。
- 包含多个技能的仓库（例如 `vercel-labs/agent-skills`）需要 `skill` 参数；缺少时 `skill_install` 会列出候选。该参数匹配技能的名称或其目录 basename。
- `skill_install` 需要 `PATH` 上有 `git`：它从 `https://github.com/` 以 `--depth 1` 克隆到 `$NIF_ROOT/var/skills-tmp/<name>`（之后再次删除）——旧版本只能通过把 `repo` 指向镜像来获取——并复制整个技能目录，包括资源。它拒绝目标已存在的名称（先 `skill_remove`）；结果报告 `source: home|project`。
- `skill_remove` 拒绝 `~/.niffler/skills` 和 `$NIF_ROOT/.opencode/skills` 之外的任何内容——其他 agent 安装到共享目录中的技能要用它们自己的工具移除。
- 安装和移除带有 `x-harness.approval: "always"`（它们会写入 `var/` 之外）。

## Provider registry (`provider`)

配置的 LLM 后端是存储记录，而不是配置文件。`provider` 组件将它们保存在 kind `provider` 下（id = 昵称，外加 `active` 标记文档），并将它们暴露给 agent 和 `llm`：

这些工具没有一个位于会话冻结的直接集合中：`provider_add`、`provider_remove`、`provider_list`、`provider_switch`、`provider_models`、`provider_export` 和 `provider_import` 是 `x-harness.onDemand`（可通过 `discover` + `invoke` 到达），而 `provider_update`、`provider_status`、`provider_active`、`provider_get`、`provider_use_environment` 和三个 OAuth 工具是 `x-harness.hidden`（仅客户端——`invoke` 拒绝它们）。

| Tool | What it does |
|---|---|
| `provider_add {nickname, apiKey, protocol?, baseUrl?, model?, catalog?, context?, plugin?, stripPrefix?, active?}` | 添加或覆盖一个 API-key provider（按昵称 upsert；`protocol`：默认 `openai-chat` 或 `anthropic`）；第一个 provider——API-key 或 OAuth——会自动变为活跃，除非 `active: false`；`stripPrefix` 会发送不带 `vendor/` 前缀的命名空间模型 id，用于按规范 id 路由的网关（例如 `alibaba/glm-5.2` 发送为 `glm-5.2`）；响应已脱敏 |
| `provider_update {nickname, apiKey?, protocol?, baseUrl?, model?, catalog?, context?, plugin?, stripPrefix?}` | 用于部分更新的隐藏客户端 API；省略的 API key 会被保留 |
| `provider_oauth_start {protocol, method?, nickname?, model?, active?}` | 隐藏，开始订阅登录：`protocol` 为 `openai-codex`（ChatGPT Plus/Pro）或 `anthropic`（Claude Pro/Max）；`method` 为 `browser`（本地回调）或 `device`（无头，仅 OpenAI）。返回 `{flowId, url, userCode?, callbackAvailable, expiresAt}` |
| `provider_oauth_complete {flowId, code?}` | 隐藏，轮询/完成登录；在回调（或粘贴的 `code`）到达之前返回 `{pending, retryAfterMs?}`，然后存储 provider 并以脱敏形式报告 |
| `provider_oauth_cancel {flowId}` | 隐藏，取消待处理的登录并关闭其回调监听器 |
| `provider_list` | 所有已存储的 provider（脱敏——无 key/token），哪个是活跃的；每个条目携带 `authType`（`api_key`/`oauth`）、`protocol` 和 `expiresAt` |
| `provider_status` | 隐藏，脱敏的有效 provider，包括环境兜底和 `hasKey` |
| `provider_active` | 隐藏的内部读取，读取有效 provider 的完整配置，含凭据 |
| `provider_get {nickname}` | 隐藏的内部完整配置读取，用于在一轮对话中固定一个显式存储的 provider |
| `provider_models {nickname?\|baseUrl?, apiKey?, refresh?}` | provider 的 `/models` 端点当前提供的模型 id——按昵称指定已存储的 provider，或显式端点+key（连接表单，在凭据保存之前）；两种形态互斥（若都给出则 `nickname` 胜出），且必须提供其一。按端点磁盘缓存 5 分钟（探测失败时提供过期缓存）；错误返回给调用方，以便客户端回退到 catalog |
| `provider_switch {nickname}` | 让另一个已存储的 provider 变为活跃；下一次聊天调用（以及 `llm_resolve`）立即使用它，无需重启 |
| `provider_use_environment` | 隐藏客户端 API，清除存储的标记并回到 `NIF_OPENAI_*` |
| `provider_remove {nickname}` | 删除一个 provider；如果它曾是活跃的，按字母序第一个剩余 provider 接管，否则恢复 `NIF_OPENAI_*` 兜底 |
| `provider_export` / `provider_import` | JSON 备份/迁移往返，含凭据；导入会合并、校验记录，并可恢复活跃标记 |

暴露标志，这样每行的说明文字无需解析：`provider_oauth_*`、`provider_status`、`provider_active`、`provider_get` 和 `provider_use_environment` 行是**隐藏**客户端 API（由 UI 或操作员调用；模型永远看不到它们），而 `provider_add`、`provider_update`、`provider_list`、`provider_switch`、`provider_export` 和 `provider_import` 是**按需**的——模型通过 `discover` + `invoke` 到达它们。四个移动凭据的工具带有 `x-harness.approval: "always"`（见下文），`provider_models` 在 20 秒超时下运行。

省略的字段采用协议默认值：`openai-codex` 推断 ChatGPT 后端 URL，`anthropic` 推断 Anthropic 的（在 `openai-chat` 下，`deepseek` 或 `openai` 昵称暗示其自己的 base URL），模型默认为 `deepseek-chat`（`openai-chat`）、`gpt-5.4`（`openai-codex`）或 `claude-sonnet-4-6`（`anthropic`），两个 OAuth 协议推断其 models.dev catalog id（`openai`/`anthropic`）。

### Wire protocols

每个 provider 携带一个 `protocol`，`llm` 据此路由：

- `openai-chat`——OpenAI 兼容的 Chat Completions 端点（默认；DeepSeek、OpenRouter、本地 vLLM……）。
- `openai-codex`——ChatGPT 的 Codex Responses 端点（`https://chatgpt.com/backend-api/codex/responses`），带 ChatGPT OAuth 头（`chatgpt-account-id`、`OpenAI-Beta: responses=experimental`）；消息被转换为 Responses API 输入格式，SSE 事件流（文本/推理增量、函数调用）被映射回共享结果形态。
- `anthropic`——Anthropic Messages 端点；OAuth 登录会发送 Claude Code 身份头和 betas，系统提示以 Claude Code 前言开头，工具调用/结果被转换为 `tool_use`/`tool_result` 块（连续的工具结果合并为一条 user 消息）；其用量为 core 的计数器归一化——`prompt_tokens` 是输入 + 缓存读取 + 缓存写入，而只有缓存**读取**计为缓存 token（缓存写入按写入费率计费）。在所有三种协议中，只有当 provider 报告非零 token 时，结果才会附带 `usage` 对象。

API-key provider 只能使用 `openai-chat` 或 `anthropic`：`openai-codex` 需要 ChatGPT 订阅登录（`provider_oauth_start`），`provider_add` 拒绝该组合。

### Output caps and `finish_reason`

输出上限按协议拼写，拼错的上限会静默失败。Niffler 的默认拼写是 `max_completion_tokens`；DeepSeek 只认 `max_tokens`，因此以默认方式发送的上限会被忽略，服务器自己的默认值（按模型为 8K/64K/128K）生效——对 DeepSeek 端点请发送 `max_tokens`。Anthropic 通道始终以 `max_tokens` 接收解析后的窗口；Codex 通道则完全不被告知上限。流的结束方式在 `finish_reason` 中报告：`length` 表示输出上限截断了回复（`llm` 会记录截断警告），`tool_calls` 表示模型停下来调用工具，Anthropic 的 `max_tokens` 停止映射为 `length`（其 `tool_use` 停止映射为 `tool_calls`）；Codex 的 `max_output_tokens` 结束及其 `response.incomplete` 事件也映射为 `length`，而无法识别的原因会原样传递以供日志记录。两个 OpenAI 兼容的错误结束，`aborted` 和 `insufficient_system_resource`，以 HTTP 200 到达，并作为可重试的流错误呈现，而不是作为回复。一个从不报告 `finish_reason` 的适配器会丢失这两个信号——没有截断警告，而在上限处被截断的空补全会作为普通空回复重试，而不是以 `the provider cut the reply at the output cap before any content` 结束该轮；`llm-openai` 示例不返回任何内容。

### Subscription OAuth (ChatGPT Plus/Pro, Claude Pro/Max)

`provider` 组件实现了与 Pi 和 opencode 相同的 PKCE 登录流程（固定的 localhost 回调端口、手动重定向/代码回退，以及面向无头机器的 OpenAI 设备码流程）。已启动的流程在 15 分钟后过期；`provider_oauth_start` 返回其 `expiresAt`（epoch 毫秒），因此被放弃的登录永远无法在之后完成：

1. `provider_oauth_start` 返回授权 URL；交互式客户端在系统浏览器中打开它。OpenAI 还提供 `device` 登录（在 `auth.openai.com/codex/device` 输入的短代码）。
2. `provider_oauth_complete` 轮询直到授权完成，然后交换代码并存储 provider —— `authType: "oauth"`，带有访问令牌、刷新令牌、过期时间以及（对于 ChatGPT）从 JWT 中提取的账户 id。
3. 每次凭据读取（`provider_active`、`provider_get`、状态解析）都会在令牌距过期 5 分钟内时透明地刷新令牌，并持久化轮换后的凭据。`llm` 组件永远看不到刷新令牌。

环境开关：`NIF_OAUTH_CALLBACK_HOST`（默认 `127.0.0.1`）移动本地回调监听器（端口保持固定为 1455/53692，与参考客户端一致）。导出内容包含实时刷新令牌 —— 将 `provider_export` 输出视为机密。

回退后端以昵称 `default`（`source: environment`）呈现自身，`NIF_OPENAI_BASE_URL` 默认为 `https://api.openai.com/v1`，`NIF_OPENAI_MODEL` 默认为 `deepseek-chat`；`provider_use_environment` 清除活动标记，它不会删除已存储的 provider。

交互式客户端以斜杠命令的形式暴露相同的操作：`/provider <nickname>`（别名 `/providers`）切换全局后端，`/provider environment`（别名 `/provider env`）回到这里，`/provider strip [off]` 切换活动 provider 上的厂商前缀剥离；UI 的 provider 管理器将相同的工具（`provider_add`/`provider_update`/`provider_remove` 以及 OAuth 启动/完成/取消流程）包装在审批提示之后。

- `provider_add`/`provider_update`/`provider_import`/`provider_export` 带有 `x-harness.approval: "always"` —— 它们会移动凭据或修改连接设置。交互式客户端在用户明确操作后直接调用隐藏的 update/status 工具，并且绝不能渲染/记录凭据负载。
- `llm` 在每次聊天调用时从活动存储的 provider 解析其默认后端，因此 `provider_switch` 立即生效。当 `provider` 组件不存在或没有活动项时，`llm` 像以前一样回退到 `NIF_OPENAI_*` 和 `NIF_LLM_PROVIDERS` 表。向 `chat` 或 `llm_resolve` 显式传入 `provider` 参数会先解析存储的昵称，然后解析 `NIF_LLM_PROVIDERS`，因此会话可以在其回合内固定一个非活动的存储 provider，而无需切换全局默认值。
- 存储的 provider 的显式 `context`（令牌数）优先于模型目录；其 `catalog` id 为上下文查找命名 models.dev provider，而 `plugin` 是信息性元数据，命名拥有此 provider 额外工具的组件 —— `provider` 既不启动也不验证它，因此命名的组件必须单独生成，并且只能对 `ev.provider.switch` 做出反应。每次切换时，组件发布 `ev.provider.switch {nickname, previous, source, at}`，以便此类插件可以启用或隐藏其工具。每次注册表变更还会发布无密钥的 `ev.provider.changed {op, nickname, active, source, at}` —— `op` 是 `add`、`update`、`switch`、`remove`、`import`、`login` 或 `refresh` 之一 —— 供交互式客户端使其 provider/模型视图失效。
- `active` 标记是一个普通的存储文档（`{nickname, updatedAt}`）—— 以 `expectRev` 0 写入 —— 悬空或空的标记会在下次读取时自动删除，因此 `provider_remove`/`provider_use_environment` 无需手动修复；`store` 工具仍然保留在那里，供你手动操作。
- 切换改变的是 harness 全局默认，而不是被固定的对话：provider 和模型成对地固定在对话头中（见上文对 `session` 调用的说明），因此被固定的对话仍在其自己的 provider 下解析，切换永远不会把它的模型发送到不支持该模型的 provider。没有固定的对话则跟随全局默认。

## Hooks

`hooks` 组件（默认关闭 —— 这是一个自动启动标志，不是构建标志：`make build` 像每个组件一样编译二进制文件，因此启用它是 `NIF_HOOKS_*` 加上 `spawn {name: "hooks", binary: "<root>/var/bin/hooks"}`）在选定的总线事件触发时运行操作员 shell 命令 —— 这是 CodeWhale 钩子的仅观察子集（docs/research/CODEWHALE.md）。钩子是一个普通进程：事件**负载**以 pretty JSON 形式通过管道传送到命令的 stdin —— 信封被剥离，不是信封的消息作为原始字节传递，因此钩子在顶层读取负载的字段（`jq -r .msg`，绝不是 `jq -r .payload.msg`）—— 写入临时文件（`getTempDir()/niffler-hook-<pid>-<n>.json`，默认权限：像对待捕获目录一样对待它）并 `cat` 到钩子中，绝不插值到命令行中 —— 失败和超时（默认 10 秒，最大 60 秒）会被记录且绝不致命，负载上限为 256 KB，并附加截断标记。这里刻意没有引导/否决：审批决策位于核心的调度门中。它完全不注册任何工具 —— 接口是环境和总线 —— 并且在没有匹配的 `NIF_HOOKS_<SUBJECT>` 设置时，它会记录 `watching nothing, staying up` 并继续运行。

配置基于环境变量，在启动时读取（`.env` 更改适用于重新生成的组件；在核心 shell 中导出的变量需要重启 harness）：

```bash
NIF_HOOKS_EVENTS="ev.session.*.turn,ev.log.error"   # subjects to watch
NIF_HOOKS_EV_SESSION_TURN='notify-send Niffler "turn finished"'
NIF_HOOKS_EV_LOG_ERROR='jq -r .payload.msg | mail -s Niffler you@example.com'
NIF_HOOKS_TIMEOUT_MS=10000
```

通配符遵循 NATS：`*` 精确匹配一个主题令牌，尾随的 `>` 匹配其余部分，因此 `ev.session.*.turn` 会为每个对话的已完成回合触发，`ev.log.>` 会为每个日志事件触发（会话 id 随主题和负载传递）。重叠的规格是安全的：满足其中两个规格的消息仍然只运行第一个匹配的命令**一次** —— 组件按已传递消息去重（一个以信封 id 和命令为键的 256 项环形缓冲区），因此列表不必互不相交。

主题 → 环境变量名：点和通配符变为 `_`，大写，其中 `*.` 和 `>.` 折叠，以便规范名称得以保留（`ev.session.*.turn` → `NIF_HOOKS_EV_SESSION_TURN`）；结束规格的通配符贡献自己的下划线，因此 `ev.log.>` 和 `ev.log.*` 都是 `NIF_HOOKS_EV_LOG__`。完整示例 —— 桌面通知、声音警报、电子邮件、webhook、错误跟踪 —— 位于 `components/hooks/README.md`。值得关注的事件是 `ev.session.<id>.turn`（回合边界）、`ev.session.<id>.done`（携带 `reply`）、`ev.session.<id>.status`（每轮 LLM）、`ev.session.<id>.context`（warn/trim/reset）和 `ev.log.<component>`；它们的负载字段列在 [The bus in one screen](#the-bus-in-one-screen) 下。匹配对逗号分隔列表采用首个匹配优先，并且在启动时其 `NIF_HOOKS_<SUBJECT>` 未设置的主题会被忽略 —— 组件仅为其将运行的钩子记录 `watching …`。

**失败**钩子的合并输出会回显到组件的 stderr，并落入 `var/logs/hooks.log`（supervisor 将子进程输出重定向到那里）；退出码为 0 的钩子其输出会被丢弃。两条路径都不会写入 logfile 的 JSONL，后者仅持久化总线流量。

`make test-hooks`（`tests/t_hooks.nim`）是冒烟测试：它使用 `NIF_HOOKS_EV_SESSION_TURN` 启动组件，发布一个 `ev.session.<id>.turn`，并检查解码后的负载是否到达钩子的 stdin。

## Fetch

`fetch` 组件是 Web 访问工具（旧 niffler `fetch` 工具的移植）。一个按需工具 —— 模型通过 `discover` + `invoke` 访问它；它永远不是对话冻结直接集的一部分：

| Tool | What it does |
|---|---|
| `fetch {url, method?, headers?, body?, timeout?, maxSize?, convertToText?}` | 对 http(s) URL 执行 GET/POST/PUT/DELETE/HEAD/OPTIONS/PATCH；HTML → 通过 Trafilatura 或纯 Nim 回退转换为干净文本；跟随重定向；强制执行上限（`timeout` 默认 30 秒，最大 120 秒） |

- `convertToText`（默认 true）从 HTML 中提取可读文本 —— JSON 负载始终原样返回。转换仅对 `text/html` 响应运行（XHTML 在 `Accept` 中声明但原样返回）；从未转换的调用报告 `extractionMethod: "none"`。
- 提取是一个阶梯：`trafilatura`（将已下载的 HTML 放在 `$NIF_FETCH_DIR` 下的临时目录中，限制为 30 秒）→ 内置的 `htmlparser` 遍历 → 原始正文（`extractionMethod: "raw-fallback"`）。缺少可执行文件、非零退出、超时或空输出都会静默回退。将 `NIF_TRAFILATURA` 设置为可执行文件路径/名称以覆盖检测，或设置为 `off`/`0`/`false`/`none` 以禁用它。
- 响应上限为 `maxSize`（默认 10 MiB，最小 1024 字节，最大 50 MiB）；处理后超过 200 KB 的内容会写入 `$NIF_FETCH_DIR`（默认 `$NIF_ROOT/var/fetch`）下唯一的 `fetch_<rand>.txt`，工具结果变为 `Content saved to file (over 200000 bytes after processing): <path>`，因此 agent 使用自己的文件工具读取大页面，而不是撑爆对话。没有任何东西会清理这些文件 —— 目录会一直增长直到操作员清除它，并且它还托管 trafilatura 的临时工作目录。
- 错误（非 2xx、超时、超大响应、无效 URL/方法）以 `ok: false` 返回，并带有状态和正文片段：HTTP 错误携带 `extra.status` 和剥离后正文最多前 500 字节，超过 `maxSize` 的响应就是这样的错误，绝不是溢出。成功结果携带 `finalUrl`（重定向后）、`status`、`contentType`、`contentLength`、`convertedToText`、`extractionMethod`、`savedToFile` 和 `filePath`。
- 请求在发送前经过验证，每个重定向跳转都会重新验证：仅限 http(s)，URL 最多 2048 个字符，无 URL 凭据，并且检查每个解析后的地址 —— 环回、私有、链路本地、CGNAT、多播、`localhost`/`.local`/`.internal`，以及空或失败的 DNS 应答都会被拒绝（故障关闭：`"hostname resolves to a private address: <host>"`、`"cannot validate hostname <host>: <msg>"`）。`NIF_FETCH_ALLOW_PRIVATE`（`1`，或 `true`/`yes`）为受信任的本地服务绕过该检查。
- 重定向：最多 5 跳，每跳重新验证；301/302/303 变为 GET，丢弃正文和 Content-Length/Content-Type/Transfer-Encoding，307/308 保留方法和正文；缺少 `Location` 或非 http(s) 目标是错误。调用方 `headers` 覆盖默认值（`niffler-fetch/0.1` UA、类似 HTML 的 `Accept`、`Accept-Language`）。
- 没有审批门（像 `plugin_search` 一样），但该工具不声明 `x-harness.effect`，因此 fabric 批处理主机将 `fetch` 调度为写入并独占运行它。

## Language servers (`lsp`)

状态：**已实现**（Nim 组件；确定性夹具测试；niffler-tui 客户端添加了 `/lsp` 注册表选择器）。

一个通用接缝，覆盖任何 stdio 语言服务器。该组件不了解任何语言：哪个服务器处理哪个文件扩展名是**数据** —— 一个内置合理默认值的注册表。添加一种语言是配置条目，绝不是代码（AGENTS.md 不变式：语言无关核心）。`repomap` 组件是当前的例外：地图语言需要其语法被 vendored 到 `components/repomap/csrc/` 下，在 `ts.nim` 中有一个 `{.compile.}` 条目，一个 `queries/<lang>-tags.scm` 及其扩展名在 `tags.nim` 中 —— 该层级列表是接缝当前的限制，不是策略。

### The tools

| Tool | What it does |
|---|---|
| `lsp {operation, path, query?, line?, character?, workspaceRoot?}` | 针对文件语言服务器的一次查询：`diagnostics`（无需运行测试的编译器/lint 错误）、`documentSymbol`（文件大纲：每个符号及其种类、名称和从 1 开始的位置 —— 无需 line/character）、`workspaceSymbol`（仓库范围符号搜索 —— 模糊 `query` 字符串；服务器在预热后构建其索引，因此首次调用可能需要重试）、`goToDefinition`、`findReferences`、`goToImplementation`、`hover` —— 或 `warmup`：以目录作为 `path`（或 `workspaceRoot`），普查其语言并预启动其服务器 |
| `lsp_servers {}` | 列出已配置的服务器（只读，免审批）及其来源：`builtin` 默认或 `user` 注册表条目 |
| `lsp_registry {action: add\|remove, name, command, extensions?, initializationOptions?, requires?, cheap?}` | 变更用户注册表（审批门控写入）。`add` 接受 `{name (lowercase letters/digits/hyphens), command, extensions: {".ext": "languageId"}}`，覆盖同名的内置项，并以 `E_LSP_CONFLICT` 拒绝已映射到另一个服务器的扩展名（先移除该映射）；`remove` 仅删除用户条目 |

模型发送从 1 开始的 line/character（UTF-16，匹配 LSP 的代码单元约定）；`findReferences` 始终包含声明；结果有上限（100 个位置 / 约 16 000 个字符），并带有截断元数据；结构化的 `[E_LSP_*]` 错误（`E_LSP_UNAVAILABLE`、`E_LSP_UNSUPPORTED`、`E_LSP_TIMEOUT`、`E_LSP_SCOPE`、`E_LSP_PROTOCOL`、`E_LSP_REGISTRY`、`E_LSP_CONFLICT`、`E_NOT_FOUND`、`E_NOT_TEXT`、`E_BAD_SHAPE`）让调用方根据代码而非文字进行路由 —— 超时和协议错误会附加服务器的最后一行 stderr，它命名了实际故障（缺少二进制文件、崩溃、索引）。

**作用域是边界，不是相等。** 对话工作区内的文件在工作区根下索引（其预热的服务器被重用）；*外部*的文件 —— 同级检出、git worktree、agent 正在工作的任何其他目录 —— 在其自己的标记派生根下索引，回复携带命名它的 `workspaceRoot`，因为答案中的相对路径否则会有歧义。`E_LSP_SCOPE` 仅保留给两种会将无界树交给服务器的情况：路径中的 `..` 组件，以及标记遍历到达文件系统根或 `$HOME` 的文件（消息要求显式 `workspaceRoot`）。直接拒绝工作区外的文件曾被尝试过，并且实际上是有害的：编辑工具的诊断推送将拒绝吞没为“未配置服务器”，因此另一个检出中工作的 agent 既得不到诊断，也得不到它没有诊断的信号。

**对于已知语言，编辑工具的自动推送从不静默。** 每次成功编辑后，它异步排队诊断 —— 检查在 lsp 组件的空闲接缝中运行，裁决在对话的 `.diag` 通道上传递 —— 编辑结果命名该通道，因此“已检查且干净”永远不会看起来像“什么都没发生”。当检查无法排队时（对话工作区外的文件，或无法到达 lsp 组件），编辑结果会说明这一点及原因。静默仅保留给其扩展名没有任何注册表条目声明的文件：`.md` 文件不关任何语言服务器的事。

所有三个工具都是**按需**的（`discover`/`invoke` —— 参见 [Progressive tool discovery](#progressive-tool-discovery)），保持冻结工具集小巧；工具描述是模型的何时使用指南。`lsp` 工具是只读且免审批的；`lsp_registry` 写入注册表文件并受审批门控。

### Model usage

典型回合：

- 在编辑不熟悉的代码之前：对符号执行 `goToDefinition`/`hover`，而不是从 grep 匹配中猜测。
- 在编辑编译型语言之后：对触及的文件执行 `diagnostics` —— 一次调用即可获得编译器的裁决，而无需跑一整轮测试。
- 当文本匹配存在歧义时：`findReferences` 以语义方式解析符号。

查询会临时打开文档（用当前字节 `didOpen` → 请求 → `didClose`），因此每次查询看到的都是文件此刻在磁盘上的样子 —— 包括 agent 自己刚刚写入的编辑 —— 并且打开的字节也会作为 `didSave` 回显，因为基于 nimsuggest 的 Nim 服务器仅在保存时发布诊断信息（对于 pyright、clangd 和 bash-language-server 这类 open-push 服务器则是空操作）。每个 (server, workspace) 保持一个服务器进程并在查询之间复用；超时或协议错误会拆除该实例，使下一次查询从新开始，并且最多保留八个活动实例（LRU 淘汰）。每次查询运行在 60 秒预算内，`initialize` 握手获得 30 秒，均在工具的 90 秒包络内；诊断在首次推送后等待 1.5 秒再定论。相对 `path` 会针对会话工作区解析；如果没有显式的 `workspaceRoot`，服务器根目录则根据该文件对应语言的最近模块标记（`go.mod`/`go.work`、`Cargo.toml`、`tsconfig.json`/`package.json`、`pyproject.toml`、`*.nimble`/`config.nims`、`compile_commands.json`/`CMakeLists.txt`）推导，然后是 `.git`，最后是工作区 —— 向上查找永远不会越过工作区，并且标记是按扩展名构建的，因此仅作为注册表条目添加的语言仍保留 `.git`/工作区回退。只有 `..` 组件或会到达文件系统根目录或 `$HOME` 的标记查找会被拒绝（`E_LSP_SCOPE`，要求显式提供 `workspaceRoot`）。

当会话工作区被宣告时（`ev.workspace.opened`），Core 会自动触发一次 **warmup**：组件运行有界的扩展名普查（在 5 000 个文件或 2 秒预算时停止；隐藏文件和诸如 `node_modules`、`vendor`、`dist`、`build` 和 `target` 之类的垃圾目录会被跳过），并为最普遍的语言预启动服务器，这样第一次真正的查询就不必支付服务器启动开销。随后它发布 `ev.lsp.warm {workspace, warmed, skipped}`，以便 UI 可以显示哪些服务器已启动、哪些被跳过。`warmup` 操作会显式重新运行同一路径。

未配置的语言会降级，而不会中断：没有服务器（或缺少二进制文件）的扩展名会返回 `E_LSP_UNAVAILABLE`，并在消息中给出修复方法 —— “add one with the lsp_registry tool (or edit <registry path>)”。模型会自行回退到 grep/read。

### Registry: adding a language

三种途径，都写入同一个文件：

1. **TUI 选择器** —— 在 niffler-tui 中执行 `/lsp`：浏览已配置的服务器，按 `a` 添加（名称、命令、扩展名 —— 例如 `elixir-ls`、`elixir-ls`、`.ex, .exs`），按 ctrl+s 保存（人工审批提示，因为它会写入配置）；按 `e` 编辑（内置项会作为覆盖打开），按 `d` 删除用户条目。
2. **让 agent 来做** —— “register elixir-ls for Elixir files” → 模型自己调用 `lsp_registry add`（同样的审批门）。
3. **直接编辑文件** —— `$XDG_CONFIG_HOME/niffler-lsp/servers.json`：

```json
{
  "elixir-ls": {
    "command": ["elixir-ls"],
    "extensions": {".ex": "elixir", ".exs": "elixir"}
  }
}
```

每个条目：`command`（argv 数组，或按空白拆分的普通字符串）加上一个 `extensions` 映射（前导点扩展名 → LSP 语言 id）。可选的 `initializationOptions` 会透传给服务器的 `initialize`。另外两个可选键承载了过去写在代码里的内容：`requires`（必须能解析到的运行时二进制文件，例如 jdtls 的 `["java"]` —— 运行时缺失的服务器会报告自身，而不是启动后死亡）和 `cheap`（不索引任何内容、因此不占用重型 warmup 名额的服务器；bash-language-server 是内置示例）。
内置默认项 —— gopls、nimtortoise、typescript-language-server、pyright、rust-analyzer、clangd、bash-language-server、jdtls、intelephense、solargraph、csharp-ls —— 只要二进制文件在 `PATH` 上或在回退目录（`~/go/bin`、`~/.nimble/bin`、`~/.local/bin`、`~/.dotnet/tools`、`~/bin`）中即可工作；`make install-lsp` 会幂等地安装它们（Go、Nim 和 TS 是必需的 —— Niffler 由它们构建 —— 其余是 y/n 提示，`make install-lsp ALL=1`（`--all`）用于无人值守安装，非 TTY 运行会跳过可选语言；不会用 `sudo` 安装任何东西 —— 只在 `$HOME` 下 —— 并且缺失的运行时（JDK、.NET SDK、rustup）会报告确切的命令，而不是自动安装；同一脚本会安装下面的用户本地 JDK。每种语言的失败都是非致命的：lsp 工具只会以 `E_LSP_UNAVAILABLE` 跳过它；每种语言的失败都是非致命的：lsp 工具只会以 `E_LSP_UNAVAILABLE` 跳过它；`NIF_LSP_BIN` 覆盖安装目录，默认为 `~/.local/bin`，它也是一个默认回退 bin 目录）。Java 是唯一连 *运行时* 也会安装的语言：当 `PATH` 上没有 JDK 17+ 时，会在 `~/.local/share/niffler-lsp/jdk` 下安装用户本地 JDK 21（免 sudo，与服务器下载一样）—— 过去没有 JRE 的 jdtls 包装器会报告 “ok”，然后在查询中途死亡。通过添加同名条目来覆盖某一项。注册表在每次调用时都会重新读取，因此编辑会立即生效；格式错误的文件或条目会被跳过，并在 stderr 上给出警告（可在 `var/logs/lsp.log` 中看到），而不是让查询失败。

将 `NIF_LSP_REGISTRY` 设置为绝对路径以迁移用户注册表（测试、多 harness 环境）。

**Warmup budgets.** Core 在会话引导时发布 `ev.workspace.opened`；组件普查工作区（有界遍历）并预启动服务器，这样第一次真正的查询就不必支付冷启动开销。重型服务器 —— 那些索引整个工作区的服务器（gopls、rust-analyzer、jdtls、clangd、pyright、intelephense、solargraph）—— 被限制为 `NIF_LSP_WARM_MAX`（默认 2）个选择；*cheap* 服务器不索引任何内容，拥有自己的预算（`NIF_LSP_WARM_CHEAP`，默认 1，且仅从 2 个以上匹配文件开始），并且永远不会挤掉重型选择 —— 在一个满是 `.sh` 文件的仓库中，bash-language-server 否则会从任务实际所用语言那里夺走两个名额之一。`NIF_LSP_WARM_TOTAL`（默认 4）为每个工作区预启动的进程数设上限。`requires` 运行时缺失的选择会报告在 `skipped` 中（“jdtls (needs 'java')”），而不是被启动。

## Repository inspection (`git`)

状态：**已实现**（Nim 组件；`tests/t_git.nim`）。

git 工作流的只读部分，作为一等工具；写入部分（add/commit/push/checkout/restore）留在 `bash` 中，受审批门控制。每个子命令都以固定 argv 运行（`--no-optional-locks -c color.ui=false -c core.quotepath=false --no-pager`），从不通过 shell，并以 `-C <repo>` 限定作用域 —— 标志、引用和路径逐字节传递。

| 工具 | 作用 |
|---|---|
| `git_status {repo?, path?}` | 当前分支加上每个已更改文件的一行 porcelain 输出；未跟踪文件出现在这里，从不出现在 `git_diff` 中 |
| `git_diff {repo?, path?, unified?=3, stat?=false}` | 自 HEAD 以来更改的一切，已暂存 **和** 未暂存（`unified` 限制在 0..50；`stat: true` 是每文件一行的摘要） |
| `git_log {repo?, path?, max_count?=20, author?}` | 最近历史，每个提交一行（`max_count` 限制在 1..200；`author` 是子串） |
| `git_show {repo?, rev, path?}` | 完整展示一个提交：元数据、消息、完整 diff（`rev` 必需） |
| `git_blame {repo?, path, start_line?=1, max_lines?=200}` | 逐行归属；未提交的行显示 `Not Committed Yet` |
| `review_receipt {op?="write", findings?, model?}` | 本地审查回执的写入/检查对（见下文） |

这六个都是 **按需**（`discover`/`invoke`），五个读取工具带有 `parallel: true` 和 45 秒包络。当 core 注入调用时（会话回合），空或相对的 `repo` 会针对会话工作区解析；直接的总线调用则针对组件的 cwd，即 harness 根目录解析。`path` 从不被重写 —— 它作为 `-- <path>` 传递，并针对 `repo` 解析。

**失败与拒绝语义。** 参数拒绝从不启动 git：它们以退出码 2 返回，并带有 `(exit 2 — refused)` 前缀（不存在或含 `..` 的 `repo`；绝对或含 `..` 的 `path`；看起来像选项、含空白或过大的 `rev`；以 `-` 开头或过大的 `author`）。真实运行返回 git 的退出码和 git 自己的输出；`124` 会加上 `[timed out]` 前缀，而带有 “not a git repository” 的 `128` 会加上 `[no git repository at the target directory]` 前缀。空结果会得到友好的标记（`[no changes since HEAD]`、`[no commits matched]`）；其他一切都是原始 git stderr，因此 **detached HEAD** 只是 git 的 `## HEAD (no branch)`，损坏的索引是 git 的致命文本并带退出码 128 —— 两者都不做特殊处理。输出被双重限制：保留头+尾 40 000 字节（带有 `truncated N of M bytes` 标记），以及每个工具的行数上限 —— `git_status` 200 行，`git_diff` 10 000（使用 `stat` 时 500），`git_show` 10 000，`git_log` 和 `git_blame` 为其计数加一 —— 每个都带有 “narrow the scope” 提示。

**Review receipts.** `review_receipt` 是这里唯一的写入侧工具，也是唯一没有审批门的 git 工具：它只会写入 `var/review-receipts/` 下的文件。`op: "write"` 将工作树 diff 的 SHA-256 指纹（加上可选的 `findings` 和 `model`）记录为 `rr-<unix>-<fp8>.json`（`schema_id: "niffler.review-receipt/v1"`、`id`、`created_at`、`diff_fingerprint`、`note`）；`op: "check"` 将当前 diff 与最新回执比较 —— 匹配时退出 0 并给出回执 id，diff 变动时退出 1 并给出 `receipt_fingerprint` 和 `current_fingerprint`，没有回执、都无法解析或 diff 为空时退出 1 并给出 `detail`。它从不调用模型。

**The git binary.** `git` 必须能在 `PATH` 上解析，并且命中组件自己的 `var/bin/git` 的 `PATH` 结果会被跳过（那会递归）；无法解析的 git 返回退出码 127 并附带安装提示。

## Background processes (`processes`)

状态：**已实现**（Nim 组件；`tests/t_processes.nim`）。

bash 按设计是同步的 —— 服务器、监视器和测试循环需要不同的契约：启动一次，轮询增量输出，显式终止。

| 工具 | 作用 |
|---|---|
| `process_start {command, label?, workdir?}` | 以分离方式生成命令（自己的进程组，stdin 来自 /dev/null，stdout/stderr 追加到 `var/processes/` 下的 spool 文件）并立即返回其 id。受审批门控制。通过 `bash` 工具的 `run_in_background` 进行的后台启动只在 `bash` 调用本身上审批一次 —— 内部的 `process_start` 直接走 NATS，从不经过 core 的审批门，而通过 core 发出的直接 `process_start`（模型，或任何经 `svc.core.call` 到达的工具）则受门控 —— 自己寻址 `svc.processes.call` 的总线客户端（`cli`、脚本）完全不受门控 |
| `process_poll {id, waitMs?, filter?, tail?}` | 排空自上次轮询以来追加的输出 —— 增量，从不重新注入旧字节；`waitMs` 阻塞直到有新输出或退出（上限 25 秒）；`filter` 是对新行的正则（排空游标仍会越过所有行前进）；任何非空 `tail` 会重新读取原始输出的最后约 64 KB。读取效应 |
| `process_kill {id}` | 终止整个进程组 —— SIGTERM，300 毫秒宽限，然后 SIGKILL。受审批门控制 |
| `process_list {}` | 显示注册表 —— 运行中和最近完成的条目及其退出码。读取效应 |

细节：

- 子进程以追加模式写入 spool 文件（绝不是可能死锁的管道）；组件从每流游标读取，因此操作系统会吸收输出突发。超过上限（32 MiB，`NIF_PROCESSES_SPOOL_CAP`）的 spool 会在下一次轮询时截断到其尾部 —— 保留最后 2 MiB，或当上限更小时保留上限的一半，并且截断的轮询会追加 `[spool truncated to its tail — the cap was reached]`；一次轮询每流最多返回 `NIF_PROCESSES_POLL_CHUNK` 个新字节（默认 64 KiB）。
- 每个工具带有自己的调度预算 `x-harness.timeoutMs` —— `process_start` 20 秒，`process_poll` 30 秒，`process_kill` 15 秒，`process_list` 10 秒 —— 与 `process_poll` 内部的 `waitMs` 上限分开。
- 上限：32 个并发进程。已完成的条目从不被淘汰：该组件生命周期内的每个进程都留在注册表中 —— 只有 *运行中* 的才会写入 `registry.json` —— 因此 `process_list` 会持续将已完成的子进程报告为 `exited(code N)` 或 `killed(signal N)`，直到组件退出。
- **已完成的进程会告知其会话。** 当你通过 `bash` 工具的 `run_in_background` 标志启动一个进程时，bash 会将所属会话交给注册表；当该子进程退出时，`processes` 会向其发布退出通知（与 subagent 结算通知使用同一通道），因此接下来的回合会以 `[background process p3 (dev-server) exited(code 0)] ran 412s, 8123 bytes of output — read it with \`process_poll\` …` 开头。它是一个指针：输出留在 spool 中，命令文本从不传递。

  这就是后台作业不再被忽视的原因：组件在周期性 tick（SDK 的 `onIdle`）上回收其子进程，而不仅仅是在有人轮询时 —— 这也意味着 `process_list` 会及时显示 `exited(code N)`，而不是在被询问前一直显示 `running`。只有 `bash run_in_background` 会移交所属会话（它是唯一传递 `session` 的调用者），因此以任何其他方式到达的 `process_start` —— 模型自己的 `discover` + `invoke`、`cli`、脚本 —— 启动时没有所有者会话；会话运行器已退役的进程也不会向任何人宣告。轮询这些进程。
- 工具错误带有稳定的代码：`E_BAD_SHAPE`（空 `command`、缺失 `workdir`、无效的 `filter` 正则）、`E_NOT_FOUND`（未知 id —— `process_list` 会显示注册表）和 `E_LIMIT`（32 个活动进程，或无法 fork 的子进程）。
- `process_list` 条目带有 `started_at`（epoch 秒），因此客户端可以显示某物已运行多久 —— `bg 1 (7m)` 徽章是 `niffler-tui` 插件的状态行，不是 core 的。
- `workdir` 默认为会话工作区：core 会为空或 `.` 值替换它，并针对工作区（`x-harness.workspace`）解析相对路径，不存在的路径会以 `E_BAD_SHAPE` 失败。裸总线调用（`cli call process_start`）会跳过该替换，因此子进程继承组件自己的 cwd（`$NIF_ROOT`）。
- 崩溃安全：子进程是进程组领导者，因此被 SIGKILL 的组件会让它们继续运行 —— `registry.json`（pid + /proc starttime，挫败 pid 复用）驱动一次启动清扫，在服务之前杀死上一世遗留的孤儿进程。当 `processes` 组件停止时它们会死亡；如果它反而被杀死，下一次启动会清扫剩余部分。

这四个工具都是按需（`discover`/`invoke`）。bash 工具的 `run_in_background` 标志是此组件之上的薄生产者：调用会立即返回 id —— 没有超时适用于 *作业*，但启动它的 `bash` 调用仍然有界（其调度预算，以及其后的 15 秒 `process_start` 请求）—— 并且转录行指向 `process_poll`/`process_kill`。如果组件未运行，bash 会回答 `[E_BACKGROUND]` 并建议同步运行该命令。

## External MCP servers (`mcp`)

状态：**已实现**（管理器 + 桥接 + 发现集成；UI 界面是同一批工具之上的瘦客户端）。

Niffler 充当 MCP **客户端/宿主**：每个配置的外部 MCP 服务器（Model Context Protocol）都变成一个受监督的桥接进程，而服务器的工具则变成普通的目录工具——可发现、可调用，并且像任何组件工具一样受审批门控。桥接基于官方 Go SDK（`github.com/modelcontextprotocol/go-sdk`）构建。

### Shape

```
store kind "mcp" (one record per server)
        │ owned by the mcp manager (components/mcp)
        ▼
spawn {name: "mcp-<server>", binary: var/bin/mcp-bridge, args: ["--server", <server>]}
        │ one supervised process per server (survives reboots via the
        │ component record; supervisor restarts it on failure)
        ▼
bridge announces mcp_<server>_<tool> schemas  ──►  catalog ──► discover/invoke
        │
        └── lazy MCP session ──► stdio subprocess / streamable-http / sse
```

桥接只会以这种方式启动（或由探针以 `--probe` 启动）；其路径为 `NIF_MCP_BRIDGE_BIN`，默认 `<root>/var/bin/mcp-bridge`，管理器会在崩溃或漂移后重新生成子进程。桥接的 argv 上不携带任何配置：它在启动时重新读取由 `--server` 指定的 `mcp` 记录（因此该记录始终是唯一事实来源），如果该记录被禁用则立即退出。当记录不可读或其存储的名称与 `--server` 不匹配时，它以 1 退出（随后监督器会退避并重试），并且 `--probe` 同样要求 `--server <name>`——探针的配置通过 stdin 传入。

- **命名**：工具以 `mcp_<server>_<tool>` 为前缀（niffler 小写约定，在目录中全局唯一）；描述带有 `[mcp:<server>]` 来源前缀。服务器名称必须匹配 `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`（≤32 字符，`bridge` 保留）；工具名称会被规范化为相同的字符集并限制在 64 字符以内。管理器会拒绝那些生成的工具名称与另一台服务器或某个目录工具冲突的服务器。
  每个桥接还会注册一个隐藏的辅助工具 `mcp_<server>_bridge_status
  {op: status|refresh}`（对 LLM 不可见），`mcp_servers` 通过它获取实时状态，`mcp_refresh` 通过它进行重连；`status` 携带 `connected`、工具和提示数量、`retiring`、`activeCalls`、`lastError`、`startedAt`、`lastUsed` 和 `idleMs`。
- **暴露**：默认按需（`x-harness.onDemand`）——schema 通过 `discover {component: "mcp-<server>"}` 进入会话，调用则通过 `invoke` 进行，因此 MCP 服务器永远不会使冻结的直接工具集膨胀。`"expose": "direct"` 会让某台服务器的工具进入每个新会话的快照——除非该服务器发布的工具超过 `NIF_MCP_DIRECT_THRESHOLD`（默认 10），此时桥接会将整台服务器推迟为按需。该阈值由桥接进程在宣告其工具时读取，因此在该子进程的生命周期内是固定的（修改它并重新生成桥接）。
- **惰性会话**：添加服务器时用一次真实连接（initialize + tools/list）进行验证，并将工具列表缓存到记录中；MCP 子进程/HTTP 会话本身在首次工具调用时启动，并在 `idleMs`（默认 5 分钟；上限 24 小时）后空闲退出。每次调用获得每次调用的超时（`timeoutMs`，默认 120 秒，上限 24 小时）。启动 harness 永远不会为 `npx`/`uvx` 的启动付出代价。
- **取消**：MCP 工具声明 `x-harness.sessionId`——会话运行器将实时会话 id 注入为 `__session.session`，被取消轮次的 `cancel.mcp-<server>` 事件（docs/WIRE.md）会立即中止进行中的 MCP 调用。直接调用方（CLI 脚本）通常得到 `""`，而未归属的调用永远不可取消——只有其 `timeoutMs` 约束它。直接总线路径上没有任何东西验证该字段，因此提供自己 `__session` 的调用方就指定了其调用所匹配的 id，任何携带该 id 的 `cancel.mcp-<server>` 都会取消它。
- **按引用传递密钥**：`env` 值、`headers` 值、`args` 和 `url` 可以包含 `${NAME}` 引用，这些引用在桥接连接或生成服务器时从 harness 环境解析——存储保留占位符，列表只回显键名，缺失的变量会使连接以清晰的错误失败，而不是发送空凭据。单独的 `$` 保持字面量。
- **沙箱**：stdio 服务器在守卫进程（`mcp-bridge
  --stdio-guard <cmd>`）下运行，该守卫拥有服务器的进程组并监视一条生命线管道——如果桥接死亡（包括 SIGKILL），守卫会先 SIGTERM 再 SIGKILL 整个进程组；内核 `PDEATHSIG` 为守卫本身兜底，因此 MCP 服务器永远不会比其 harness 活得更久。stdio 服务器继承固定的环境允许列表——`PATH`、`HOME`、`USER`、`LOGNAME`、`TMPDIR`/`TMP`/`TEMP`、`LANG`/`LC_ALL`、`SYSTEMROOT`、`SSL_CERT_FILE`/`SSL_CERT_DIR`、`XDG_CACHE_HOME`/`XDG_CONFIG_HOME`、`UV_CACHE_DIR`、`NPM_CONFIG_CACHE`——再加上记录的 `env` 所添加的内容。`SHELL` 和 `TERM` *不会*被传递，harness 环境中的 `NIF_*` 变量和密钥也永远不会到达它们。HTTP/SSE 服务器只能看到配置的 `Authorization` 头，且仅当它们指向服务器自身的源时——凭据永远不会被重放到跨源重定向目标（该重定向会被拒绝）。
- **结果大小**：MCP 结果 ≤64 KiB 时内联返回；更大的结果会溢出到 `$NIF_ROOT/var/mcp-results/result-*.json`，工具则得到一个机器可读的指针——`{text: <the first 16 KiB of the text
  plus a line naming the file>, spill: {path, bytes}, truncated: true}`
  （可用 `read`、`grep` 或 `bash` 读取），因此大结果永远不会撑爆上下文窗口。非文本内容部分和结构化内容会被 JSON 序列化进 `text`，而不是被丢弃。
- **漂移**：在每个新会话（以及服务器推送的
  `notifications/tools/list_changed`）时，桥接会重新列出服务器的工具；当契约发生变化时，它会持久化新的列表（尽力而为，rev 重试）并以 3 退出，于是监督器会重启它并宣告当前真相。
  退出会等待进行中的调用完成，因此漂移永远不会截断调用。目录与执行永远不会长时间不一致。如果该刷新无法持久化，桥接会以*退役*状态失败关闭，而不是崩溃循环：`mcp_servers` 会显示错误，服务器需要 `mcp_refresh`（在活动调用完成后）或 `mcp_edit` 才能恢复。
- **隔离**：每台服务器一个进程；挂起或崩溃的服务器不会拖垮其他服务器（监督器的失败退避会重启它）。某台服务器的工具在移除后仍会在现有会话中保持其冻结的 schema——调用随后会通过正常路由失败。

### The record

每台服务器一个存储文档（kind `mcp`，id = 规范化后的服务器名称；`mcp_servers` 列出它们时会**隐去** env/header **值**）：

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

`type` 选择传输方式：`stdio`（默认；`command`+`args`+可选的
`env`/`cwd`）、`http`（streamable HTTP；`url`+可选的 `headers`）或 `sse`
（`url`+`headers`）。`approval: "always"` 会以人工审批提示对服务器自身的每个工具——`mcp_<server>_<tool>`、其资源工具及其提示工具——逐次调用进行门控；`effect: "read"` 为 fabric 调度标记只读工具；`concurrency: "serial"` 用于无法处理重叠调用的服务器（默认通过 SDK 的有界 `ToolConcurrent` 为 `parallel`）。记录的
`timeoutMs` 不仅是运行时预算：桥接在注册时将其写入每个工具的
`x-harness.timeoutMs`，因此在该桥接进程的生命周期内是固定的。管理器拥有除缓存之外的每个字段：当服务器漂移时，桥接会重写 `tools`
**和** `prompts`。

### Tools

全部位于 `mcp` 组件上，全部按需。`mcp_add`、`mcp_edit` 和
`mcp_remove` 受审批门控（它们发出的 `core.spawn`/`core.remove` 也是如此）；`mcp_refresh`、`mcp_servers` 和 `mcp_search` 则不受门控——刷新只会重新列出已经获批的服务器。

| 工具 | 用途 |
|---|---|
| `mcp_servers` | 列出记录 + 实时桥接状态（已注册工具、会话状态、最后错误）。停滞的桥接永远不会阻塞列表（1 秒状态超时，8 并发）；如果目录不可达，该行报告 `live: false` 而不是失败 |
| `mcp_add` | 用一次真实连接验证（通过探针模式下的桥接——配置在 stdin，无总线），存储带有缓存工具列表的记录，生成桥接。验证超时：30 秒或 `timeoutMs`（若更高）（`NIF_MCP_PROBE_TIMEOUT_MS` 可覆盖）——`npx`/`uvx` 服务器的首次运行会下载包。`enabled: false` 会存储一个停放配置而不连接或生成（`mcp_edit {enabled: true}` 稍后激活它）。如果桥接在 15 秒内未注册，记录仍会被存储，调用返回 `ok` 外加一个指明 `var/logs/mcp-<server>.log` 的 `warning` |
| `mcp_edit` | 合并提供的字段，重新验证，重新生成（或在禁用时停止） |
| `mcp_remove` | `core.remove` 桥接（不会在启动时复活）+ 删除记录 |
| `mcp_refresh` | 强制桥接丢弃其会话，立即重连并重新列出 |
| `mcp_search` | 按关键词查询官方 MCP Registry 中的服务器（只读）；为可安装的 npm/PyPI 条目返回现成的 `mcp_add` 参数 |

服务器的自身工具只有在桥接生成后才会出现在目录中——就在 `mcp_add` 之后，或在启动时从恢复的组件记录中出现。

因此，添加 MCP 服务器按设计需要两次审批：一次针对
`mcp_add` 本身，一次针对它触发的 `core.spawn`——这是对改变 harness 形态的人工门控（docs/ARCHITECTURE.md）。`mcp_edit` 同样需要两次（编辑，然后重新生成），`mcp_remove` 也需要两次（移除，然后 `core.remove`）。

### Prompts, resources, registry

- **提示变成斜杠命令。** 每个服务器提示都注册为一个
  隐藏的目录工具 `mcp_<server>_prompt_<promptname>`（对 LLM 不可见，`x-harness.hidden`），外加一个斜杠命令 `mcp-<server>-<promptname>`，
  其命名参数镜像该提示的参数（每台服务器 ≤32 个提示，每个 ≤16 个参数）；第二个隐藏的通用工具
  `mcp_<server>_prompt` 为客户端按名称渲染任意提示。渲染提示是一次普通的
  总线调用；结果将渲染后的文本作为 `userMessage` 携带，UI 将其作为**用户**消息追加到会话中（斜杠结果约定，
  `ui/frontend/src/lib/slashResult.ts`）——提示输出永远不会作为 system/assistant 内容注入
  到记录中。桥接在漂移时像工具一样重新注册它们（包括服务器推送的 `notifications/prompt_list_changed`）。
- **资源**表现为一个并发工具 `mcp_<server>_resources`
  （`x-harness.effect: "read"`）：`{op: "list"}`、`{op: "templates"}`（URI
  模板）或 `{op: "read", uri: ...}`。
  文本结果遵循与工具结果相同的 64 KiB 内联上限（更大的溢出到 `var/mcp-results`）；二进制 blob 以 base64 返回，并带有 MCP
  mimeType。
- **注册表**：`mcp_search <query>` 查询官方 MCP Registry
  （`registry.modelcontextprotocol.io`；用 `NIF_MCP_REGISTRY_URL` 覆盖）
  并返回 name/title/description/version 以及针对 npm/PyPI 打包条目的建议 `mcp_add`
  配置——版本从注册表固定
  （`npx -y <id>@<v>` / `uvx <id>==<v>`）。条目只有在需要零配置时才被标记为 `installable`；包
  id 中的模板变量或声明的必需 env/headers 会作为 `requirements`
  （"configuration required: ..."）出现，而不是半填充的配置。失败会逐字报告
  （`registry unreachable: …`、`registry returned status N`、`bad registry
  payload`）；浏览永远不会改变任何东西——在返回的参数传给 `mcp_add` 之前不会安装任何东西。
- **漂移也覆盖提示**：`checkDriftLocked`（新会话）和两个
  list-changed 通知都会重新列出工具*和*提示；记录的缓存
  被刷新，桥接以 3 退出以便监督器重启。

### Verification

`tests/t_mcp.nim`（在 `make test` 中）：将一个无依赖的夹具 MCP
服务器（`tests/fixtures/mcp_server.nim`，基于 stdio 的换行分隔 JSON-RPC）和一个模拟注册表（`tests/fixtures/mock_registry.nim`，仅用标准库的
HTTP）编译进一个私有沙箱，并演练整个契约——添加（带
密钥隐去）、桥接注册、发现提示 + 完整 schema、惰性
调用、工具错误传播、飞行中取消（`cancel.mcp-<server>`
中止进行中的调用）、资源 list/read、提示斜杠命令 +
渲染、针对模拟的注册表搜索、服务器推送的漂移（持久化 +
重启 + 重新发现）、编辑/重新生成、用于启动
恢复的生成参数持久化，以及移除。两个回归测试固定了进程卫生修复：被
SIGKILL 的守卫必须不留下孤立的 MCP 服务器（内核 `PDEATHSIG`），并且
失败的添加必须不留下记录。Go 单元测试（`make gotest`）覆盖
SDK 的冻结注册门控（`Announce` 在延迟注册时 panic；
就绪后调用以 `not-ready` 失败）、名称/契约验证、注册表
形态解析、传输凭据/重定向规则，以及取消管道。

## Progressive tool discovery

状态：**已实现**。

Niffler 保留一份完整的全局目录，同时向每个会话暴露一组小而不可变的工具集。额外的 schema 通过 `discover` 进入仅追加的消息历史；对这些工具的调用则通过固定的 `invoke` 网关进行。这减少了提示词膨胀，同时不削弱核心的审批或超时策略。

### Model

#### Existence is global; exposure is per conversation

组件在总线上存活时即存在。`reg.publish` 将其所有工具插入 core 的目录；`reg.depart` 或 supervisor 清理会移除它们。`var/bin` 下的二进制文件在 manifest 自动启动、`core.spawn` 或插件安装启动它之前是惰性的。

暴露是另一个独立的问题：

| 级别 | Schema 元数据 | 直接 LLM schema | 发现 | 调用 |
|---|---|---|---|---|
| direct | 缺少 `x-harness.onDemand` | 包含在新的会话快照中 | 提示 + schema 查找 | 直接调用或 `invoke` |
| on demand | `x-harness.onDemand: true` | 省略 | 提示 + schema 查找 | `invoke`（当会话没有工具允许列表时，按裸名称调用也会派发） |
| hidden | `x-harness.hidden: true` | 省略 | 省略，包括显式查找 | 仅限 components/core |

如果两个标志同时存在，hidden 优先。一个同时带有 `x-harness.runner: true` 的隐藏工具可豁免于子代理的冻结工具允许列表——这就是可替换的 runner 机制（compactor）如何触达一个在其存在之前就已冻结工具集的子代理。这两个标志必须同时具备：一个带有 `runner` 但没有 `hidden` 的按需工具**不**豁免，并且会像任何其他不在其 `tools` 列表中的工具一样，在允许列表会话中被拒绝。暴露不是 ACL：
完整目录仍然是路由的权威依据。面向 LLM 的
`invoke` 网关拒绝隐藏目标，而组件仍可通过 NATS 直接请求隐藏工具。

#### Full catalog and projections

- `catalog {op: "snapshot"}` 返回完整的组件注册和
  schema。会话 runner 从中初始化其本地目录。
- `catalog {op: "components"}` 返回 CLI 使用的完整组件到工具名
  映射。
- `catalog {op: "list"}` 返回当前按名称排序的、面向*新*会话的
  直接投影。它不是现有会话的工具集。
- 派发、审批、`x-harness.timeoutMs` 以及组件到组件的调用
  始终查询完整目录。

### Core tools

`discover` 和 `invoke` 是每个新会话中的直接核心工具。`profile` 是一个按需核心工具，用于管理命名工具配置文件；`session.profile` 在会话首次创建时选择一个。Web UI 或 TUI 中的 `/profile` 设置 `/new` 使用的客户端默认值。
`session_info`（onDemand）汇总一个会话（头部字段、
按角色的消息计数、累计完成 token 数）；`prompt_preview`
（onDemand）显示组合请求的来源——系统提示词来自哪里、有多少项目上下文文件为其提供输入、冻结的直接工具名与目前已发现的 schema 的对比、消息/token 计数——而不发送任何内容。`doctor`（onDemand）是一次性的机器可读健康报告：
存储可达性、llm 注册、活动 provider、systemprompt
存在性、目录大小、会话数量，外加一次自检扇出——
每个注册了标准 `selftest` 工具（docs/WIRE.md）的组件都会被要求检查自身，其每项检查结果会被收集到报告中（未实现该工具的组件会被列为未实现）。使用 `deep: true` 时，探测会实际运行——lsp 组件针对一次性 fixture 启动每个已配置的语言服务器（干净文件 → 0 诊断、悬停有应答、损坏文件 → 错误），repomap 检查映射一个一次性工作区并断言两个追加门都会触发，存储在其引擎上运行完整的 put/get/rev/list/del 往返。快速模式保持低成本（仅二进制解析）；可用作 CI 存活门或第一步诊断。UI 将其暴露为 `/doctor`。报告还在 `text` 中携带一个渲染后的 Markdown 表格（即 `/doctor` 显示的内容），并且 `ask: true` 会添加一个 `userMessage`（docs/WIRE.md 约定），以便客户端以用户轮次提交解释请求。

#### Explicit client commands

聊天客户端无需 LLM 轮次即可暴露相同的目录状态：

- `/components [all|direct|discovered|undiscovered]` 列出存活组件，并按每个工具在当前会话中的暴露情况过滤。`direct` 表示 schema 在请求 tools 数组中；`discovered` 表示它已在历史中已知并可通过 `invoke` 调用；`undiscovered` 表示它存活但尚未暴露给此会话。
- `/discover COMPONENT` 或 `/discover tool=NAME` 执行显式发现请求，并将返回的 schema 记录到会话的持久发现摘要中。它不会将工具提升到直接数组中；当需要直接 schema 暴露时，请在 `/new` 时使用 profile，或使用带 `sticky: true` 的 `invoke`。
- `/profile NAME` 为新会话选择一个命名配置文件；`/profile default` 清除该选择。更改它绝不会重写现有会话的冻结暴露。

Web Components 面板提供相同的 all/direct/discovered/undiscovered 过滤器以及文本搜索。隐藏工具保持内部状态，绝不会被 `/discover` 列出。

#### Hints

```json
{"query": "web"}
```

`query` 是可选的，并以不区分大小写的方式匹配组件名、工具名和描述。多词查询是合取：每个以空白分隔的词都必须出现在组件名或工具名/描述中——像 "mechanical fan-out" 这样的关键词短语即使没有任何描述逐字包含它也会匹配。空查询返回仅含工具名的总线目录；`component` 和 `tools` 调用返回完整描述和 schema。结果是确定性的：组件和工具按名称排序，描述是空白归一化的一行提示，上限为 200 个字符，并且排除 pid 和注册时间等易变字段。

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

`discover {component: "fetch"}` 返回该组件的直接和按需提示。没有非隐藏工具的组件会被省略。

#### Schemas

只请求下一步所需的工具，一次最多 16 个：

```json
{"component": "fetch", "tools": ["fetch"]}
```

结果包含归一化的完整 schema，按工具名排序：

```json
{
  "component": "fetch",
  "tools": [
    {"name": "fetch", "schema": {"type": "object", "properties": {}}}
  ]
}
```

未知和隐藏工具请求具有相同的错误形状，因此发现不是隐藏工具存在性的预言机。

不带 `component` 的 `tools` 会搜索每个存活组件——调用者通常知道工具名但不知道其所有者。每个返回的 schema 随后会携带所属的 `component`，而没有可发现工具的名称会列在 `notFound` 中（空 schema 集是一个错误，会列出所请求的工具）。

#### Invocation

通过固定网关调用已发现的 schema：

```json
{
  "tool": "fetch",
  "arguments": {"url": "https://example.com"}
}
```

`invoke` 递归进入正常的 `dispatchToolCall` 路径。因此目标工具的审批对话框、超时、组件路由和错误的行为与直接调用完全一致。它还可以触达会话启动时不存在的新注册的非隐藏工具。

### Session state and caching

Provider 提示词缓存包含顶层工具定义。将已发现的具体 schema 添加到后续 `tools` 数组会改变前缀并使累积的缓存失效。仅将 schema 作为工具结果返回是仅追加的，但模型仍需要一个声明的函数来调用它；这就是 `invoke` 固定且通用的原因。

在第一轮，会话 runner：

1. 计算 `Catalog.promptTools()`；
2. 将精确的有序 schema 存储在存储 kind `session`、id
   `<sessionId>:tools` 下；
3. 在每一轮 LLM 以及 runner 重启后使用该快照。

文档形状为：

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

`direct` 携带 schema，因为它是可安全恢复的 provider 快照。
`discovered` 是用于检查和 UI 状态的持久摘要；schema
本身存在于持久化的工具结果消息中。只有成功的
完整 schema `discover` 调用才会更新它。提示搜索和失败的查找不会。

组件注册变动绝不会改变现有会话的直接数组。迟到的组件通过 `discover` 被发现，并通过 `invoke` 调用。如果直接组件离开，其冻结的 schema 仍保留在该会话中以保持缓存稳定；调用会通过正常路由失败，而当前发现会反映它已消失。

### Shipped policy

在完整的随附 manifest 中，有 7 个工具是直接的（profile 或 `invoke {sticky: true}` 可以为单个会话扩大该集合）：

- 核心：`discover`、`invoke`。
- 日常工作：`bash`、`grep`，以及文件工具
  `read`/`edit`/`write`（`edit` 组件）。

长尾工具是按需的：

- 搜索和检查：`files`（排序列表）、git
  工具、`undo_last_edit`、`context_recall`（命名被替换内容的通知所指向的内容）、`repo_map`（模型显式请求的排序工作区映射），以及 `observe_*` 诊断加上
  logfile 的 `logfile_search`/`logfile_paths`。
- 状态和内省：存储 `get`/`list`、`session_info`，以及
  技能入口点 `skill_list`/`skill_load`（仅当某个工作流指南适合任务时才加载）。
- 编排：`fabric`、`agent_*` 和 `expert_*` 工具。
- 核心生命周期/状态/目录、builder、插件和 fetch。
- 模型和 provider 管理。
- 技能资源、在线搜索、安装和移除。

内部工具保持隐藏：核心 `session`/`session_prepare`、存储
`del`、LLM `chat`/`llm_resolve`、systemprompt 提示词、压缩接缝的
`compaction_propose`，以及
携带凭据的 provider 工具（`provider_update`、
`provider_use_environment`、`provider_status`、`provider_active`、
`provider_get`、`provider_oauth_start`、`provider_oauth_complete`、
`provider_oauth_cancel`）。存储 `put` 是按需的（它携带
`x-harness.sessionId` 用于冻结工具集快照）。

缺少 `onDemand` 元数据仍为直接，以保持第三方兼容性。在会话启动后生成的组件仍不会改变该会话的冻结直接数组；discover/invoke 是新能力的握手。

### UI

Live Components 面板将全局 `core.status` 数据与活动
会话的暴露文档结合起来。工具 chip 使用文本加颜色：

- `direct`：在不可变的 provider 工具数组中；
- `seen`：其 schema 已在此会话中成功发现；
- `demand`：存活且非隐藏，但未在此会话中暴露；
- `internal`：对 LLM 隐藏。

组件存活状态仍是一个单独的状态点。面板会在会话
选择、目录变更、发现/完成事件、重连以及周期性
轮询时重新加载。删除会话也会删除其暴露文档。

### Verification

`tests/t_discover.nim` 是端到端契约。它证明了确定性的
投影和发现、完整目录保留、隐藏不披露、
通过 invoke 保留审批和超时、实际的会话 runner LLM
载荷、跨迟到注册的不可变行为、消息历史中的 schema 持久化，以及持久的 UI 暴露元数据。

单独运行它使用 `make test-discover`；它也是 `make test` 的一部分。

---

## Model catalog (`models`)

`models` 组件是 Niffler 可替换的 provider/model 元数据平面。
它不属于核心，也不是通用推理适配器。它
回答存在哪些 provider 和 model、如何寻址它们、它们
支持什么，以及它们的限制和价格。`llm` 组件仍然拥有实际的
线上协议、认证流程、请求转换和流式传输。

该设计借鉴了 Pi 和 OpenCode 中有用的共同形态：

- models.dev 是广泛的精选基线。
- 一个小的嵌入式种子使首次离线启动有用：刻意很小——
  仅附带 `deepseek` provider 及其 `deepseek-chat` 和 `deepseek-reasoner`，
  以便配置的默认值在离线时继续工作。其他一切
  在获取基线或由 source/override 提供后出现。
- 最后一次验证的下载以原子方式写入，并在失败时保留。
- 更正和 provider 发现是确定性层，而不是对
  下载文件的编辑。
- 用户提供的 model id 严格解析；有歧义的裸 id 绝不
  按目录顺序选择。

### Merge order

有效目录按以下顺序重建：

1. `NIF_MODELS_PATH`、缓存的 models.dev 目录或嵌入式种子。
2. 已注册的 `x-models-source` 插件，按 `priority` 升序，然后按
   `component/tool`。因此较大的 priority 胜出。
3. `NIF_MODELS_OVERRIDE`，始终最后。

插件层和本地层是 JSON Merge Patches（RFC 7396）：对象合并，
数组和标量值替换，`null` 删除键。完整的
models.dev 形态被保留，包括 Niffler 尚未使用的字段——因此
一个 patch 可以添加整个 provider、在现有 provider 下添加 model，或更改任何
字段。省略 `id`/`name` 的 provider 或 model 会从其 map
键填充，非对象条目在规范化期间被丢弃。

该组件在启动时刷新，每当组件目录变化时（一次
注册或一次离开），然后在 `NIF_MODELS_REFRESH_INTERVAL`
（默认一小时；`0` 禁用周期性 tick）。当其缓存年轻于五分钟时，
models.dev 下载被跳过。HTTP 获取有界
（16 MiB，每个请求 12 秒），最多重试三次，退避 200/400 ms，
在客户端错误上快速失败，经过验证（没有可用 model
条目的目录被拒绝，因此格式错误的响应不能替换最后已知良好的
缓存），并以原子方式
重命名为 `var/models/api.json`。每个已注册的插件源也有一个
最后已知良好的 patch，名为 `<component>--<tool>.json`，位于
`var/models/sources/` 下（`A-Za-z0-9-_.` 之外的任何内容变为 `_`）；该 patch
在源暂时失败时使用，但仅在源组件
保持注册期间——移除组件会一步丢弃其注册、状态和
缓存 patch，因此已离开的源不能继续影响
目录。本地 override 在文件在重写中途不可读时保留其先前的 patch。
失败的刷新会自动重试（30 秒或配置的间隔，以较早者为准），
因此没有 `reg.depart` 的崩溃协调不会搁浅到下一个每小时 tick。`ev.sys.drain`
取消刷新工作并关闭该组件。

### Tools

| Tool | Purpose |
|---|---|
| `models_providers` | provider 连接元数据和配置状态，绝不包含 secret 值 |
| `models_list` | 带能力、模态、限制和成本的过滤 model 搜索 |
| `models_get` | 供其他组件使用的精确 provider/model 描述符 |
| `models_resolve` | 严格的 `provider/model` 或全局唯一裸 id 解析 |
| `models_refresh` | 排队刷新 models.dev 和每个活跃扩展源：它立即返回*当前*来源报告以及 `queued` 和 `force`，工作在异步进行（注册突发在 150 ms 内合并），因此再次读取 `models_sources`——或等待 `ev.models.updated`——以查看结果；`force: true` 绕过缓存 TTL |
| `models_sources` | 来源、新鲜度、过期回退和错误诊断 |

所有六个工具都是 `onDemand`：它们不在会话的冻结
直接工具集中，因此模型通过 `discover` + `invoke` 访问它们。
组件和 `cli call` 按名称直接寻址它们。这里没有
`hidden`，因此 `/discover tool=models_sources` 会列出它们。

`models_resolve` 绝不猜测：存在于多个 provider 下的裸 id
返回 `found: false` 并带 `matches`，未知引用返回
`found: false` 并带最多十个 `suggestions`；前缀不是已知 provider id 的
`provider/model` 字符串会作为字面裸 id 查找，因此
拼错的 provider 看起来像缺失的 model。成功时答案携带
选定的 `provider`、`model`、`reference`、`configured` 以及目录
`updatedAt`。

`models_list {status: "active"}` 也匹配 status 字段缺失的 model
（models.dev 对正常 model 省略它）。列表结果在
超过总线负载限制时被裁剪，过大的单个描述符
会报错，而不是在线上超时。描述符元数据被递归
脱敏：类似 secret 的键（api keys、tokens、passwords、credentials、
authorization headers、private keys、cookies）绝不到达调用者，在
provider 或 model 级别。参数形态：`models_list` 接受 `status`、
`provider`、`query` 和 `limit`（默认 50，最大 500）；`models_get` 要求
`provider` + `model`；`models_providers`/`models_sources` 不接受参数。
列表式结果是 `{models|providers, count, total}`，并在
超过总线负载限制时以 `truncated: true` 裁剪，而一个
过大的 `models_get` 描述符会报错，而不是在线上超时。

活跃源：models.dev 是元数据权威（限制、定价），但
provider 实际提供的 id 来自 provider 本身。存在两个
互补表面——`provider` 组件的 `provider_models`
工具使用存储的或显式凭据按需探测端点（
连接形式），而 `llm` 组件的隐藏 `llm_models_source` 工具
注册为 `x-models-source` 插件（priority 150），其 patch 添加
每个 provider 被观察到提供的 id。其背后的探测是每个目录 provider + base-URL 键每 10 分钟一次后台
`GET {baseUrl}/models`
（8 秒超时；id 仅存在于内存中，因此重启会忘记它们直到
下一次聊天，并且该工具在探测成功之前回答 `no live model data yet`；Codex 通道被排除，因为 ChatGPT 后端不暴露
此类路由），因此整个目录收敛到端点真正列出的内容。两者
都是尽力而为：失败绝不影响聊天或目录基线。

`llm` 向 `models_get` 询问所选 model 的上下文窗口。显式
provider `context` 和 `NIF_OPENAI_CONTEXT` 仍然胜出，并且如果移除 `models`，现有的小
回退仍然可用。Provider 端点按主机名分类，而不是 URL 子串。交互式客户端应调用
隐藏的、无凭据的 `llm_resolve {model?}`，而不是复制此
优先级：它报告有效的全局 provider、可选的会话
model override、目录、上下文以及每个值的来源。

### Source plugins

model source 是由 `plugins` 安装的普通组件。一个隐藏
工具携带此注册扩展：

```json
{
  "x-models-source": {"version": 1, "priority": 200},
  "x-harness": {"hidden": true}
}
```

契约：`x-harness.hidden` 标志是约定，`x-models-source`
扩展才是注册该工具的东西；`version` 必须恰好为 1，否则该工具
被跳过；`priority` 默认为 100，相同 priority 按
`component/tool` 排序。`models` 从 `reg.publish` 和
核心的完整目录快照中发现标记的工具，因此组件启动顺序无关紧要。它以 `{"version": 1}` 和 30 秒截止时间调用
该工具；没有 `patch`
对象的结果算作失败，保留最后已知良好的 patch。结果是
一个 JSON Merge Patch（RFC 7396）：

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

一个完整的可运行 source 组件——marker、tool、包布局和
验证——在 [MODEL_SOURCES.md](MODEL_SOURCES.md) 中。

将 source 放在普通的 `niffler.json` 包中。安装、更新、
移除、进程隔离和持久化已由现有的
`plugins` 和核心生命周期处理。移除 source 组件会立即从有效目录中移除
其 patch。核心不添加任何 model 特定的扩展机制。

### Configuration

配置变量（`NIF_MODELS_*`）列在上面的主
[Environment variables](#environment-variables) 表中。

修复或添加元数据的最便宜方式是 JSON Merge Patch 文件：

```json
{ "deepseek": { "models": { "deepseek-chat": { "limit": { "context": 131072 } } } } }
```

由 `NIF_MODELS_OVERRIDE=/abs/path/override.json` 指向（仅环境变量，
因此更改它意味着 `core.kill` + `core.spawn`）。它在每次
重建时重新读取，在所有插件 patch 之后合并，并且 `null` 删除键。在重写中途不可读的文件保留
先前的 patch，并由 `models_sources` 报告为 `stale`。上面的插件路径仍然是持久、可共享的
选项。

该组件仅报告 provider 使用哪些凭据环境名称
以及是否设置了其中一个，在调用时计算并附加到 provider 和
model 结果。*Configured* 意味着：provider 的 `env` 名称之一已设置，或
该 id 作为昵称出现在 `NIF_LLM_PROVIDERS` 中，或——对于附带的
`deepseek` 条目——`NIF_OPENAI_API_KEY` 已设置。它绝不返回凭据
值。Provider 特定的
OAuth、环境凭据、headers、请求转换和原生 API
行为属于推理适配器组件，它们可以独立于此目录作为插件附带或
安装。

#### Verification

`make test-models` 启动一个带有本地 fixture 目录的私有 harness，并
证明注册、严格解析，以及构建的 source 插件的 patch
在 spawn 时出现并在移除时消失。针对活跃 harness，
`./var/bin/cli call models_sources '{}'` 打印来源，并且
`./var/bin/cli call models_get '{"provider":"deepseek","model":"deepseek-chat"}'`
打印一个描述符。

---

## System prompt (`systemprompt`)

状态：由 `systemprompt` 组件**已实现**。

### Boundary

系统提示不是 LLM 调用的工具——它是每个会话开始时
所处的常驻指令集。它存在于组件中，
而不是核心中：核心只保留最小的结构性回退，并且会话
运行器每个会话从 `svc.systemprompt.call` 获取真正的宪法一次。替换宪法是正常的 Niffler 操作：编写一个
在同一 subject 上应答的组件——subject 派生自
组件名称，因此它必须注册为 `systemprompt`——`build` 它，
`kill` 旧的（`core.spawn` 拒绝已被
监督的名称），然后 `spawn` 你的。不过，交换只持续到下一次
启动：在 `manifest.yaml` 中声明的组件会首先恢复，并且同一名称的存储记录会被跳过，因此永久
替换意味着编辑 `manifest.yaml`。agent 可以对自己
这样做。

### How it works

- **每个会话冻结。** 解析后的提示在
  第一轮持久化到会话头（`systemPrompt` 字段），并在任何运行器进程中的每次恢复时逐字重用。提示前缀保持
  稳定，以便 provider 重用它；在会话中途死亡或变化的组件绝不重写运行中会话的指令。
- **回退。** 组件缺失、缓慢（500 ms 探测，然后当目录说它已注册时 8 秒预算）或损坏 → 核心内置的
  最小提示。核心绝不为启动硬依赖组件。
- **上限。** 答案在 200 KB 处截断（两侧）——组件自身在 200 000 字节处停止（标记 `[systemprompt: truncated at 200000 bytes]`；
  核心添加自己的）并最多收集 16 个上下文文件。两个数字都是
  编译时常量，没有环境变量旋钮：不同的上限意味着重建
  该组件。
- **Agent 预取。** `agent` 组件在子 agent 的第一轮之前为其请求提示，并通过会话
  调用的 `systemPrompt` 字段传递它（尽力而为——运行器自己的回退
  覆盖缺失的组件）。
- **提示槽（扩展接缝）。** 组件和插件通过隐藏的 `prompt_hint {slot, content, source?, key?,
  mode?}` 工具贡献片段：命名槽（`tool_usage`、`efficient_tools`、
  `after_instructions`）以确定性顺序（按 `source`，然后 `key`）渲染为 `<prompt_slot name="…">` 块；
  `mode: aggregate`（默认）
  保留每个贡献，`mode: singleton` 仅保留为该槽注册的最后一个，而没有贡献的槽渲染
  为空。注册是组件本地状态，仅影响在其*之后*组合的提示——冻结的会话绝不重写。
  `prompt_hint` 也是 `x-harness.hidden`，因此它和 `systemprompt`
  都绝不出现于 LLM 工具集中。

### The default component's prompt assembly

1. `components/systemprompt/baseprompt.txt`——产品提示
   （变更范围纪律、工具选择指导、文档指针），
   在编译时通过 `staticRead` 逐字烘焙进二进制——没有
   替换，也没有模板。编辑它是
   重建 + 重新 spawn；没有运行时文件依赖。
   产品提示也是教会模型被替换内容
   补救措施的地方：被修剪的工具结果、溢出的命令输出和压缩
   检查点可通过 `context_recall` 检索，方法是逐字传递通知中引用的 ref——削弱那句话，每个修剪、溢出和
   压缩通知都不再被遵循。
2. 仓库的本地上下文文件，Pi 风格，在产品提示之后包裹在
   `<project_context>`/`<project_instructions path="...">` 标签中：
   - 每个目录，首次命中胜出：`AGENTS.override.md`、`AGENTS.md`、
     `AGENTS.MD`、`CLAUDE.md`、`CLAUDE.MD`（每个目录一个文件——
     `AGENTS.md` 遮蔽旁边的 `CLAUDE.md`；符号链接被跟随；
     `AGENTS.local.md` 是额外添加的，绝不是候选：它绝不
     遮蔽主文件，并且它为遍历的每个目录收集，而不仅是惰性收集）；
   - 从会话的 cwd **向上到 harness 根
     （含）**的祖先遍历，根优先，按文件身份（device:inode——
     符号链接农场不能注入同一文件两次）去重；更靠近 cwd 的文件
     稍后出现，因此最具体的指令是模型最后读到的东西。harness 根**之外**的工作区仅遍历自己的
     目录，因此 `$HOME` 中无关的 `AGENTS.md` 绝不泄漏到
     提示中；
   - worktree 遮蔽规则：当 harness 根是主仓库下的 `git worktree` 时，主仓库根的上下文文件被跳过——
     否则祖先遍历会应用同一逻辑仓库范围两次；
   - 惰性加载：进入 harness
     根*之下*目录的 `read` 会为路径上的目录追加任何新发现的 `AGENTS.override.md`/`AGENTS.md`/
     `AGENTS.MD`/`CLAUDE.md`/`CLAUDE.MD`（+ `AGENTS.local.md`），每个包裹在 `<lazy_project_instructions
     path="…">` 中，每个会话一次——monorepo 子树在模型实际进入之前
     不进入冻结头部。
3. 每个会话的 `<workspace>` 尾部，仅在
   会话的 cwd **不是** harness 根时追加：它命名工作
   目录（相对路径从它解析）和 harness 根，因此
   从根外工作区，`docs/`、`components/` 和 `sdk/` 按绝对路径解析。无论哪种方式，上面的冻结头部保持无路径——
   根是每个会话的事实，对于一台机器上的每个会话都相同，因此 provider 缓存前缀仍然对齐。

该工具是 `x-harness.hidden`——它绝不出现于 LLM 工具集；它是
基础设施，仅可由核心和组件访问。

## Observation and logs

Status: **implemented** by the `observe` and `logfile` components.

### Boundary

观察总线，而非组件内部。这两个组件都是基于 SDK 构建的普通 NATS 公民；core 从不导入它们。唯一的 core 集成是可选的 nats-server HTTP 监控：当 core 拥有总线时，它会分配第二个回环端口，并在服务器上线后写入 `var/nats-monitor-url`。

观察是一项管理能力。总线捕获可能包含工具参数、模型输出、审批以及来自每个会话的数据。Niffler 当前的信任模型是单一受信任用户/管理员；不要将 observe 服务或捕获目录暴露给不受信任的总线客户端。它也无法被复制：环形缓冲区、探针和组件普查都是进程本地的，因此副本会把一个视图拆分成多个，并恰好放大这种暴露——正因如此，清单中未设置 `replicas`。

**不是审计追踪。** 这些组件都不是决策的持久记录：`observe` 保留一个有界的内存环形缓冲区，随组件消亡而消失，`logfile` 是尽力而为的（至多一次，默认 `ev.log.>`），`console` 打印后即忘，`hooks` 不记录任何内容。审批门控的唯一持久产物是客户端写入的授权记录（存储类型 `approval`）以及 core 写入 `var/approval-sources/<digest>.nim` 的程序源——不存在请求/裁决历史。

### `observe`: bounded live inspection

`observe` 有一个原始的 `>` 订阅。它保留原始 JSON 节点，包括未知的信封字段和裸注册负载。其同类 `console` 会解码每条消息：信封渲染为 `call`/`result`/`error`/`event`，而裸负载（`reg.publish` / `reg.depart` 注册）渲染为 `event <subject>` 后跟对象本身，结果行携带它所回答的工具（缩短的信封 id；归属来自已渲染调用的 id→tool 映射——SDK 的回复信封不携带工具名）。格式错误的 JSON 在是有效 UTF-8 时保留为 `{raw, decodeError}`；任意字节则使用无损的 `rawBase64`。超大消息以有界 base64 预览表示，而不是让一条消息耗尽进程。

全局环形缓冲区同时受消息数量和近似线上字节数限制——默认 2 000 条消息和约 16 MiB（`NIF_OBSERVE_RING`，钳制在 1..10000；`NIF_OBSERVE_RING_BYTES`，64 KiB..100 MiB），单条保留消息上限为 64 KiB（`NIF_OBSERVE_ENTRY_BYTES`，1 KiB..1 MiB——更大的消息以 base64 预览保留）。每个定向探针有独立的数量和字节上限——最多 2 000 个条目和 2 MiB（`cap`，钳制在 1..2000；`NIF_OBSERVE_PROBE_BYTES`，64 KiB..16 MiB）——探针数量也上限为 32（`NIF_OBSERVE_MAX_PROBES`，1..256），因此第 33 个 `observe_listen`/`observe_trace` 会失败，直到移除一个。已停止的探针在 `observe_remove` 释放其内存之前仍可查询。

| Tool | Use |
|---|---|
| `observe_subjects` | 当 core 可达时列出权威的组件/服务视图（`session-<id>` 组件映射到 `svc.session.<id>.call`）、固定的已知事件集（`reg.publish`、`reg.depart`、`ev.sys.drain`、`ev.catalog.updated`、`ev.llm.token`、`ev.session.>`、三个 `ev.approval.*` 主题、`svc.approval.>.request`、`ev.log.>`、`ev.models.updated`、`llm.cancel.>`），以及最常观察到的具体主题（前 100，排除 `_INBOX.*`）；core 视图是尽力而为的 250 ms `catalog` 请求，`*Truncated`/`dropped*` 计数器说明答案何时不完整 |
| `observe_listen` | 为 token 正确的 NATS 模式（`*` 和末尾 `>`）加上可选正则启动有界捕获；`cap` 默认为 500 并钳制在 1..2000，返回的 `probeId` 为 `pr-<id>`（`observe_trace` 相同） |
| `observe_trace` | 捕获对一个组件的调用，并按信封 id 关联结果/错误收件箱回复——它监视 `svc.<component>.call` 和带作用域的 `svc.<component>.<id>.call` 形式，`toolRegex` 按工具名过滤，`cap` 默认为 500（最大 2000），每个关联的回复携带来自单调时钟的 `elapsedMs` |
| `observe_probes` | 检查探针状态、保留字节、上限和待处理跟踪 |
| `observe_stop` | 冻结探针并保留其条目 |
| `observe_remove` | 删除探针并释放其内存 |
| `observe_events` | 查询探针或全局环形缓冲区，最新优先，支持时间/类型/组件/主题/正则过滤；`kind` 为 `call|result|event|error`，`component` 匹配 `svc.<component>.*`、`ev.log.<component>` 或信封自身的 `component` 字段，`subject` 是精确的具体主题，`limit` 钳制在 1..500 |
| `observe_logs` | 查询内存中最近的 `ev.log.*` 事件——仅环形缓冲区，持久历史请使用 `logfile_search`；条目携带 `component`、`level`、`msg` 以及发出者的 `at` 作为 `emittedAt`，存在时还有 `ctx`，`limit` 钳制在 1..500 |
| `observe_dump` | 经审批门控导出某个探针到 `NIF_OBSERVE_CAPTURE_DIR` 下（文件为 `<captureDir>/<probeId>.jsonl`，每个捕获条目一个 JSON 对象，目录以仅用户可访问创建——0700，文件 0600——拒绝符号链接目标，旧捕获按最旧优先修剪至字节配额和 256 文件上限；当即使修剪也无法容纳转储时，工具失败并报 `capture directory quota is exhausted`）；不接受任意输出路径 |
| `observe_monitor` | 读取 nats-server 连接/订阅计数和订阅最多的模式；经审批门控——它借用操作员的监控端点 |
| `observe_send` | 向具体的 `ev.*` 或 `llm.cancel.*` 主题发布事件；经审批门控 |
| `observe_request` | 向具体的 `svc.*.call` 进行诊断请求/回复；经审批门控。请求等待钳制在 100–30000 ms（`timeoutMs`），工具调用本身携带 `x-harness.timeoutMs: 35000` |

`observe_send` 不能发送 call/result/error 信封或注册。`observe_send`、`observe_request`、`observe_monitor` 以及会修改文件系统的 `observe_dump` 携带 `x-harness.approval: always`，因此 LLM 路径必须通过 core 的人工门控。直接与 `svc.observe.call` 对话的客户端已经是受信任的总线对等方，绕过 core 策略，正如它可以直接调用任何其他服务主题一样。生成的捕获按最旧优先修剪至字节配额和 256 文件上限。

跟踪请求在 60 秒后从待处理关联表中过期。探针主题、标签和正则表达式有固定的输入限制；超大探针条目被丢弃并计数，而不是保留在字节预算之外。工具响应在线上约 64 KiB 内联结果约定之前停止，并报告 `truncated`（或大型诊断回复的值字节元数据），而不是返回无界数据。

### `logfile`: rotating JSONL persistence

`logfile` 是尽力而为的进程本地持久化，不是审计日志。Core NATS 是至多一次：启动前或重启期间发出的记录会丢失。保证重放需要显式的 JetStream 设计。

默认输入是 `ev.log.>`。每个匹配 `[a-z0-9-]{1,64}` 的组件名一个文件，位于 `NIF_LOGFILE_DIR` 下（默认 `$NIF_ROOT/var/logs`；绝对值按原样使用，相对值相对于 harness 根解析）：

```text
var/logs/bash.jsonl
var/logs/bash.jsonl.1
...
```

`NIF_LOGFILE_SUBJECTS` 可以选择其他主题。非日志流量，包括全总线 `>`，进入单个 `bus.jsonl`；因此动态收件箱主题不会创建无界的文件描述符或文件名。组件日志文件数量有上限，多余/伪造的组件主题也回退到 `bus.jsonl`。多个配置的模式被视为一个本地过滤的并集，因此重叠模式对每个匹配的发布恰好持久化一次。列表在启动时验证：格式错误或超过 512 字节的模式、超过 64 个唯一模式或空结果会使组件以非零退出。有多个模式时，tap 为 `>` 并在本地匹配；单个模式则按自身订阅。

每行记录接收器时间和原始线上数据：

```json
{"receivedAt": 1780000000.25, "subject": "ev.log.bash", "message": {"v": 1, "id": "...", "kind": "event", "payload": {"level": "info", "msg": "..."}}}
```

格式错误的 UTF-8 输入使用无损的 `rawBase64`；文本格式错误的输入使用 `raw` 和 `decodeError`。接收器对每条记录打开、追加、刷新并关闭。轮转在重命名已关闭文件之前比较 `current size + record size`，因此精确边界的写入不会留下过期的文件句柄。大于配置文件大小的单条记录保留为活动文件，并在下一条记录之前轮转。`NIF_LOGFILE_KEEP=0` 不保留任何轮转代。轮转代命名为 `<file>.1` … `<file>.<KEEP>`，每次启动都会删除编号高于当前 `NIF_LOGFILE_KEEP` 的任何代——降低该旋钮会在下次启动时销毁历史。启动时磁盘上已有的 `.jsonl` 文件也计入 `NIF_LOGFILE_MAX_FILES`。

`logfile_search` 仅从保留文件中读取有界尾部，按 `receivedAt` 最新优先排序匹配记录，并报告 `truncated`、`scannedBytes`、格式错误行数和读取错误。结果还有编码的响应字节预算。结构化日志记录暴露 `component`、`level`、`msg`、`ctx` 和可选的发出者时间；原始总线记录暴露保留的消息。搜索从不信任发出者提供的时间戳用于 `since`/`until` 窗口。目录枚举受 `NIF_LOGFILE_DIRECTORY_ENTRIES` 限制，当存在更多文件时报告 `directoryTruncated`；搜索仍检查有界子集。

两个读取工具都是 `onDemand` 且不声明 `x-harness.effect`，因此 fabric 批处理宿主即使对读取也按写入调度。`logfile_search` 接受 `{component?, level? (debug|info|warn|error), regex? (≤1024 bytes), since?, until? (epoch seconds, `since ≤ until`), limit? (default 100, cap 500)}`；无效参数会作为*成功*结果内的 `{"error": …}` 返回，而不是作为错误信封，并且由于 schema 上没有 `timeoutMs`，调用在 core 的 120 s 默认截止时间下运行。

`logfile_paths` 报告最多 500 个保留文件，以及 `writeErrors`、`lastError`、`lastErrorAt`、`maxBytes`、`keep`、`subjects` 和组件文件计数。文件系统故障也会输出到 stderr。**日志目录**在平台允许的情况下以仅用户可访问创建（0700，文件 0600），日志路径上的活动符号链接会被拒绝。

### SDK APIs

所有三个 SDK 都暴露相同的观察/日志和原始信封 API：

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

每个 SDK 都让 NATS 执行主题匹配，并且只分派绑定到投递该消息的订阅的处理程序。这避免了以前的叉积问题，即一次调用可能通过 call、event 和 tap 路径多次投递。Nim 保持无回调和无线程；Go 使用其现有的互斥锁，TypeScript 使用其 promise 链。关闭时，Go 先排空订阅（至其有界关闭宽限期），然后停止每个组件的投递循环并等待所有正在运行的处理器完成，以保留欠给调用方的回复——已接受但尚未启动的调用会被拒绝，而不是静默丢弃；TypeScript 等待排队的处理程序，而不会死锁显式关闭自身组件的处理程序。

#### Idle work (`onIdle`)

所有三个 SDK 都暴露相同的*空闲接缝*——用于没有请求可以承载的工作的回调（回收后台子进程、健康探针、缓存刷新）。`components/processes` 用它来在无人轮询的情况下注意到后台子进程的退出，这正是其退出通知得以实现的原因。

```nim
proc onIdle*(c: Component, intervalMs: int, handler: IdleHandler): Component
```

```go
func (c *Component) OnIdle(interval time.Duration, handler func(*Component)) *Component
```

```ts
comp.onIdle(intervalMs, handler)
```

API 是镜像的；*执行模型*是各运行时的，因此契约按 SDK 陈述：

| SDK | runs on | exclusion |
|---|---|---|
| Nim | 泵循环，在轮次之间 | 处理程序运行时绝不——该循环是串行的 |
| Go | 自己的 ticker goroutine | 获取串行处理程序锁；`ToolConcurrent` 处理程序仅持有读锁，因此可能与它们重叠 |
| TS | promise 链，与每个处理程序一样 | 绝不与其他处理程序交错 |

三者共同点：在 connect/run 之前注册，每个组件一个处理程序（第二次注册替换第一个），间隔下限为 10ms，定时器随连接启动并在关闭时停止，空闲处理程序 panic 会被记录，绝不致命。当“每 N 秒”就是你所需的全部时，优先使用它而不是组件线程。

Nim 的任意信封请求助手在等待时仅继续泵送原始 tap 订阅。工具和事件处理程序保持非嵌套，而观察者可以在 `observe_request` 期间为目标的请求和回复打时间戳。跟踪持续时间和过期使用单调时钟；显示的 `at` 值保持为墙钟 epoch 秒。

结构化日志在确切主题 `ev.log.<component>` 上发布事件，内容为 `{component, level, msg, ctx?, at}`。级别为 `debug`、`info`、`warn` 和 `error`。`NIF_LOG_LEVEL` 默认为 `info`，并在每个 SDK 中于发布前抑制更低级别。发出的无效级别会失败；无效阈值回退到 `info`。

### Monitoring

当 core 生成 nats-server 时，它使用不同的回环客户端和 HTTP 端口，然后写入（二进制文件是存在时来自 `components/nats` 的已构建组件 `var/bin/nats-server`，否则是 PATH 中的 `nats-server`）：

```text
var/nats-url
var/nats-monitor-url
```

监控发现文件仅在客户端连接成功后写入。NATS 自行分配端口：core 传递 `--ports_file_dir <tmp>` 并从它写入的 `*.ports` 文件读回客户端和监控端口（有界 4 s 等待），因此并发 harness 无法赢得绑定-关闭-启动竞态。Core 在空闲时传递主端口，在启动隔离总线时传递 `-1`（随机端口）。复用或远程总线没有可发现的 HTTP 端点；请显式配置 `NIF_OBSERVE_MONITOR_URL`。`NIF_NATS_SPAWN=1` 强制在随机端口上使用隔离的 core 拥有的总线（主要用于测试和诊断）——绝不是 4222；环境中显式的 `NIF_NATS_URL` 优先。

一个请求承载整个对话，因此捆绑的总线以 `max_payload: 8388608`（8 MiB——约 2M tokens 的 JSON；超过此值 nats-server 仅警告）启动：捆绑的 `var/bin/nats-server` 将其作为额外标志，而 PATH 中的 `nats-server` 则在生成的配置文件中获得它。当 core 附加到它未生成的总线时，它读取服务器的真实上限，并在启动时当低于 8 MiB 时警告——这样的总线在发布时拒绝大型回复，调用者会等待其完整超时，这看起来像组件挂起而不是总线限制。

`observe_monitor` 为每个请求使用新的 HTTP 客户端读取 `/subsz` 和 `/connz`。它报告订阅详情是否被截断；`mostSubscribed` 表示订阅者密度，而非消息吞吐量。

所有 `NIF_OBSERVE_*`、`NIF_LOGFILE_*` 和 `NIF_LOG_LEVEL` 变量列在上面的主 [Environment variables](#environment-variables) 表中。

所有边界在启动时验证；无效配置以非零退出，而不是静默替换为默认值。

### Verification

`tests/t_observe.nim` 覆盖精确一次 tap、通配符边界、注册捕获、上限/字节驱逐、诊断请求期间的单调跟踪关联、格式错误调用回复、超时行为、嵌入 NUL 和无效 UTF-8 原始数据、响应边界、审批元数据、配额修剪的安全转储、监控发现和无效配置。

`tests/t_logfile.nim` 覆盖 SDK 日志过滤、最新优先查询、时间/正则过滤、编码响应和实际磁盘读取边界、精确一次重叠主题模式、已关闭文件轮转、零保留、嵌入 NUL 全总线保留、有界路径列表、接收器健康和无效配置。两个测试都使用隔离的临时输出目录，并且是 `make test` 的一部分。

## Fabric and subagents

`fabric` 组件添加了可编程的工具调用：模型编写一个 Nim 程序，由该程序自行驱动 Niffler 工具，只有程序的 `finish()` 值进入会话。`agent` 组件将会话转变为子代理。完整设计与威胁模型见：
[research/FABRIC.md](research/FABRIC.md)（塑造了它的外部评审：
[research/FABRIC_FEEDBACK.md](research/FABRIC_FEEDBACK.md)）。面向用户的指南，包含提示措辞与完整示例：
[FABRIC_GUIDE.md](FABRIC_GUIDE.md)。

| Tool | What it does |
|---|---|
| `fabric {code | name, tools?, strings?, timeoutMs?, maxCalls?}` | 运行一个由 LLM 编写的 Nim 程序：`var/bin/fabric-exec` 将其编译到一个私有进程中（无内嵌 VM；相同的程序会缓存在 `var/fabric-cache`，自身上限为 64 个条目 / 128 MB，按最近最少存储淘汰）。`code` 是内联程序源码；`name` 则改为运行来自模型策展的 `fabricprog` 库中的已存储程序。使用 `tools` 时，选定的 schema 会被固定，并生成编译期检查的 `tools.<name>(...)` 包装器；列入允许清单的 `callTool` 仍作为回退。只有 `finish(value)` 会进入会话。已批准的原生代码属于 bash 级信任，而非沙箱。预算：`maxCalls` 默认为 200（最大 1000），`timeoutMs` 默认为 240 秒（硬上限 300 秒，同时被限制在调用方剩余的会话截止时间内）；每个嵌套调用都继承本次运行的剩余时间，过大的 `finish()` 值会溢出到 `var/fabric-artifacts/<run>.json`（[FABRIC_GUIDE.md](FABRIC_GUIDE.md)，"Budgets and limits"）。 |
| `fabric_help {topic?}` | 从组件内部读取 Fabric 访客参考与完整示例源码；空的 `topic` 返回参考加上示例索引，指定 topic 则返回该程序。仅用于发现：当你即将编写程序时，通过 `discover` + `invoke` 访问它，这样你永远不必定位组件文件。 |
| `agent_run {task, session?, close?, fork?, model?, modelTier?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | 在子代理会话中运行任务并返回其最终回复。不带 `session` 时，它启动一个**全新**子代理（自有 runner、自有循环）：其 `model`/`modelTier`/`thinking`/`tools`/预算来自本次调用，并在其第一轮冻结，正如延续会话的冻结方式一样。带 `session`（先前返回的 `sessionId`）时，它给该**现有子代理再一轮**——其会话、模型、thinking、工具与预算都在其第一轮冻结，因此调用方的 model/thinking/tools/预算参数会被忽略，结果会报告子代理的 `effective` 控制项；该子代理必须属于本会话，必须未被关闭，且必须不处于轮次进行中（否则以 `code: "busy"` 拒绝——请改用 `agent_spawn` 排队）。全新运行的可选按作业预算：`maxRounds`（每轮工具轮数，1–`NIF_MAX_TURN_ROUNDS`）、`maxCalls`（工具派发总数，1-500）、`maxTokens`（累计 token）——耗尽会以预算耗尽失败结束该轮。`model` 是精确 id，而 `modelTier`（`weak`/`medium`/`strong`）通过 `NIF_AGENT_MODEL_*` 解析，并被限制在父级的层级——两者互斥。`close: true` 在本轮之后退役该子代理（不删除任何内容；后续延续会被拒绝）。 |
| `agent_spawn {task, session?, close?, fork?, model?, modelTier?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | 在后台启动同类任务；立即返回 `{jobId, sessionId}`。不带 `session` 时启动全新子代理；带 `session` 时为现有子代理**排队**另一轮（与 `agent_run` 相同的冻结控制规则，但轮次进行中的子代理没问题——该轮会在下一轮运行；只有谱系父级可以延续）。`close: true` 在排队/后台轮次结束后退役该子代理。`timeoutMs` 是作业预算：一旦超出，作业会在下次被观察时取消（agent_stop 语义）。 |
| `agent_status {jobId}` | 非阻塞的持久作业查询（running/done/failed/stopped + 回复或错误）。 |
| `agent_wait {jobId, timeoutMs?}` | 阻塞直到后台作业到达终态；迟到的等待读取持久记录。 |
| `agent_stop {jobId}` | 真正取消正在运行的作业：子代理的 LLM 请求被中止，其轮次立即结束，进行中的 bash 命令被杀死（整个进程树）。终态记录显示 "stopped"。 |
| `agent_steer {session_id, message}` | 向正在运行的后台作业的轮次注入一条消息（在 LLM 轮次之间排空）。 |
| `agent_ask {session, question, timeoutMs?}` | 向子代理提问并获取其回答。空闲子代理直接回答——这是普通的延续（`timeoutMs` 限制等待时间，默认 300 秒）——而**轮次进行中**的子代理无法开始第二轮，因此问题会作为父级邮件排队，并在其下一次延续时到达（结果会显示 `queued: true`、`deliveredVia: "next-turn"`）。与 `agent_run` 相同的谱系授权适用：未知、外来和已关闭的子代理会被拒绝。受审批门控。 |
| `agent_list {scope?}` | 调用方的子代理名册，源自持久谱系：每个子代理一行，包含其 `sessionId`、`jobId`、`task`，以及基于驻留状态的 `status`——`running`（正在工作）、`idle`（轮次之间驻留）、`ready`（仅存储；**可恢复，未完成**）。`scope: "descendants"` 遍历你下方的整棵树，而默认的 `children` 是深度 1 的视图；一旦 `NIF_AGENT_MAX_DEPTH` 提高到 1 以上，就存在真正的嵌套。子代理结束时你会被告知，因此这是用于定位，而非轮询。 |
| `agent_notices {session?, peek?}` | 排空本会话待处理的子代理**结算通知**——每个已完成、被停止或失败的后台子代理一条。通知会自动送达（见下文）；此工具用于在会话空闲期间到达的通知，`peek` 只查看而不消费。 |

### Settlement notices

到达终态的后台子代理会告知其**父会话**，而不仅仅是 UI（`ev.agent.done` 仅用于观察）。该通知是一条持久的 `agentnotice` 记录，在任何送达尝试之前写入，它是一个*指针*，而非回复：

- 当父级的轮次正在运行时，通知会立即被并入（steer 通道）为一条结构标记的用户消息；would-stop 点也会排空通知，因此轮次不会在其最后一步期间完成的子代理之上关闭（`NIF_AGENT_NOTICE_HOLD=0` 仅禁用该保持）；
- 否则父级会被**唤醒**：agent 组件启动一个轮次，其唯一工作就是并入待处理的通知，因此结算无需人类询问即可见。唤醒受 `NIF_AGENT_WAKES` 限制（默认 3 个连续唤醒轮次；人类的下一条消息会重置预算，`0` 禁用唤醒）。被拒绝的唤醒不持久化任何内容，父级的下一个轮次会在轮次顶部拉取所有待处理通知（pull 通道）——因此模型永远不必轮询；
- 无论哪种方式，通知都携带一个有界的 `summary`、`replyBytes`（未截断的长度）和 `fullReplyIn: "agent_status"`，因为完整回复已经持久存在于 `agentjob` 记录中，只差一次调用。

通知是尽力而为的：存储或 agent 组件不可达只会损失一条通知，绝不会损失一个轮次。

### Continuation (sessions with memory)

两个驱动都接受 `session`：先前返回的 `sessionId` 会给该子代理再一轮，而不是铸造一个全新的。子代理保留其会话——只发送新任务。授权是持久谱系关系（`sessionmeta.parent`），因此只有子代理自己的父会话可以延续它，并且每种失败都会明确拒绝：未知会话、根会话、外来子代理、已关闭子代理和不可达存储都会返回不同的错误，而不是静默启动全新子代理。

两个驱动的差异恰好在于其承诺的差异：

- `agent_run {session}` 承诺**现在**就有结果，因此轮次进行中的子代理会被拒绝（`code: "busy"`，并指明 `agent_spawn`/`agent_wait`/`agent_status`）；
- `agent_spawn {session}` 承诺工作**会发生**，因此它会排队——子代理的 runner 会串行化轮次，并在下一轮运行排队的轮次。

延续是仅追加的历史：后续任务被持久化为下一条用户消息（无前言、无系统提示），因此子代理的缓存前缀得以保留。每一轮都会推进子代理的激活账本（`sessionmeta.activations`，带有 `firstActivationAt`），后台延续会在其 `agentjob` 记录上标记 `continued`/`activation`。`close: true` 在轮次之后退役子代理（`sessionmeta.closed`）——记录与转录保留；只有进一步延续会被拒绝。

### Delegation depth

`NIF_AGENT_MAX_DEPTH`（默认 **1**）限制委托可以嵌套多深，在派发时通过遍历 `sessionmeta.parent` 链接来评估。`0` 完全禁止委托。生成工具在上限处仍然可见：被拒绝的启动会返回一个错误，指明该限制和调用方的深度，因此模型能了解原因。将其提高到 1 以上是一种刻意行为——子代理的同步 `agent_run` 由 agent 组件可重入地服务（见 WIRE.md "Delegation depth"），而来自子代理的 `agent_spawn` 完全不需要可重入（后台作业从不持有泵）。

### Fork (a child that has read the discussion)

`fork: true | {"lastK": n} | {"maxChars": n}`——仅在**全新生成时**（fork 是诞生，不是延续；`fork` + `session` 会被拒绝）——在子代理的第一次请求之前，用本会话的**已完成轮次**播种其消息日志，因此子代理是*读过*讨论，而不是被告知讨论。结果和 `session_info` 会携带来源信息（`{source, uptoId, copied}`）。

- **切分是平衡的且从 0 连续**：它只落在已完成轮次的边界上——绝不在工具轮次中间——并且种子是能作为有效提供方消息列表重放的最长转录前缀（每个 `tool_calls` 都有其工具记录应答，没有孤立的工具记录）。尾部的进行中轮次被排除；崩溃留下的悬空历史会在那里截断 fork（失败关闭胜过复制不平衡的前缀）。
- **预算在轮次边界切分**，如果选择丢弃了一切，则失败关闭——一个空的子代理会看起来像成功，但实际上是错误的。
- **不复制的内容**：每条消息的 `usage` 计量（子代理的核算自成一体）、`summary`/`error` 角色记录（summary 是对被原样复制的记录的派生；error 记录是父级的审计）、工具集快照（`<session>:tools`），以及头部的控制字段——fork 是诞生：调用方的 `tools`/`maxRounds`/… 参数从本次调用起冻结子代理的控制项，绝不是父级的。
- **冷启动**：子代理的第一次请求会以未缓存方式重放继承的历史；从第二轮起变热。这就是*判断力*继承的代价，只有当前言否则不得不叙述上下文时才是正确的取舍。无需判断力的大批量传输正是 `fabric` 的用途。

### Fabric (programmable tool calling)

- **治理，而非沙箱**：访客处于 bash 的信任类别——人类批准该程序一次（`x-harness.approval: always`）。每个嵌套调用都穿过会话嵌套调用代理（`svc.session.<id>.tool`），重新进入单一派发门（审批、完整 schema 验证、截止时间）。执行器子进程不持有 NATS 连接、无凭据、无继承的 `NIF_*` 环境：它只看到 `PATH`、一个临时 `HOME`/`TMPDIR` 和缓存路径。
- **审批清单**：程序审批会显示源码摘要、`var/approval-sources/<digest>.nim` 下的完整程序（模式 0600）、选定的工具以及声明的预算。持久化的自动批准以 `fabric:<digest>` 为键——批准一个程序绝不会覆盖另一个不同的程序。
- **防护**：代理拒绝隐藏工具和内部/递归表面（`fabric`、`agent`、`chat`、`session`、`invoke`、`session_prepare`）；每轮租约会过期陈旧请求；在类型化模式下，每次调用都会对照固定的组件指纹进行检查，因此运行中途被替换的组件会以 `catalog-changed` 失败，而不是调用一个漂移的工具；`maxCalls` 为调用设预算；
  `x-harness.noSpawn` 在派发时拒绝来自子代理的子代理生成。
- **效果感知批处理**：`batch()` 在总线上最多保持 4 个调用。每个工具按 `x-harness.effect` 分类（任何未声明的都算作写）；读可以一起填满上限，写是全局独占的，而非按目标。
- **上下文经济**：中间结果从不进入会话；过大的 `finish()` 值会溢出到 `var/fabric-artifacts/<run>.json`（模式 0600），工具结果会指向该路径。
- **访客 API**：`import fabricguest` 提供结构化的 `call(tool, JsonNode) ->
  JsonNode`、`batch`、`finish(JsonNode)`、`log`/`logg`、`stringArg`/`inputs`（加上遗留的 `callTool`/`j*` 字符串辅助函数）。`fabricmeta.nim` 将固定的运行时 schema 转换为输入类型化的包装器；除非工具声明了标量 `outputSchema`，否则结果是 `JsonNode`。`fabric_help` 工具从组件内部返回参考和示例源码，无需定位文件。完整示例：`components/fabric/examples/`。
- **何时使用什么**：逐步判断的工作用直接循环；机械的已知形状编排用 `fabric`；需要自有上下文的探索性子任务用 `agent_run`；混合程序可以调用 `agent_run`。

## Expert advisory peer (`expert`)

`expert` 组件是一个非交互式顾问同伴（设计：
[research/EXPERT.md](research/EXPERT.md) —— §2 知识前缀、§4 调度、
§5 判断契约、§6 轮次绑定建议、§8 成本与可观测性）。它并发跟随一个或多个工作
会话——通过 `expert_follow {session_id}` 显式武装
（受审批门控，默认关闭，且按需：用 `discover` +
`invoke` 武装它，或在 shell 中用 `./var/bin/cli call expert_follow
'{"session_id": "conv-…"}'`；在此之前组件是惰性的）——监视
每个被跟随会话的
`ev.session.<id>.*` 事件（toolcall start/done——判断触发器——轮次
start/done、助手文本、token 增量的推理尾部，以及窗口 80% 处的
上下文压力触发）进入一个有界的按会话内存当前轮次帧，该帧在轮次完成时清除，因此任何证据都不会
跨越轮次，并询问一个 LLM 裁判（一个无状态的隐藏 `chat` 调用：固定的
缓存稳定知识前缀——从 `llm.llm_resolve` 调整到裁判窗口的 80% 减去 8 000 token 的观察与裁决预留，
并按跟随缓存——加上一个临时观察，无工具）该
证据是否值得一次 steer。只有高置信度、指明活跃、
非隐藏工具的 steer 才会被送达，且仅当门控成立：steer 携带一个
非空 `tools` 列表和一个在 `MaxMessage` 上限内的非空消息，每个
名称都被规范化（去除反引号，`component.tool` 归约为工具），
必须对该会话可见，必须出现在消息文本中，并且其中至少
一个必须是工作器本轮尚未使用的工具——一个只指明帧中已有工具的
steer 被读作沉默，而非工具
变更。送达通过轮次绑定的
`svc.session.<id>.advise` 请求/回复表面：runner 仅在该确切轮次仍在运行时
接受建议——迟到的建议会被拒绝
（`stale-turn`/`no-active-turn`，加上 `wrong-session`、`empty` 和 `duplicate`
用于与上一条建议完全重复的情况，以及 `advisory-limit` 一旦该轮已有
一条），绝不排队到下一轮。被接受的
建议被并入为一条标记的用户消息（`[Niffler advisor: expert] ...`），
持久化，并在 `ev.session.<id>.advice` 上宣告。裁判通道本身保持
全局：一次判断在途，共享冷却，按会话最新状态合并。每个被解析的判断——包括沉默——都作为
`ev.log.expert` 行发布（action、reason、message），这就是操作员回答
"为什么它沉默了？"的方式。已发布的数字：每轮最多 2 次判断
（`MaxJudgmentsPerTurn`），之间至少间隔 8 秒（`EvalCooldownMs`）；
帧保留 8 条最近工具活动（`MaxActivities`），每个字段裁剪到
400 字符（`MaxField`），保留 2 000 字符的推理尾部（`MaxReasoningTail`）
并将建议消息上限设为 1 200 字符（`MaxMessage`）。裁判调用
本身上限为 1 536 输出 token（`JudgeMaxOutputTokens`），要求
`reasoning_effort: "low"`（`JudgeReasoningEffort`）并在 120 秒后超时
（`ChatTimeoutMs`）——这三者都是编译期常量，因此更改其一意味着
编辑 `components/expert/main.nim` 并重新构建。token 上限是
尽力而为的：网关可能会忽略它。

| Tool | What it does |
|---|---|
| `expert_follow {session_id, model?, provider?}` | 跟随一个会话（多目标：每个被跟随会话保留自己的帧、知识前缀、判断预算和按跟随指标）；重新跟随会重置其帧。`model`/`provider` 为该跟随覆盖判断调用；不带它们时，裁判运行在 `llm` 的默认后端（活跃提供方）上，这使裁判成本不落在工作器的模型上。受审批门控。 |
| `expert_unfollow {session_id?}` | 带 `session_id`：丢弃该跟随。不带：丢弃所有跟随并丢弃其帧。 |
| `expert_reload` | 从实时目录重建每个被跟随会话的知识前缀（新缓存纪元）。 |
| `expert_status {session_id?}` | 带 `session_id`：该跟随的帧、知识版本、按会话计数器（judgments、silences、steers、accepted、rejected、staleDrops、errors）、前缀诊断（`liveTools`、`skills`、`prefixChars`、`prefixBudgetTokens`）和裁判 token 总计（`tokens {prompt, cached, completion}`）。不带：被跟随目标加上生命周期诊断（相同的计数器和 token 总计，生命周期）。 |

该组件没有自己的配置：没有 `NIF_*` 变量会改变它如何
跟随或判断（`NIF_LOG_LEVEL` 只决定其自身的
`ev.log.expert` 行是否可见）。

设计不变量：工作会话从不等待 expert
（尽力而为、冷却、最新状态合并）；没有增长的 expert
转录（每次判断都是无状态的），组件本身没有任何持久内容——
帧、前缀和计数器都存在于进程中，因此重启会丢弃
每个跟随，重新武装是显式的；被接受
steer 的唯一存储产物是被跟随会话中的并入消息记录）；失败关闭
（任何解析/验证/
传输错误都是沉默）；expert 从不行动——它只建议，且
受审批门控的工作仍由工作会话的人类门控负责。

前缀持有组件自己的策略、三个经评审的捆绑技能
（`niffler-tools`、`niffler-fabric`、`niffler-harness`——一个遮蔽捆绑名称的项目或主目录技能
会被拒绝，因此该允许清单就是信任
边界），然后是所观察会话自己的工具视图：其冻结的直接
暴露和工具允许清单（从 `core.prompt_preview` 读取）加上它可以 `discover` 的按需
工具。绝不是全局 LLM 工具集——那会夸大
一个较旧或列入允许清单的会话实际可以调用的内容。

## Recovery

仓库是快照；`var/` 是一次性构建输出——用 `make clean` 删除构建
输出，绝不要裸 `rm -rf var`；而一个拒绝启动的 `store` 意味着另一个进程仍持有锁
（`var/store.db.lock` / `var/barrel-db.lock`），而不是一个陈旧文件：`make down`
或杀死陈旧的 store，内核会释放它。如果 agent
（或一个 bug）破坏了随附组件——覆盖了 `var/bin` 中的二进制、
损坏了已生成组件的记录，或一个自行添加的组件在启动时崩溃——以恢复模式启动 Niffler：

```bash
make recover        # stops anything running, then ./var/bin/niffler --recover
```

`--recover` 按顺序做三件事：

1. **从源码重建随附二进制**（`make build`，回退到
   `nimble all`）——修复被覆盖/损坏的 `var/bin/*`。
2. **清除存储的组件记录**——不留下任何持久化的额外组件
   形状可供恢复。
3. 启动所请求的 profile（通常是完整的交互式 harness；
   `--recover --minimal` 选择最小 profile）。**会话和
   消息保留**——只有组件形状被重置。

对于*源码*的损坏（有人编辑了 `components/`、`core/`、`sdk/`、
`manifest.yaml` 或 `Makefile`）：

```bash
# stop the harness first (close the UI, or Ctrl-C ./var/bin/niffler)
git restore components/ core/ sdk/ manifest.yaml Makefile   # or: git checkout -- .
make build
./var/bin/niffler                       # or just reopen the UI
```

## The store

`store` 和其他组件一样，是总线上的文档存储，提供 `put` / `get` / `list` / `del`，并基于 rev 实现乐观并发（`put` 接受 `expectRev`，不匹配时以 `rev-conflict` 失败）。barrel 引擎还注册了一个隐藏的 `selftest` 工具——一次真正的 put/get/rev/list/`del` 往返，`/doctor` 可以调用它；两个 SQL 引擎只注册那四个工具。
`put`、`get` 和 `list` 是按需工具；`del` 是隐藏的——由核心删除记录，模型不能。`put` 还携带 `x-harness.sessionId`，这正是下面写入围栏得以实现的原因。**绑定会话的调用方只能写入受管理的 kind**（目前是 `fabricprog`）：其他所有 kind 都由 harness 管理，会被以 `forbidden-kind` 拒绝，因此任何活动会话都无法破坏转录或组件记录。直接的总线调用方（cli、测试、核心）保留完整访问权限。
核心及其组件正在使用的 kind（store 工具自身的 docstring 只列出了其中一部分——此表才是完整列表）：

| Kind | Id | Value |
|---|---|---|
| `conversation` | `conv-<ts>` | `{createdAt, model, title}` — 会话头（还携带冻结的系统提示、模型/思考选择、每会话预算控制和 token 计量器） |
| `message` | `<convId>:<seq>`（序列号补零到六位——id 顺序即消息顺序） | `{conversationId, role, content, ...}` |
| `component` | `<name>` | `{name, binary, policy, addedAt}` — 启动时恢复的持久化形态 |
| `plugin` | `<pkg name>` | `{name, repo, ref, dir, version, components, addedAt}` — `plugins` 组件的安装记录 |
| `provider` | 昵称（外加 `active` 标记文档） | `provider` 组件的 LLM 提供商注册表。凭据以**明文**存储——store 文件本身就是秘密——脱敏只发生在工具响应中（`provider_list`；`mcp_servers` 同样会脱敏 `mcp` 记录的 `env`/`headers`）。这覆盖了两类 kind 的秘密，因此任何 `var/store.db` 或 `var/barrel-db` 的副本都是它们的副本 |
| `session` | `<sessionId>:tools` | 会话冻结的直接工具集快照（见 [Progressive tool discovery](#progressive-tool-discovery)） |
| `slash` | `slash` | UI 渲染的合并斜杠命令表（见 [WIRE.md](WIRE.md)） |
| `agentjob` | `<jobId>` | 持久化的后台 `agent_spawn` 作业记录（延续会打上 `continued`、`activation` 和队列 `close` 标记） |
| `agentnotice` | `<parentSession>:<seq>` | 子代理结算通知（摘要 + 指向完整回复的追索；`deliveredAt`/`deliveredVia` 标记投递） |
| `sessionmeta` | `<sessionId>` | 子代理谱系 / 运行器元数据：spawn 时写入 `{parent}`；延续会添加 `activations`（轮次计数，从 1 开始）和 `firstActivationAt`；`close: true` 退役会设置 `closed` |
| `fabricprog` | 程序名 | 模型管理的 fabric 程序库（`fabric {name}` 运行其中一个） |
| `profile` | profile 名 | `profile` 核心工具的具名工具配置选择器列表；在会话第一轮时解析一次，写入该会话的直接工具集 |
| `approval` | `<sessionId>:<key>` | 客户端的“不再询问”授权（以工具为键，程序形态的调用则为 `tool:<digest>`）；核心读取它以跳过审批门 |
| `contextreceipt` | `<convId>:<requestId>` | 溢出恢复尝试的请求级回执，在消耗之前写入，并用结果更新 |
| `compaction_input` | `<convId>:<attemptId>` | 分页的压缩前快照，压缩组件据此校验，运行器据此提交（页为 `<id>:p<idx>`）。瞬态：尝试一结算就删除，因崩溃或超时尝试而孤立的页会在 600 秒后清扫——任何东西都不得将其视为持久（只有 `context_projection` 是持久的） |
| `context_projection` | `<convId>` | 每个会话一个文档——已提交的上下文投影（`version`、`generation`、`canonicalHigh`、`renderer`、规范化后的 `checkpoint`、持久的 `covered` 规范范围、`retained` id、`prunes`、`measurements`、`provenance`），运行器在压缩后复用它。基于上一代以 `expectRev` 写入一次；它是重启后重建提供商视图的真相来源，当通知指名 `checkpoint` 引用时，召回解析器会读取其 `checkpoint`/`generation` |
| `spill` | `<convId>:<n>` | 从上下文窗口中提升出来的超大工具结果，可用 `context_recall {"ref": {"source": "spill", "id": "…"}}` 寻址。提升在追加时尽力而为（失败则保留临时文件指针且不添加引用）；缺失、为空或格式错误的 spill 文档会被大声拒绝，而不是作为空成功来回答，并且修剪门在修剪前会重新校验该文档，因此损坏的 spill 绝不会导致最后一份副本丢失 |
| `mcp` | 服务器名 | `mcp` 组件的 MCP 服务器配置记录（见 [External MCP servers](#external-mcp-servers-mcp)） |
| `selftest` | store 自检探针 | 一次性——由 store 自身的自检往返写入并删除 |

后端是所选引擎——默认是位于 `var/store.db` 的 SQLite，设置 `NIF_STORE_BACKEND=barrel` 时是位于 `var/barrel-db` 的 BitBarrel，或 DSN 共享的 TiDB 引擎（`NIF_STORE_TIDB_DSN`，无 flock——行锁和 rev 计数器在 harness 之间仲裁）。**恰好一个进程拥有该文件**——绝不要对同一个数据库运行两个基于文件的 `store` 进程（对同一 root 启动的第二个核心正是如此；实验时请使用临时的 `NIF_ROOT` 副本）。

`list` 是一页，而不是完整视图（见 [Store engines](#store-engines)）：核心中所有必须看到整个 kind 的地方都走 `storeListAll`——单次有上限的 `list` 在恢复时会静默截断长转录。

## Testing

```bash
make test           # the full gate: the bus-contract suite (the desktop UI's
                    # frontend tests + typecheck live in gokr/niffler-ui)
make test-server    # ... server side only: one test-owned NATS per test, no node
make test-bash      # ... or just one — `make help` lists every target
                 # (test-uireg, test-autostart, test-<component>); the full
                 # bus suite is `make test-server`
```

`make test-server` 通过 `scripts/run-tests.sh` 在有界池中运行约 60 个测试二进制（默认每个核心一个测试）：测试拥有私有的 NATS 服务器和临时 root，因此可以安全地重叠运行。每个测试的输出被捕获到 `var/test-logs/<name>.log`，完成时打印其墙钟时间，摘要会列出最慢的——可用 `TEST_JOBS=N`（或直接对脚本用 `NIF_TEST_JOBS=N`）覆盖；`TEST_JOBS=1` 是旧的顺序运行，无论哪种方式日志都按测试分开。`NIF_TEST_VERBOSE=1` 会在每个测试的行之后交错输出其捕获的输出。

每个测试都会启动真实的组件二进制（Nim、Go *和* TypeScript——信封就是产物，因此一个 harness 测试所有 SDK），并在每个测试自己启动的私有 nats-server 上驱动它们（`NIF_NATS_SPAWN` 式隔离）。
桌面 UI 的前端测试不属于此套件：UI 现在是 [gokr/niffler-ui](https://github.com/gokr/niffler-ui) 插件，其 lib 单元测试和类型检查在该仓库中运行（那里的 `make test` / `make typecheck`），因此此门保持自包含。
基于核心的测试会将其所需二进制快照到唯一的临时 `NIF_ROOT`；Barrel、插件克隆、生成的组件、日志和缓存因此都被隔离。各个 `make test-*` 目标可以彼此并发运行，也可以与活动的开发 harness 并发运行——`scripts/run-tests.sh` 正是依赖这一点来池化套件。仓库构建写入（`make build`、`make clean`）由 `scripts/with-build-lock.sh` 串行化；运行时的 `builder.build` 不获取该锁，因此在第二个终端中执行 `make clean` 会在正在运行的构建之下删除 `var/bin` 和 `var/build`。
代理构建的测试组件使用沙箱本地的 Nim 缓存。

若干测试自带夹具，而不是使用真实模型：
`components/ctxtest/` 是一个 stub-LLM 组件（一个隐藏的 `chat`，按会话 id 播放脚本化的一轮），它还提供真实工具无法按需产生的契约夹具——参数名改写、schema 冲突、目录重新发布抖动、供 fabric 批处理宿主使用的 `effect: "read"` 项、标量 `outputSchema`——外加 `ctxecho`，即证明 harness 私有上下文从嵌套调用中被剥离的 `sessionContext` 探针；
`components/ctxtest/sink.nim` 为同一检查注册了第二个组件（`ctxsink`，它报告 `sawSession`）。`tests/mock_llm.nim` 和 `tests/mock_parallel_llm.nim` 是 `llm` 二进制的等价替身。它们都不在 `manifest.yaml` 中，也不由 `make build` 构建：每个测试将它需要的那一个编译进其私有沙箱 `NIF_ROOT` 并在那里启动它。

`/doctor deep` 还会通过总线（`comp.selfTest`）扇出到每个组件自己的自检：例如 `bash` 真的通过其进程组路径执行一条命令，然后在 1 秒预算下证明超时杀死，期望退出码 124。未实现自检的组件会列在 `selftestMissing` 下（并作为一行 `selftest (not implementing)` markdown 行）——这是覆盖信息，绝不是失败的检查。

压缩契约有自己的验证通道：
`make test-compaction` 运行端到端的 propose/commit/restart/reload 夹具，`make test-conformance --bin:<path> --tool:<name>` 将同一 contract-v1 套件指向替代压缩器——这是第三方摘要器的验收测试（两者都走通配符 `t_*` 套件，因此 `make test-server` 也会运行它们）。`make live-smoke` 是可选的实况门：针对真实提供商进行真实摘要，`SYNTHETIC_API_KEY=...`，在套件之外。

网络可选开关：`NIF_TEST_INSTALL=1` 运行真实的 `cli install gokr/niffler-weather` + 工具验证；`NIF_TEST_NETWORK=1` 针对 GitHub 运行 `plugin_search`，针对 skills.sh 运行 `skill_search`，以及 TypeScript 构建器构建（npm registry）。安装流水线本身由 `t_plugins` 通过本地 `file://` git 仓库进行封闭式覆盖。
观察/日志文件测试使用临时输出目录，绝不删除开发者的 `var/logs` 或 `var/captures`。外部网络可选开关即使本地状态隔离，仍可能共享提供商速率限制。

## Starting and stopping

没有启动器脚本——二进制自己拥有生命周期：

- **桌面图标 / `niffler-ui`** —— 最常见的情况。桥接的第一个动作是 SDK 的 `ensureHarness`：探测 `NIF_NATS_URL` → `var/nats-url` → 127.0.0.1:4222，寻找服务**此 root** 的核心（目录携带拥有它的 harness 的 root；外来克隆的核心绝不会被采用）；如果没有应答，则以 `NIF_AUTOSTART=1` 分离启动 `var/bin/niffler`。该二进制本身由 `make install-ui` 安装——桌面 UI 是 [gokr/niffler-ui](https://github.com/gokr/niffler-ui) 插件，由构建器构建到 `var/bin/niffler-ui`，并由 `make install` 链接到 PATH。探测是有耐心的：附加以 200 毫秒重试约 10 秒，启动的核心必须在 20 秒内应答，否则 `ensureHarness` 会以 `spawned core did not answer within 20s — check <root>` 失败（Nim SDK 会先回收它在同一会话中早先启动的核心，如果它已退出）。
- **交互式插件**（例如 `niffler-tui`）——它们**不**调用 `ensureHarness`，也绝不启动 harness：它们探测活动总线（`NIF_NATS_URL` → `$NIF_ROOT/var/nats-url` → `./var/nats-url` → 127.0.0.1:4222），连接并注册 `client: true`（这样自动启动的核心在它们运行期间保持存活）。与 `ensureHarness` 不同，它们**不**检查应答的核心服务哪个 root，因此 TUI 可以加入桌面 UI 会拒绝的外来 harness 的总线。这条链是按客户端而定的：Nim 客户端（`cli`、`console`）探测 `NIF_NATS_URL` → `<NIF_ROOT 或它们自己的克隆>/var/nats-url` → 127.0.0.1:4222，绝不探测 cwd，而 bash `dialog` 使用 `NIF_NATS_URL` → `./var/nats-url`（仅 cwd）→ 127.0.0.1:4222。先启动 harness——桌面 UI 或 `./var/bin/niffler`。
- **终端管理 shell** —— 直接运行 `./var/bin/niffler`，或用 `./var/bin/niffler --minimal` 启动三组件引导配置。手动启动的核心绝不自行终止；用 Ctrl-C / SIGTERM 停止它。环境中的 `NIF_AUTOSTART=1` 会覆盖 shell——该核心即使在 tty 上也处于服务模式——并且当它停在提示符处时仍继续服务 `svc.core.call`，因此 UI 可以附加到 tty 启动的核心。

交互式前端注册 `"client": true`（SDK 的 `interactive()` / `Component.Client` 标记）。按此定义，`console` 和 `dialog` 不是交互式前端：两者都不注册 `client: true`，因此自动启动的核心可能在它们之下退出（当新 harness 出现时 `console` 会自行重连）。该标记是注册，不是租约：一个未调用 `reg.depart` 就被杀死的客户端会让自动启动的核心保持存活——并让核心相信有人类可联系以进行审批——直到目录将其移除（`ui` 注册表的 20 秒租约是另一个时钟，见 [Clients and the UI registry](#clients-and-the-ui-registry)）。**自动启动的**核心会统计它们：当最后一个离开时，它会在 `NIF_AUTOSTART_IDLE_S`（默认 10 秒——重启的 UI 会在该窗口内重新注册）后关闭，带走其组件和启动的总线；如果从未有客户端到来，它会在 `NIF_AUTOSTART_BOOT_S`（默认 60 秒）后放弃。关闭附加到*手动*启动核心的 UI 不会改变任何东西——核心保持存活。
`NIF_ENSURE_ATTACH=0` 使 `ensureHarness` 无条件启动（测试用）。
显式的 `NIF_NATS_URL` 则以相反方式短路：客户端恰好附加到该总线，不探测也不启动任何东西。（`NIF_NATS_SPAWN=1` 是核心侧的双胞胎——一个隔离的、核心拥有的随机端口总线，绝不使用 4222；见 [Environment variables](#environment-variables)。）

在内核层面，同样的规则成立，只有一个刻意的例外：核心自身没有父进程死亡信号——自动启动的核心必须比启动它的 UI 活得更久——而它启动的每个子进程都有。受监督的子进程（组件、会话运行器）在 util-linux 的 `setpriv` 位于 `PATH` 时被包裹在 `setpriv --pdeathsig TERM` 中，SDK 在它们启动的组件中设置 `PR_SET_PDEATHSIG`，捆绑的 `nats-server` 在其自己的 `main` 中设置它，因此即使 SIGKILL 也没有东西能在其 harness 之后存活。在 Linux 之外（或没有 `setpriv` 时）两种机制都缺失，这就是孤立总线产生的方式（见 Troubleshooting）。

## Common tasks

```bash
./var/bin/niffler             # full harness in a terminal (admin shell)
./var/bin/niffler --minimal   # store + bash + llm only at boot
niffler-ui                    # desktop UI; autostarts the full profile
make build          # rebuild what changed
make install        # PATH entries (niffler, niffler-cli, niffler-console,
                    # + niffler-ui when its plugin binary exists and the
                    # niffler-tui wrapper on request — never component
                    # binaries such as the `grep` tool (`var/bin/grep`, which
                    # shells out to `rg`), so PATH cannot shadow grep/git/...)
make install-tui    # same, installing the niffler-tui terminal client quietly
                    # (= make install WITH_TUI=1)
make uninstall      # remove those PATH entries again
make install-ui     # install the desktop UI plugin (gokr/niffler-ui): an
                    # isolated auto-approved harness boots, the plugin manager
                    # clones + the builder builds it into var/bin/niffler-ui
make install-lsp    # install the lsp component's default language servers
make test           # the full gate: the bus-contract suite (the UI repo's
                    # frontend tests live in gokr/niffler-ui)
make test-server    # the bus-contract suite alone (each test owns a private bus)
make doctor         # check prerequisites
make ram            # RAM of running stacks (harness + components + nats + clients)
make down-here      # stop this checkout's harness, components and spawned bus
                    # only — bench worktrees and other clones survive
make clean          # remove all build artifacts (var/, nimcache/)
```

- **无头服务模式**（无 tty，用于 UI/自动化）：
  `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null` ——
  服务 `svc.core.call`；除非有 UI 附加或设置 `NIF_AUTO_APPROVE=1`，否则需要审批的工具会被拒绝。
- **附加到任意总线**：`NIF_NATS_URL=nats://host:4222`（甚至远程），或在核心之前自己在默认端口启动 nats-server——只有当应答的核心服务**此 root** 时，核心才会复用 `127.0.0.1:4222` 上的总线；外来 harness，或没有核心在其上的裸 nats-server，会使核心发出警告并改为启动隔离总线（命名为此 root 自己总线之一的遗留 `var/nats-pid` 会先被回收）。要刻意强制使用某条总线，请设置 `NIF_NATS_URL`。
- **不使用 LLM 探测总线**：`tests/` 中的一次性 `nim c -r` 脚本（见 AGENTS.md 的 "Debugging the bus"）。
- **Wails**：桌面 UI（以及任何 Wails 客户端包）通过其包配方构建，该配方必须运行 `wails build -tags webkit2_41`（Linux）——普通的 `go build` 会产生一个桩。UI 的 SPA 开发服务器位于 gokr/niffler-ui 检出中（那里的 `make dev`）。
- **监控运行系统的 RAM**，用 `make ram`（或 `watch -n5 scripts/niffler-ram.sh`）：按栈统计总量——你的克隆、`nifflerprod` 以及每个 bench 私有 harness 分别统计——涵盖 harness + NATS + 所有启动的组件 + 会话运行器 + 客户端。成员资格按可执行文件路径（`*/var/bin/*`、`niffler-ui`）判定，而非进程树：tui 是自动启动 harness 的*父进程*，而 bench 运行的私有总线属于 bench 驱动程序，因此 PPID 遍历会漏掉两者。读 PSS，而非 RSS：共享同一 `var/bin` 构建的栈会在 RSS 中重复计算文件支持的页。`bash` 工具的工作负载子进程（编译器、测试二进制）按设计被排除。

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| UI 在桌面应用内显示 "Running in a browser" | `nats.ts` 绑定不匹配——`window.go.main.Bridge` 必须与 Go 结构体名匹配（ui/README.md） |
| UI 横幅：总线不可达 | 核心自动启动仍在进行或已失败——在终端中启动 `./var/bin/niffler` 以查看引导错误 |
| 引导时 `core: WARNING missing binary for <name>` | 运行 `make build` |
| llm 错误 HTTP 401/403 | 先检查活动提供商的密钥或令牌（`provider_status` 查看生效内容的脱敏视图，`provider_list` 查看 `expiresAt`）；只有在没有存储的提供商处于活动状态时，`.env` 或 shell 环境中的 `NIF_OPENAI_API_KEY` 才起作用 |
| 无头模式中 "approval denied" | 预期行为：没有人类可联系。附加 UI，使用 `make run`，或在知情的情况下设置 `NIF_AUTO_APPROVE=1` |
| 两个 store 争抢同一数据文件（`var/store.db` 或 `var/barrel-db`） | 单写入者规则——每个 root 只有一个核心；在临时 `NIF_ROOT` 副本中实验 |
| 引导拒绝："this harness has conversation history in var/barrel-db" | 默认引擎已改为 SQLite，而你的历史仍在 barrel 中——运行 `niffler-store-migrate --root <path>`（错误会打印它），或设置 `NIF_STORE_BACKEND=barrel` 以保留旧引擎 |
| 孤立的 `nats-server` | 手动启动的 `nats-server`、非 Linux 主机（没有 PDEATHSIG 来回收它），或 SIGKILL 留下的陈旧 `var/nats-pid`——检查 pid 文件（核心会校验 pid + comm，因此陈旧文件会被忽略），然后 `pkill -f nats-server` |
| 组件在引导时崩溃，在退避循环中重启 | 通过 UI/终端 `core.remove` 它，或 `make recover` |
| 代理修改了源代码 | `git restore components/ core/ sdk/ manifest.yaml Makefile` 然后 `make build`（见 Recovery） |
| 一轮被取消但编译仍在运行 | `build` 不声明 `x-harness.sessionId`，且 `builder` 不订阅 `cancel.build`，因此取消被丢弃：编译器运行到自己的截止时间，只有回复被放弃。取消前等待工具结果，或 `core.kill {name: "builder"}` |
| 会话调用失败："session runner binary missing" | `var/bin/session` 从未构建——`make build` |
| `spawn` 失败："spawn failed — tool '<t>' already provided by <owner>" | 注册被拒绝——几乎总是因为工具名已存在（名称全局唯一；给你的工具加上组件名前缀）。修正名称，重新构建并再次 `spawn`：失败的尝试已被回滚（副本已停止，未持久化任何东西），因此该名称立即可用。在核心的 stdout 上，同样的拒绝显示为 `catalog: rejecting <name> — …` |
| `spawn` 失败："did not register within <n> ms" | 组件未及时宣告自己——启动缓慢，或二进制在途中死亡（核心会将 `var/logs/<name>.log` 的有界尾部追加到错误中）。修正原因并再次 `spawn`（尝试已被回滚），或为确实缓慢的组件提高 `NIF_SPAWN_WAIT_MS` |
