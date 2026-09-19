# Niffler 手册

操作、配置和恢复 Niffler harness 所需的一切，另加内置组件的参考章节。设计理由见
[research/REBOOT.md](research/REBOOT.md)；wire 协议见
[WIRE.md](WIRE.md)；core/组件边界见
[ARCHITECTURE.md](ARCHITECTURE.md)；未完成工作汇总于
[research/PLAN.md](research/PLAN.md)。

> 🤖 AI 自动翻译，可能滞后于英文版；以 [English](MANUAL.md) 为准。
> 章节标题保留英文，以便跨文档链接保持稳定。

[English](MANUAL.md) · 简体中文 · [繁體中文](MANUAL.zh-TW.md)

## Contents

- [Layout of a running system](#layout-of-a-running-system)
- [Store engines](#store-engines)
- [State and configuration](#state-and-configuration) · [Environment variables](#environment-variables) · [The `.env` file](#the-env-file)
- [The bus in one screen](#the-bus-in-one-screen) · [Approvals](#approvals)
- [Context window](#context-window) · [Self-extension and component lifecycle](#self-extension-and-component-lifecycle)
- [Component ecosystem (`plugins`)](#component-ecosystem-plugins) · [Skills](#skills)
- [Provider registry (`provider`)](#provider-registry-provider) · [Fetch](#fetch)
- [External MCP servers (`mcp`)](#external-mcp-servers-mcp)
- [Language servers (`lsp`)](#language-servers-lsp) · [Background processes (`processes`)](#background-processes-processes)
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

| 路径 | 是什么 |
|---|---|
| `core/` | 控制平面：system harness（`niffler.nim`：总线引导、supervisor、catalog、dispatch）+ session runner（`session.nim`：每个会话一个进程，会话循环） |
| `components/` | 内置组件源码：`bash`、`builder`、`store`、`plugins`、`skills`、`fetch`、`edit`、`grep`、`git`、`agent`、`fabric`、`expert`、`observe`、`logfile`、`hooks`、`dialog`、`systemprompt`、`cli`、`console`（Nim），`models`、`provider` 和 `llm`（Go），以及 `llm-openai` 替换示例 |
| `sdk/` | Nim SDK（`sdk/niffler`）+ `sdk/go`（Go）+ `sdk/ts`（TypeScript/Node.js，npm 包 `niffler-sdk`）；`sdk/envelope.nim` 中的信封才是核心产物 |
| `docs/` | 本手册、wire 规范（`WIRE.md`）、设置设计（`research/SETTINGS.md`）、core 边界理由（`ARCHITECTURE.md`）、fabric 用户指南（`FABRIC_GUIDE.md`）、未完成工作（`research/PLAN.md`）以及 `research/`（设计历史） |
| `manifest.yaml` | 引导清单：core 启动哪些组件、重启策略、可选的组件副本数 `replicas`；`--minimal` 把它过滤为 `store`、`bash` 和 `llm` |
| `var/` | **运行状态，gitignored，可丢弃**——仓库本身才是快照 |
| `var/bin/` | 构建出的二进制（系统 core + session runner + 组件）。由 `make build` 重新构建 |
| `var/store.db` | SQLite store 的数据文件（默认引擎）——**单写者**：同一时刻只有一个 `store` 进程可打开它。较老的 harness/迁移前根目录使用 `var/barrel-db` |
| `var/nats-url` | 最近一次启动的总线地址；UI bridge 据此找到 core |
| `var/nats-monitor-url` | core 自行启动总线时的 HTTP 监控端点；复用/远程总线没有该文件 |
| `var/logs/`、`var/captures/` | 轮转的结构化日志和显式 observe 探测导出（见 [Observation and logs](#observation-and-logs)） |
| `var/nats-pid` | core 启动的总线进程 pid（仅用于崩溃清理——存活的 core 退出时会自行停止总线） |
| `var/build/` | agent 构建组件的源文件（builder 的暂存目录） |
| `nimcache/`、`ui/build/`、`ui/frontend/node_modules/`、`ui/frontend/dist/` | 构建产物；`make clean` 会删除它们 |

### Shipped components

| 组件 | 语言 | Manifest | 做什么 |
|---|---|---|---|
| `store` | Nim/Go | required | 总线上的文档存储（`put/get/list/del`，基于 rev 的并发控制）。各引擎以同一名称注册并提供相同工具：`store-sqlite`（Go，SQLite + goose 迁移，`var/store.db`）是**默认**；`barrel`（`var/bin/store`）和 `tidb` 仍可通过 `NIF_STORE_BACKEND` 选用——见 [Store engines](#store-engines) |
| `bash` | Nim | required | 经典工具：带超时和输出上限的 shell 命令。命令作为自身进程组的组长运行，因此超时或回合被取消会杀掉整棵进程树（退出码 124 / 130）——不会留下孤儿进程。结果携带 `text`（以 `(exit N)` 状态行开头——非零即失败；124 = 超时，130 = 已取消——其后是合并的 stdout/stderr；LLM 记录看到的就是它）以及机器字段 `exit_code`、`cancelled`，输出过大时还有 `spill {path, bytes, lines}`（溢出到临时文件，可用 `read` 分页读取）。`run_in_background: true` 把长跑命令（服务器、监视器）交给 `processes` 组件而不是阻塞——见 [Background processes](#background-processes-processes) |
| `repomap` | Nim | optional | 排序后的工作区地图（docs/research/REPOMAP.md）：约 1KB 内给出承重文件及其关键定义，由 tree-sitter + 原生 Nim tags 图与个性化 PageRank 构建（aider repomap 的移植）。`repo_map {workspace?, focus?, mentionedIdents?, budget?}` 是 onDemand 且为读效应——模型主动询问，不注入任何东西。工作区打开时的自动追加（在 `ev.workspace.opened` 时追加一条 append-only 条目；组件发布，runner 追加）**默认关闭**：设置 `NIF_REPOMAP_AUTOAPPEND=1` 选择开启。默认关闭是因为 A/B 没有过线（full30：约多 40% token、准确率无提升；Multi10 high 开启后 8/10 vs 9/10，尽管 low 复跑结论反转、最初的高档测试部分测的是桩地图——见 `bench/reports/repomap-ab-*.md`），而且 onDemand 工具不会自己激活。选择开启后，追加还有**门控**（`docs/research/REPOMAP-GATES.md`）：低于普查下限的工作区从不构建，桩地图（字节/符号/文件阈值）从不注入——被扣留的地图记录为 `repo map withheld`。关闭追加时，它只是一个模型想要定位时可以发现的可选组件。缓存：`var/repomap-tags/`（按 mtime 键控）。可选组件——缺失就没有地图，其他一切不变 |
| `processes` | Nim | optional | 带归属者的长跑命令：`process_start`（脱离父进程、独立进程组，立即返回 id）、`process_poll`（增量排空输出）、`process_kill`（停止整个进程组）、`process_list`——见 [Background processes](#background-processes-processes) |
| `builder` | Nim | required | 把 agent 编写的 Nim/Go 源码编译为二进制 |
| `llm` | Go | required | 流式 chat 适配器（隐藏的 `chat` 工具；`ev.llm.token` 增量；取消）——协议：OpenAI 兼容 Chat Completions、OpenAI Codex（ChatGPT OAuth）Responses 和 Anthropic Messages；`components/llm-openai` 中的 `llm-openai` 是最小非流式示例，可通过 `manifest.yaml` 换上 |
| `models` | Go | optional | models.dev 提供商/模型目录、原子缓存、严格解析，以及插件修正/发现层（见 [Model catalog](#model-catalog-models)） |
| `provider` | Go | optional | store 持久化的 LLM 提供商注册表：`provider_add`/`list`/`switch`/`active`/`remove`/`export`/`import`，订阅 OAuth 登录（`provider_oauth_start`/`complete`/`cancel`），`ev.provider.switch` 通知 |
| `plugins` | Nim | optional | 生态门户：topic 搜索 + 包的安装/更新/移除 |
| `skills` | Nim | optional | Agent Skills（SKILL.md）：发现、加载、资源访问、基于 git 的安装/移除 |
| `fetch` | Nim | optional | 网页内容获取：http/https、HTML→文本提取、大小上限与文件溢出 |
| `edit` | Nim | optional | 文件工具：`read`（规范的 `reads` 数组——一次调用最多 12 个文件/区间，可分页，单文件 `path` 语法糖；对超过 1000 行且其类型有语言服务器的文件做整体读取时，改为返回 lsp 符号大纲——可用 offset/limit 取窗口，或 `offset: 1` 强制整体读取，`NIF_READ_OUTLINE_LINES` 调整/禁用）、`edit`（唯一 `old_string`、带保护的级联回退、`replace_all`）、`write`（原子整文件写）、`undo_last_edit`（变更需审批）；锚定块移动在 [niffler-hashline](https://github.com/gokr/niffler-hashline) 插件中 |
| `lsp` | Nim | optional | 语言服务器接缝：一个 `lsp` 工具——`diagnostics`（不用跑测试就能拿到编译/lint 错误）、`documentSymbol`（文件大纲：每个符号及其种类、名称和从 1 开始的位置）、`workspaceSymbol`（基于服务器索引的全仓符号搜索——模糊 `query`，跨文件结果）、`goToDefinition`、`findReferences`、`goToImplementation`、`hover`——面向任何已配置的 stdio 语言服务器（默认为 gopls、nimtortoise、typescript-language-server、pyright、rust-analyzer、clangd、bash-language-server、jdtls、intelephense、solargraph、csharp-ls）。注册表是数据（`$XDG_CONFIG_HOME/niffler-lsp/servers.json`）：添加语言是一条配置或 agent 自己能执行的 `lsp_registry add`——绝不写代码（AGENTS.md：语言无关的 core）。On-demand 工具 |
| `git` | Nim | optional | 只读仓库检查：固定 argv 的 `git_status`/`git_diff`/`git_log`/`git_show`/`git_blame`（无需审批；变更仍走 bash），外加 `review_receipt`——`var/review-receipts/` 下用于推送前评审交接的本地 diff 指纹写入/校验对（从不调用模型；diff 自收据后有变化即校验失败）。On-demand 工具——worker 通过 `discover` + `invoke` 触达它们，保持直接工具集精简 |
| `agent` | Nim | optional | 子代理会话：`agent_run`/`agent_spawn`（新建或继续的子代理、后台作业、持久化结算通知——见 [Fabric and subagents](#fabric-and-subagents)） |
| `expert` | Nim | optional | 顾问同伴：并发跟随一个或多个会话、由 LLM 评判、回合绑定的 steer（见 [Expert advisory peer](#expert-advisory-peer-expert)） |
| `fabric` | Nim | optional | 可编程工具调用：模型编写一个编排工具的 Nim 程序；只有它的 `finish()` 值进入会话（见 [Fabric and subagents](#fabric-and-subagents)） |
| `grep` | Nim | optional（4 个副本） | ripgrep 驱动的搜索：`grep`（内容，path:line:match，直接、输出有上限）和 `files`（排序列表，按需）；感知 .gitignore，无需 shell 引号；无状态的队列组副本可并发处理同组件搜索 |
| `systemprompt` | Nim | optional | 会话宪法：session runner 每个会话从 `svc.systemprompt.call` 获取一次系统提示词（见 [System prompt (`systemprompt`)](#system-prompt-systemprompt)） |
| `compaction` | Nim | optional | 默认可替换 `compaction_propose` 实现：校验 runner 拥有的分页快照、选择允许的切点并返回结构化检查点候选；只有 runner 才验证并提交投影 |
| `recall` | Nim | optional | 隐藏的 `context_recall` 解析器：解析规范消息、完整溢出文档和当前持久化检查点 |
| `cli` | Nim | — | 面向脚本/CI 的按需总线驱动器（`catalog`/`wait`/`call`/`install`） |
| `console` | Nim | — | 按需总线查看器（在 stdout 渲染每个信封） |
| `observe` | Nim | optional | 有界实时总线环形缓冲、listen/trace 探测、安全捕获导出和 NATS 监控（见 [Observation and logs](#observation-and-logs)） |
| `logfile` | Nim | optional | 轮转 JSONL 落盘和有界的持久化日志搜索（见 [Observation and logs](#observation-and-logs)） |
| `hooks` | Nim | off by default | 选定的总线事件触发时运行操作者的 shell 命令（仅观察；stdin 收 JSON，环境变量配置；见 [Hooks](#hooks)） |
| `mcp` | Go | optional | 外部 MCP 服务器（Model Context Protocol）：store 持久化注册表（`mcp_servers`/`mcp_add`/`mcp_edit`/`mcp_remove`/`mcp_refresh`），每个服务器一个受监督 bridge；其工具成为普通目录工具，可经 `discover` + `invoke` 触达（见 [External MCP servers](#external-mcp-servers-mcp)） |
| `dialog` | bash | — | 完全用 bash 写的演示组件——nats CLI + jq，无 SDK、无编译步骤：`dialog_show` 弹出桌面对话框（zenity、notify-send 或日志回退），`dialog_ask` 向用户提出 yes/no 问题并返回答案。随 `var/bin/dialog` 一并构建（`make build`）但**不自动启动**；用 `spawn {name: "dialog", binary: ".../var/bin/dialog"}`（core 的工具）启动它。前置条件：natscli、jq、zenity——`make setup` 三者都会装 |

### Minimal boot profile (`--minimal`)

正常 manifest 是完整、可自我扩展的 harness。要得到最小但可用的常驻运行时，启动：

```bash
./var/bin/niffler --minimal
```

它把 manifest 的引导集合过滤为恰好三个服务组件：

- `store` —— 会话/消息持久化和组件记录
- `bash` —— 一个通用机器工具
- `llm` —— OpenAI 兼容的模型访问和流式输出

core 和 NATS 照常运行，首个会话会启动它正常的临时
`var/bin/session <id>` runner。`builder`、`plugins`、`skills`、`fetch`、
`models`、`provider`、专用文件工具以及观察/日志组件都不会启动。通过
`core.spawn` 创建的持久化组件被有意不恢复，但其实 store 记录不会删除；之后
正常启动会把它们恢复。minimal 只是引导配置，不是策略边界——调用方在运行期间
仍可使用 `core.spawn`。

由于既没有 `provider` 也没有 `models`，正常会话回合直接从
`NIF_OPENAI_API_KEY`、`NIF_OPENAI_BASE_URL` 和 `NIF_OPENAI_MODEL` 解析后端。
当精确上下文窗口很重要时设置 `NIF_OPENAI_CONTEXT`；否则 `llm` 使用它内置的
小型模型表，最后回退到 128K。

```bash
NIF_OPENAI_API_KEY=sk-... \
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1 \
NIF_OPENAI_MODEL=deepseek-chat \
NIF_OPENAI_CONTEXT=1000000 \
./var/bin/niffler --minimal
```

桌面 UI 的自动启动使用正常配置。要在 minimal 配置下使用 UI，先启动上面的命令，
再启动 `niffler-ui`；它会附着到已运行的 core。`--minimal --recover` 也有效：
recover 会先重建并清空 spawned 组件记录，然后引导三组件配置。这只是运行时的
选择；`make build` 仍会构建完整的出厂组件集。

### Session runners

一个会话 = 一个进程（`var/bin/session <sessionId>`），由 system harness 按需
启动。客户端始终调用 `svc.core.call`（工具 `session`）；system 为每个会话 id
确保一个 runner，并把回合转发到 `svc.session.<sessionId>.call`。runner 是受监督
的子进程（重启策略 `never`）；它以组件名 `session-<id>`（零工具）注册，启动时
从 `catalog {op: snapshot}` 播种自己的目录，并发出与经典 core 内循环相同的
`ev.session.<id>.*` 事件。会话是临时的：历史存在 store 中，因此新的 runner 会在下次
调用时恢复会话。杀掉 runner 只影响该会话——进程就是隔离单元。两个方向上回合
都不会嵌套。

stdin/stdout tty（`make run`）是**管理 shell**，不是会话 UI：它只检查 harness
自身——`help`、`status`、`catalog`、`tools`、`sessions`、`exit`——带方向键历史
和 Tab 补全（见 `core/tty.nim`）。LLM 对话在 `niffler-tui` 终端客户端和 Web UI
中；脚本化通过 `cli` 组件。

### Store engines

store 的**总线契约才是产物**：`put/get/list/del`、`expectRev` 乐观并发、
按 id 排序的列表（docs/WIRE.md）。多个引擎实现它并以组件 `store` 注册相同的
工具——消费者永远不知道当前是哪个引擎。选择是引导期的决定：
`NIF_STORE_BACKEND=sqlite|barrel|tidb`（默认 `sqlite`）；core 据此解析 manifest
条目的二进制，遇到未知值会拒绝启动。

- **sqlite**（默认，`var/bin/store-sqlite`，Go）：同一文档契约落在 SQLite 上。
  文档以 JSON TEXT 原样保存；`put` 是一条原子语句（文档与 rev 一起移动——
  KV 引擎的两键崩溃窗口消失了）；schema 由内嵌 goose 迁移管理；纯 Go 驱动
  （`modernc.org/sqlite`，无 cgo）。数据文件 `var/store.db`（WAL），可用任意
  SQLite 工具内省（`sqlite3 var/store.db 'select kind, count(*) from docs group
  by kind'`），也可只读挂载到 DuckDB 做离线分析。自上下文压缩落地后成为默认：
  上下文投影需要原子写和可范围读取的列表（docs/research/COMPACTION.md §2）。
- **barrel**（`var/bin/store`）：嵌入的 BitBarrel KV（Bitcask 风格），位于
  `var/barrel-db`——按设计无 schema、零依赖、久经考验。仍完全支持
  （`NIF_STORE_BACKEND=barrel`）；它的 `put` 是两个键的两步序列（先文档、后
  rev），因此两者之间崩溃可能更新内容而没有更新修订号。
- **tidb**（`var/bin/store-tidb`，Go）：同一 schema 走 MySQL 协议
  （go-sql-driver）——网络共享 store，任意多个 harness 可以共用。
  `NIF_STORE_TIDB_DSN` 指向集群（`root@tcp(host:4000)/niffler`；单节点 docker：
  `docker run -p 4000:4000 pingcap/tidb`）。`value` 保持 MEDIUMTEXT，而不用原生
  JSON 类型——二进制 JSON 会规范化键顺序和数字精度，破坏逐字文档契约；索引
  查询以后以 TEXT 上的生成列形式到来（一个 goose 迁移）。`kind`/`id` 是
  utf8mb4_bin：字节精确相等、字节序列表排序和大小写敏感的 LIKE 前缀（与其他
  引擎的契约一致）。没有 flock——集群按设计就是共享状态；行锁
  （`SELECT … FOR UPDATE`、悲观事务）仲裁写者，rev 计数器仍是乐观并发的检查。
  也能跑在普通 MySQL 8 上。

所有引擎都以相同方式强制单写者：一个进程拥有该文件（flock；崩溃时由内核释放），
其他人都通过信封通信。

`list` 是**一页**，不是完整视图：上限 1000 条，并返回 `hasMore` 加一个
`nextAfter` id 游标。把它作为 `after` 传回即可继续走完剩余部分——store 保留完整
历史，所以长会话一次调用装不下。core 自己的全量读取（resume、`session_info`、
`conversation_delete`）会自动分页。

### Migrating between engines

**切换引擎不会搬移数据。** 升级后，历史仍在 `var/barrel-db` 的 harness 会拒绝
启动，而不是打开一个空的 `var/store.db`、看起来像丢掉了所有会话：

```
core: this harness has conversation history in var/barrel-db, but the
      default store engine is now SQLite and no var/store.db exists yet.
core: migrate first (nothing is moved automatically):
core:     niffler-store-migrate --root /path/to/harness
core: scan for other un-migrated roots (benchmarks, clones):
core:     niffler-store-migrate --scan
core: or keep using the old engine: NIF_STORE_BACKEND=barrel
```

`niffler-store-migrate`（位于 `var/bin`）**离线**运行——它启动私有的 NATS 服务器
和 store 进程，因此无需引导任何 harness，也绝不修改源数据。它通过总线契约从源
引擎读取每个文档（所以任意引擎对都可行，包括 TiDB），逐条重放到全新的目标，
最后按 kind 核验计数：

```bash
niffler-store-migrate --root ~/git/myharness      # migrate that root
niffler-store-migrate --root ~/git/myharness --dry-run
niffler-store-migrate --scan ~/git                # list un-migrated roots
niffler-store-migrate --all ~/git                 # migrate all of them
```

`--scan` 会找到顶层目录、同级 clone 和基准测试树
（`var/bench/**/niffler-root`）。迁移拒绝覆盖已存在的目标数据库；回滚只需
`NIF_STORE_BACKEND=barrel`，因为 barrel 文件未被改动。同一条导出/重放路径可以在
两个方向上搬移数据（docs/research/STORE_V2.md "Moving data between engines"）。

## State and configuration

Niffler 没有单一配置文件。状态分布在五处，按生命周期选择：引导决策用环境变量，
身份/选择在 store，每会话的选择在会话头，显示偏好在浏览器，派生的一切在
`var/`（可再生——删掉它，`make build` 加一次启动即可重建整个世界）。

| 位置 | 内容 | 生命周期 |
|---|---|---|
| **环境变量 / `.env`** | 所有 `NIF_*` 变量（下表）：引导与总线、LLM 连接、各组件调优。`.env`（根目录，gitignored）保存密钥和本地覆盖；shell 环境优先；`.env.example` 是带默认值的参考副本 | 进程生命周期——组件启动时读一次环境；改配置要 `core.kill` + `core.spawn` |
| **store**（kind 表见 [The store](#the-store)） | 会话头、消息、`provider` 注册表（含凭据）、冻结的每会话工具集、slash 表、插件/组件安装记录、子代理作业/血缘记录、fabric 程序、MCP 服务器配置 | 持久——harness 的数据库 |
| **会话头**（`conversation` kind） | 每会话选择：model、modelOverride、thinking、profile、title、预算/token 计量——通过 `session` 调用设置（UI 中的 `/model`、`/effort`），并在回合结果中回显 | 每会话 |
| **Home / 项目文件** | skills 树（项目 `.agents|.claude|.opencode/skills` > 内置 `skills/` > home `~/.niffler/skills` + agent 标准目录 > `~/.config/opencode/skills`）；LSP 注册表 `~/.config/niffler-lsp/servers.json`（`NIF_LSP_REGISTRY`） | 持久，用户可编辑 |
| **`var/`**（gitignored） | `bin/` 构建产物、`logs/` 总线 JSONL 和子进程日志、`models/` 目录缓存、`nats-url`/`nats-pid` 总线认领、`processes/` 输出池、`repomap-tags/` 地图缓存、`fetch/`、`captures/`、`store.db`（store 引擎的文件——有且只有一个所有者） | 运行时，可再生 |
| **浏览器 localStorage** | 仅显示偏好：推理/工具卡片的详细级别、语言（`niffler-think`、`niffler-tools`） | 每浏览器 |
| **仓库文件** | `manifest.yaml`（出厂组件注册表）、`skills/`（内置技能）、构建文件（`config.nims`、`*.nimble`、`Makefile`） | 版本化 |

值得记住的优先级规则：shell 环境胜过 `.env`；active `provider` 胜过
`NIF_OPENAI_*`；会话冻结的工具集快照胜过实时 catalog（这正是 resume 字节稳定的
原因）；项目 skills 遮蔽 home skills，home skills 遮蔽内置 skills。repomap、lsp
和 skills 组件还会把 `config.nims`、`tsconfig.json`、`package.json` 和 `go.mod`
当作仓库*标记*（从哪里开始遍历），而不是要解析的配置。

这张表的环境变量部分，正是将来迁入 store 作为全局设置并配上 `/settings` 命令的
候选——设计（优先级 `会话头 > store 设置 > env > 代码默认`、第一阶段迁移哪些键、
哪些永远留在 env）见 `research/SETTINGS.md`。

## Environment variables

所有组件都会加载 `.env`（从 harness 根和 cwd，既有的 shell 环境总是优先——见
下文）并继承 core 的环境。完整集合：

| 变量 | 含义 | 默认值 |
|---|---|---|
| `NIF_ROOT` | harness 根目录（仓库）。未设置时 core 从二进制位置推导，并为所有子进程设置。组件用它寻找 SDK、`var/`、`.env`。每个组件都以 **cwd = NIF_ROOT** 运行，因此 agent 的 `bash pwd` 永远是 home——无论你从哪里启动 harness | `<binary location>/../..` |
| `NIF_NATS_URL` | 总线地址。在**环境变量**里（测试、bench、脚本）：只附着——core 精确使用该总线。写在 **`.env`**（或众所周知的 `nats://127.0.0.1:4222`）：本 clone 的 **home 总线**——空闲时认领，仅在应答的 core 服务本 root 时才附着（通过 catalog 的 `root` 字段识别），遇到外来 core 或裸 nats-server 会大声让出（改用隔离的随机总线；先回收已记录的多余 `var/nats-pid`），并写入 `var/nats-url` | auto |
| `NIF_NATS_SPAWN` | `1` 强制在随机端口启动 core 独占的隔离总线——绝不用 4222，绝不附着（开发 clone 和测试）。显式 `NIF_NATS_URL` 优先 | unset |
| `NIF_AUTOSTART` | SDK 的 `ensureHarness` 不得不启动 core 时设置：该 core 在最后一个交互客户端离开后退出（见 Starting and stopping） | unset |
| `NIF_AUTOSTART_IDLE_S` | 最后一个交互客户端离开后，autostarted core 退出前的秒数 | `10` |
| `NIF_AUTOSTART_BOOT_S` | autostarted core 等待第一个交互客户端的秒数，超时放弃 | `60` |
| `NIF_ENSURE_ATTACH` | `0` 让 `ensureHarness` 跳过附着、总是启动 core（测试） | `1` |
| `NIF_STORE_BACKEND` | 引导时选择的 store 引擎：`sqlite`（默认 → `var/bin/store-sqlite`）、`barrel`（→ `var/bin/store`）、`tidb`（→ `var/bin/store-tidb`）；其他值拒绝启动。所有引擎都以组件 `store` 注册相同工具——见 [Store engines](#store-engines)。未迁移的 barrel 会让 core 打印 `niffler-store-migrate` 指引并拒绝启动；`barrel` 是逃生口 | `sqlite` |
| `NIF_STORE_TIDB_DSN` | `tidb` store 引擎的 TiDB/MySQL DSN，如 `root@tcp(127.0.0.1:4000)/niffler`（单节点 docker：`docker run -p 4000:4000 pingcap/tidb`）。该引擎必需——没有本地默认值；组件缺它会拒绝启动。除非 DSN 设置 `time_zone`，会话强制 UTC | unset |
| `NIF_GIT_MIRROR` | `plugins` 组件 clone 包时代替 `https://github.com` 的主机前缀（如 `https://cnb.cool` 或 Gitee 镜像）——API/搜索端点仍在 GitHub | unset |
| `NIF_NPM_REGISTRY` | `builder` 安装 ts 组件使用的 npm registry（如 `https://registry.npmmirror.com`） | npm 默认 |
| `NIF_OPENAI_API_KEY` | LLM 适配器（`llm`）的 API key。任何会话回合都需要 | — |
| `NIF_OPENAI_BASE_URL` | OpenAI 兼容端点 | `https://api.openai.com/v1` |
| `NIF_OPENAI_MODEL` | 模型名 | `deepseek-chat` |
| `NIF_OPENAI_PROVIDER` | 默认 LLM 连接的 models catalog provider id；未设置时常见端点会被推断 | inferred |
| `NIF_OPENAI_CONTEXT` | llm 向 core 上下文守卫报告的显式上下文窗口（token） | `models` 目录，然后 `llm` 回退 |
| `NIF_AGENT_MODEL_WEAK` / `NIF_AGENT_MODEL_MEDIUM` / `NIF_AGENT_MODEL_STRONG` | 请求 `modelTier` 时新子代理使用的确切模型 id；子代理的档位会被夹到父会话已配置的档位 | unset |
| `NIF_AGENT_DEFAULT_TIER` | 父会话的确切模型不在已配置阶梯中时使用的档位上限（`weak`、`medium` 或 `strong`） | `strong` |
| `NIF_AGENT_WAKES` | 后台子代理在会话空闲时结算后，该会话可连续运行的自主唤醒回合数（docs/WIRE.md "Autonomous wake"）；人类的下一条消息重置预算，`0` 禁用唤醒（通知随后等待下一回合的 pull 排空） | `3` |
| `NIF_AGENT_NOTICE_HOLD` | `0` 允许回合在最后一步收到结算通知时照常关闭（通知等待下一回合排空）；默认会把回合多保持一步，使它不能越过刚刚结束的子代理关闭（docs/WIRE.md "Busy-parent inbox"） | `1` |
| `NIF_LLM_PROVIDERS` | 命名提供商的 JSON 对象 `{nickname: {baseUrl, apiKey, model, context, catalog}}`，供 `chat` 工具的 `provider` 参数解析；provider 注册表（`provider` 组件）激活时取代默认值 | `{}` |
| `NIF_MODELS_URL` | models.dev 兼容目录的基址或 JSON 端点 | `https://models.dev/api.json` |
| `NIF_MODELS_PATH` | 固定的本地基线目录；便于离线/测试 | unset |
| `NIF_MODELS_OVERRIDE` | 在所有插件来源之后应用的本地 JSON Merge Patch | unset |
| `NIF_MODELS_OFFLINE` | `1` 禁用远程目录刷新 | unset |
| `NIF_MODELS_CACHE_DIR` | 目录和来源补丁缓存 | `$NIF_ROOT/var/models` |
| `NIF_MODELS_CACHE_TTL` | 重新抓取基线前的最小年龄 | `5m` |
| `NIF_MODELS_REFRESH_INTERVAL` | 后台刷新间隔；`0` 禁用 | `1h` |
| `NIF_FETCH_DIR` | 大体积 fetch 结果和临时提取文件 | `$NIF_ROOT/var/fetch` |
| `NIF_FETCH_ALLOW_PRIVATE` | `1` 允许 `fetch` 工具访问 loopback/私有/链路本地地址；仅用于可信的本地开发服务 | unset（阻止） |
| `NIF_SKILLS_BUNDLED_DIR` | 显式指定 `skills` 组件内置树的位置，取代 `<repo>/skills` 及其 `$NIF_ROOT/skills` 回退。路径不存在时发现机制提供编译内置副本（目录 `(baked)`） | `<repo>/skills` |
| `NIF_MCP_DIRECT_THRESHOLD` | 配置为 `expose: direct` 的 MCP 服务器可直接发布的缓存工具数上限；更大的服务器延迟到渐进式发现 | `10` |
| `NIF_MCP_BRIDGE_BIN` | mcp-bridge 二进制的显式路径 | `<root>/var/bin/mcp-bridge` |
| `NIF_PROCESSES_SPOOL_CAP` | 后台进程输出文件在下次 poll 时被截断为尾部的阈值 | `33554432` |
| `NIF_PROCESSES_POLL_CHUNK` | 单次 `process_poll` 每流返回的最大新增字节数（保持在 spool 上限之下，突发总会被切开） | `65536` |
| `NIF_LSP_REGISTRY` | 语言服务器用户注册表（`servers.json`）的绝对路径 | `$XDG_CONFIG_HOME/niffler-lsp/servers.json` |
| `NIF_LSP_WARM_MAX` | `ev.workspace.opened` 时每个工作区预启动的重型（持有索引的）语言服务器数 | `2` |
| `NIF_LSP_WARM_CHEAP` | 预启动的轻量（不建索引）服务器数，使用自己的预算——它们绝不挤掉重型名额 | `1` |
| `NIF_LSP_WARM_TOTAL` | 每个工作区预启动进程的总上限 | `4` |
| `NIF_LSP_BIN` | `make install-lsp` 使用的安装目录（服务器包装脚本和用户本地 JDK）；也作为默认回退 bin 目录参与解析 | `~/.local/bin` |
| `NIF_LSP_BIN_DIRS` | 在 PATH 之外额外搜索服务器二进制的目录（展开 `~`） | — |
| `NIF_TRAFILATURA` | Trafilatura 可执行文件路径/名称；`off` 禁用外部提取 | 在 `PATH` 上自动探测 `trafilatura` |
| `NIF_LOG_LEVEL` | SDK 结构化日志发布阈值（`debug`、`info`、`warn`、`error`） | `info` |
| `NIF_LLM_MAX_RETRIES` | 瞬时 LLM 失败（429/5xx/过载/连接断开）的额外尝试次数，指数退避；每次重试都会广播 `ev.session.<id>.retry`。认证/配额/坏请求错误总是快速失败 | `2` |
| `NIF_LLM_MAX_STREAM_RETRIES` | 流式响应中途断开时的额外尝试——与一般情况分开计预算，因为断开的流可能已经计费了输出 | `2` |
| `NIF_LLM_MAX_CONNECT_RETRIES` | 连接/拨号失败的额外尝试次数 | `2` |
| `NIF_LLM_RETRY_AFTER_CAP_MS` | 服务器 `retry-after` 提示的等待上限；更长的提示等待会被夹到这个值 | `3600000` |
| `NIF_LLM_TIMEOUT_MS` | 单次 `llm` `chat` 完成的时限；慢推理模型（例如经 llmgateway 的 GLM thinking=max）单次响应可能超过默认值 | `300000` |
| `NIF_CTX_RESERVE` | 上下文准入保留的输出 token；默认为模型在目录中解析出的输出上限，未知时 `16384`；`0` 禁用保留 | 目录输出上限 |
| `NIF_COMPACTION_TOOL` | runner 选择的 contract-v1 候选工具；为空则禁用摘要，但不影响 prune/trim/错误准入 | `compaction_propose` |
| `NIF_COMPACTION_TIMEOUT_MS` | 整个候选调用的截止时间（最小 5000 ms） | `90000` |
| `NIF_COMPACTION_MAX_LLM_CALLS` | 授予一次尝试的辅助摘要调用预算；报告调用数超过授予值的候选会被判为无效 | `4` |
| `NIF_COMPACTION_MAX_SUMMARY_TOKENS` | 每次调用的检查点输出上限 | `4096` |
| `NIF_OBSERVE_RING` | observe 全局环形缓冲保留的消息数 | `2000` |
| `NIF_OBSERVE_RING_BYTES` | 全局环形缓冲保留的近似 wire 字节数 | `16777216` |
| `NIF_OBSERVE_ENTRY_BYTES` | 每条观察消息保留的最大字节数 | `65536` |
| `NIF_OBSERVE_MAX_PROBES` | 同时保留的活跃 + 已停止探测数 | `32` |
| `NIF_OBSERVE_PROBE_BYTES` | 每个探测保留的字节数 | `2097152` |
| `NIF_OBSERVE_CAPTURE_DIR` | `observe_dump` 的受限目录 | `$NIF_ROOT/var/captures` |
| `NIF_OBSERVE_CAPTURE_BYTES` | 生成捕获的总配额；最旧的文件先被清理 | `67108864` |
| `NIF_OBSERVE_MONITOR_URL` | 外部/复用总线的显式 nats-server HTTP 端点 | core 发现文件 |
| `NIF_LOGFILE_DIR` | JSONL 输出目录 | `$NIF_ROOT/var/logs` |
| `NIF_LOGFILE_SUBJECTS` | 要持久化的逗号分隔 NATS 模式 | `ev.log.>` |
| `NIF_LOGFILE_MAX_BYTES` | 轮转前每个 JSONL 文件的活跃字节数 | `10485760` |
| `NIF_LOGFILE_KEEP` | 保留的轮转代数（`0` 禁用） | `5` |
| `NIF_LOGFILE_MAX_FILES` | 回退到 `bus.jsonl` 前的组件专用文件数 | `64` |
| `NIF_LOGFILE_SCAN_BYTES` | 单次 `logfile_search` 检查的最大字节数 | `16777216` |
| `NIF_LOGFILE_DIRECTORY_ENTRIES` | 每次查询枚举的候选 JSONL 路径上限 | `10000` |
| `NIF_AUTO_APPROVE` | `1` → 绕过审批门（见下文）。仅用于无人值守自动化；绝不要在你在意的会话中设置 | unset |
| `NIF_AUTO_CONTINUE` | `1` → 回合触及会话软限制（`/limit`）时不再询问、继续运行。仅用于无人值守自动化 | unset |
| `NIF_MAX_TURN_ROUNDS` | 每回合的硬性 LLM 轮数上限；显式的每会话 `maxRounds` 可以收窄它 | `1000` |
| `NIF_MAX_DIRECT_TOKENS` | `invoke {sticky: true}` 提升时对会话直接工具集的估算 token 上限；超出的提升会被推迟并在工具结果中报告 | `4000` |
| `NIF_PROFILE` | 新会话默认的命名工具配置，在 `session` 调用未携带 `profile` 参数时使用 | unset |
| `NIF_AGENT_MAX_DEPTH` | `agent_spawn` 委托可嵌套的深度上限（core 在分发时强制执行；agent 组件镜像同一限制）。`0` 完全禁止委托；到达上限时 spawn 工具仍然可见 | `1` |
| `NIF_HOOKS_EVENTS` | hooks 组件监视的逗号分隔总线主题；主题中任意位置的 `>` 通配可用。启动时读取——改配置即 `core.kill` + `core.spawn` | `ev.session.*.turn` |
| `NIF_HOOKS_<SUBJECT>` | 某个被监视主题要运行的 shell 命令（点和 `>` 变成 `_`：`ev.session.*.turn` → `NIF_HOOKS_EV_SESSION_TURN`）；事件负载以 JSON 从 stdin 传入 | unset |
| `NIF_HOOKS_TIMEOUT_MS` | 每个 hook 的超时；超过 60000 的值会被夹住 | `10000` |
| `NIF_MCP_REGISTRY_URL` | 外部 MCP 服务器目录的基址（气隙/代理环境） | `registry.modelcontextprotocol.io` |
| `NIF_MCP_PROBE_TIMEOUT_MS` | `mcp_add` 中一次真实连接探测的超时（覆盖 30s 默认值，并在调用自身的 `timeoutMs` 更高时覆盖它） | `30000` |
| `NIF_READ_OUTLINE_LINES` | 超过该整读行数阈值时，read 返回语言服务器符号大纲而不是原始窗口；`0` 禁用大纲 | `1000` |
| `NIF_REPOMAP_AUTOAPPEND` | `1` 选择开启 repomap 组件的工作区打开自动追加（每个新会话注入一次地图）。默认关闭——各 A/B 的符号随区间反转，最初的高档测试部分测的是桩地图（`bench/reports/repomap-ab-*.md`）。`repo_map` onDemand 工具不受影响 | unset |
| `NIF_REPOMAP_MIN_CENSUS` | 追加的普查文件下限：覆盖源文件更少的工作区从不建图（docs/research/REPOMAP-GATES.md） | `50` |
| `NIF_REPOMAP_MIN_BYTES` | 追加内容门控：渲染出的地图小于该字节数即视为桩，予以扣留 | `800` |
| `NIF_REPOMAP_MIN_SYMBOLS` | 追加内容门控：渲染符号行数下限 | `25` |
| `NIF_REPOMAP_MIN_FILES` | 追加内容门控：承载符号的文件数下限 | `5` |
| `NIF_RUNNER_IDLE_S` | session runner 无会话调用达到该时长后退场；下一次调用会启动新的 runner（子代理按需重新确保） | `600` |
| `NIF_WRITE_MAX_BYTES` | `write` 工具整文件负载的上限 | `900000` |
| `NIF_OAUTH_CALLBACK_HOST` | 本地 OAuth 回调监听的主机（端口固定为 1455/53692） | `127.0.0.1` |
| `NIF_LOG_MAX_MB` | core 在 `var/logs` 中保留子进程日志的上限（MB） | `200` |
| `NIF_LOG_RETENTION_DAYS` | core 清理子进程日志前的保留天数 | `7` |

每个 Niffler 变量都带 `NIF_` 前缀，因此 harness 绝不会与采用裸约定的工具
（`NATS_URL`、`OPENAI_API_KEY`）冲突。

### The `.env` file

`.env`（仓库根目录，gitignored）保存本地密钥/配置：

```bash
NIF_OPENAI_API_KEY=sk-...
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1
NIF_OPENAI_MODEL=deepseek-chat
```

加载规则（Nim SDK、Go SDK 和 UI bridge 完全一致）：既有 shell 环境**总是**胜过
`.env`；`.env` 依次从当前目录和 `$NIF_ROOT` 加载。因此
`NIF_OPENAI_API_KEY=other ./var/bin/niffler` 覆盖文件值，想要文件值就先
`unset NIF_OPENAI_API_KEY`。

仓库根目录的 `.env.example` 是完整参考：每个 `NIF_*` 变量、全部注释掉、注释值
即默认值，并说明它控制什么——复制它，取消注释即可。

## The bus in one screen

core 只说一种协议：NATS 上的 JSON 信封（细节见 [WIRE.md](WIRE.md)）。主题：

```
reg.publish            组件宣告自己：{name, version, pid, tools:[{name, schema}]}
reg.depart             优雅关闭宣告
svc.<component>.call   队列组的工具调用请求/应答
svc.session.<id>.steer   回合中途消息注入（fire-and-forget，{content}）
svc.session.<id>.advise  回合绑定的顾问请求/应答（expert 同伴）：
                         仅当命名 turnId 仍活跃时接受
ev.session.<id>.turn        {sessionId, turnId, phase: start|done, content?, error?}
ev.session.<id>.assistant   {sessionId, turnId?, content, provider?, model?, context?, usage?}
ev.session.<id>.status      {sessionId, turnId?, provider?, model?, context?, usedTokens?}
ev.session.<id>.token       {sessionId, turnId?, content, reasoning}  （实时 token 增量）
ev.session.<id>.toolcall    {sessionId, turnId?, callId?, phase: start|done, tool, args, result|error, durationMs?}
ev.session.<id>.advice      {sessionId, turnId?, source, content} 一条建议被折入
ev.session.<id>.notice      {sessionId, turnId?, kind?, content?, jobId?, child?,
                       status?} 运行时机器内容被折入（子代理结算、后台进程退出、自主唤醒）
ev.session.<id>.done        {sessionId, turnId?, reply} | {sessionId, turnId?, error}
ev.session.<id>.context     {sessionId, turnId?, promptTokens, usedTokens, context, warning?|trimmed?}
ev.catalog.updated     任何注册变化之后的直接（面向提示词的）工具投影；
                       `catalog {op: snapshot}` 仍返回全部（含隐藏/on-demand schema）
ev.models.updated      刷新后有效的 provider/model/source 计数
ev.provider.switch     provider 组件 → 总线：{nickname, previous, source, at}
ev.provider.changed    脱敏后的 provider 注册表失效事件
ev.llm.token           llm 适配器 → core：{sessionId, content, reasoning} 增量
ev.sys.drain           core → 组件：停止接活、完成在途、退出
svc.approval.<name>.request 定向审批，发给正在驱动该回合的组件（由调用信封
                       的 `caller` 推导）；driver 先 ack {id, ack: true}，
                       再回答 {id, ok}
ev.approval.request    core → UI：{id, tool, args, caller?, fallback?} ——
                       人工门控，广播（见下文 Approvals）
ev.approval.reply      UI → core：{id, ack?} | {id, ok}
ev.approval.resolved   core → UI：{id, ok} —— 门控裁决；关闭过期弹窗
cancel.<component>     取消侧信道：回合取消落在在途分发上时由 runner 发布；
                       bash 会杀掉命令的进程组（见 WIRE.md）
```

**流式。** `llm` 组件在生成时流式输出 token：`ev.llm.token` 增量（content 和
reasoning）→ core 为活跃回合转发为 `ev.session.<id>.token` → UI 追加到实时 assistant
气泡。最终的 `ev.session.<id>.assistant` 事件总是携带完整内容，因此漏掉最后一帧也会
自愈。向 `llm.cancel.<sessionId>` 发布消息即可中止在途调用。

用 `nats sub '>'` 附着到总线，可以实时看到 harness 在思考。
或者更好：**console 组件**（`./var/bin/console`，不在 manifest 中——自己在第二个
终端启动）订阅一切并以可读方式渲染 wire 流量：带工具和参数的调用、结果、错误、
事件、审批——这就是你跟踪实时安装或卡住的工具调用的方式：

```bash
./var/bin/console    # 在另一个终端，harness 运行时
```

**cli 组件**（`./var/bin/cli`）从脚本或流水线驱动同一条总线——非交互、对 CI
友好（成功退出 0）；它是脚本入口，tty 管理 shell 是交互入口：

```bash
./var/bin/cli catalog                        # 组件及其工具
./var/bin/cli wait <component> [secs]        # 等待注册
./var/bin/cli call <tool> '<json args>'      # 分发并打印结果
./var/bin/cli install <repo>[@<ref>]         # plugin_install + 验证
```

`cli install` 会 clone、经 builder 构建、启动每个组件，并等待每个服务名出现在
core 已接受的 catalog 中；交互式组件以构建完成为验证。CLI 的目录和工具查找也
使用 core 的权威目录，绝不使用原始注册广播。插件仓库的 CI 通过这一条命令运行
harness 来证明包可用。`file://` 仓库 URL 可从本地 git 仓库安装（封闭测试、
镜像）。基于名称的验证不能区分已接受组件与同名新启动的进程。

## Approvals

schema 携带 `x-harness.approval: "always"` 的工具——当前是
`bash`、`build`（`builder` 组件）、core 的 `spawn`、`kill` 和
`remove`、`edit`、`write`、`undo_last_edit`、`fabric`、`agent_run`、
`agent_spawn`、`agent_ask`、`expert_follow`、`lsp_registry`、`mcp_add`、
`mcp_edit`、`mcp_remove`、`mcp_refresh`、`plugin_install`、`plugin_update`、
`plugin_remove`、`process_start`、`process_kill`、`skill_install`、
`skill_remove`、`provider_add`、`provider_update`、`provider_export`、
`provider_import`、`provider_use_environment`、`observe_send`、
`observe_request`、`observe_dump`、`observe_monitor`——执行前都需要人类的
许可（core 未注册的 `conversation_delete` 接口同样被门控）：

- **终端 harness**（`make run`）：出现 `[approval]` 提示，显示工具名和参数；
  回答 `y`/`n`（只有 core 在终端上且没有 UI 附着时才回退到 tty 提示）。
- **Web UI / 交互组件**：请求被路由到正在驱动该会话的那个组件——core 从调用
  信封自称的 `caller` 推导，并发布到该组件的私有主题
  `svc.approval.<name>.request`。driver 先 ack（`{id, ack: true}`）确认正在
  询问人类，显示带工具名和参数的弹窗，再回答 `{id, ok}`。
- **driver 不在/非交互**：若 driver 在短窗口内没有 ack，请求会在
  `ev.approval.request` 上以 `fallback: true` 重新广播，让任何交互客户端接管。
  直接（非会话）调用立即广播。
- **两者都没有**（服务模式且没有 UI）：调用**被拒绝**并给出明确错误——绝不
  静默批准。
- 裁决到达时，core 发布 `ev.approval.resolved {id, ok}`，让每个客户端关闭
  过期的弹窗。
- 无人应答的 UI 请求在 5 分钟后超时并被拒绝。
- `NIF_AUTO_APPROVE=1` 绕过门控（无人值守自动化）。

### Conversation controls: `/approvals`, `/limit` and `/compact`

这三个控制属于你（人类），永远不属于模型，而且只作用于一个会话。它们都通过
session 调用设置（Web UI 以 `/approvals`、`/limit` 和 `/compact` 暴露；任何
总线客户端都可直接调用 `session`）。`approvals` 和 `limits` 设置会随会话持久化，
因此恢复的会话会保留它们；`/compact` 是一个动作，不是设置。

- **`/approvals auto`** —— 该会话不再询问：每个被门控的工具都会被授予，core
  会大声记日志（`core: approval auto-granted for <tool>`），因为静默授予正是
  门控要防止的事。`/approvals ask`（或带空参数的 `/approvals`）恢复正常门控。
  用于你决定完全信任的会话；更窄的信任仍可用每工具的“不再询问”记录。
- **`/limit rounds=N tokens=N seconds=N`** —— 回合的软预算：LLM 轮数、累计
  token 和墙钟秒数（在每次工具分发前检查，不只是回合之间）。触及之一时回合
  不会死：core 通过同一审批通道问你**“继续吗？”**（UI 显示一个 Continue/Stop
  提示并指明是哪个限制），*是*会把该限制再放宽一步。*否*、无应答或没有可达
  客户端会以独特的 `limit-<dimension>` 记录结束回合，记录中给出限制名和提升
  它的命令。`/limit clear` 清除全部三项。
- **`/compact`** —— 立即运行压缩器，而不是等待自动压力阶梯：core 向已配置的
  压缩组件请求允许切点上的检查点，原子安装它，并发出通常的
  `ev.session.<id>.context {reason: "reset:compact"}`。不运行 LLM 回合，也不追加
  用户消息。回复报告 `compacted: true` 及前后 token 数，或
  `compacted: false` 及原因（未配置压缩组件、压缩器拒绝、或还无可压缩内容）；
  拒绝绝不静默降级为有损裁剪。

关键区别：这些限制是*你的*，所以可以协商；作业级预算
（`maxRounds`/`maxCalls`/`maxTokens`，`agent` 组件把它们冻结进子代理会话，
以及 `NIF_MAX_TURN_ROUNDS`）保持硬性——子代理不能靠话术给自己争取更多预算。
`NIF_AUTO_CONTINUE=1` 对所有“继续吗”问题回答是（无人值守自动化，精神同
`NIF_AUTO_APPROVE=1`）。

回合运行期间到达的 session 调用会立即以 `busy` 拒绝
（“the conversation is mid-turn — retry when the turn finishes”）而不是等待：
回合绝不嵌套，而选择等待的客户端只会耗尽自己的超时（这就是长回合中
`/export` 看起来坏掉的原因）。

## Context window

core 监视会话使用了模型上下文窗口的多少，并采取*朴素*行动——不做摘要，
除模型上报的数字外不做 token 数学：

- 有效窗口在每个回合前由隐藏的 `llm_resolve {model?}` 解析，因此新选择的模型
  的限制会在推理前到达上下文守卫。提供商的 `context` 和 `NIF_OPENAI_CONTEXT`
  覆盖 models 目录；若移除 `models`，小型内置表和保守的 128K 仍作为回退。
  结果包含无密钥的 provider、model、catalog 和 context 来源信息，供交互客户端
  使用。见 [Model catalog](#model-catalog-models)。

- `session {sessionId, content?, model?, thinking?, title?, cwd?, profile?, discovery?, tools?, maxRounds?, maxCalls?, maxTokens?}`
  接受会话作用域的模型覆盖。仅模型的调用会持久化并解析选择，不做推理；带空值
  出现则清除它。`profile` 命名存储的工具配置，只在会话首次调用时解析进直接
  工具集（`NIF_PROFILE` 提供默认）；未知配置会让调用失败，恢复时会忽略该参数。
  `discovery {…}` 是显式客户端发现：它运行 `discover`，把 schema 记录进持久化
  发现摘要并作为用户消息追加——不运行 LLM 回合，也不提升进直接工具集。
  core 把选择存进会话头，并在一个回合内的所有工具轮次中钉住已解析的模型。
- 每会话控制在首次调用时冻结并持久化在头中：`tools`（子代理可分发的工具
  白名单）、`maxRounds`（每回合 LLM 轮数，1–`NIF_MAX_TURN_ROUNDS`，收窄硬
  上限）、`maxCalls`（每回合工具分发总数，1–500——每次分发尝试都计数，成功
  或报错），以及 `maxTokens`（每回合累计提供商上报 token，检查于每个新轮次
  之前）。预算耗尽会让回合以 budget-exhausted 错误结束——子代理驱动
  （`agent_run`/`agent_spawn`）把它作为失败上报，而不是文本回复。
- `cwd` 钉住会话的**工作区**：`NIF_ROOT` 内的一个已存在目录（相对路径相对根
  解析），创建后不可变并持久化在头中，使恢复的 runner 以完全相同的方式解析
  上下文和路径。session runner 在分发时重写路径形态的工具参数：bash 以
  workspace 为 cwd 运行，edit/grep/read 在那里解析相对路径，git 工具以
  workspace 仓库为作用域。systemprompt 组件在它与根不同时追加一条工作区提示。
  默认工作区就是 `NIF_ROOT` 本身。
- 每次 chat 调用后 core 记录 prompt token，并用 `usage.total_tokens`
  （或 prompt + completion 回退）作为当前占用的最佳值。provider、model、
  context、占用和覆盖也镜像进会话头，因此计量器无需加载整个记录就能跨重启
  存活。
- core 发出 `ev.session.<id>.status`，包含已解析的 provider/model/context 和当前
  `usedTokens`；客户端直接渲染 `usedTokens / context`。当提供商上报缓存输入
  （`prompt_tokens_details.cached_tokens`）时，status 事件还携带
  `cacheHitTokens` 和 `cacheHitRatio`——冻结的提示词前缀意味着首次请求后大部分
  prompt token 应命中缓存，所以低比率是值得注意的信号（Web UI 每条消息显示
  `⚡ NN% cached`；TUI 状态行显示一个 `⚡ NN% cached` 小片）。
- 持久化消息携带从不进入 LLM 的审计元数据：每条消息的 `createdAt`、到处都有
  的 `turnId`，以及 assistant、tool 和 error 记录上的 `startedAt`/
  `durationMs`（LLM 调用本身失败时会持久化一条 `error` 记录，回放会跳过
  error 角色）。
- 准入运行在**每次**提供商请求之前，包括每个工具循环轮次。在还没有上报用量
  之前，它用保守的 chars/4 估算给整个请求定价（消息加上冻结的工具 schema）。
  保留的余量是目录中该模型声明的输出上限（`limit.output`，例如 DeepSeek 的
  384000）——提供商在准入时把请求的 `max_tokens` 计入其窗口，因此固定 16K
  的保留曾让 736,803 token 的提示词溢出 1,048,576 的提供商限制，而该提示词
  本身是装得下的。`NIF_CTX_RESERVE` 覆盖推导出的保留量。core 在到达有效线的
  75% 处警告一次（`ev.session.<id>.context {reason: "warn:threshold"}`）；在线上
  ——绝不晚于窗口的 90%——core 执行有界阶梯：确定性工具结果 prune → 已配置
  压缩器 → 最老完整回合 trim → 显式 `context-recovery-required`。在 wire 上，
  `llm` 组件还会把请求的输出夹到序列化提示词（消息加工具 schema）留出的余量，
  因此任一层的估算漂移都无法把装得下的提示词推过提供商限制。它绝不有意发送
  超窗请求。
- 触发以**提供商的标度而非估算的标度**度量：每个成功响应都会重新测量校准
  偏移（上报的 `prompt_tokens` 减去对同一请求的本地估算），准入、警告和 trim
  都以估算 + 偏移给候选定价。原始 chars/4 代理可能比更密的 tokenizer 落后
  数万 token——在一个 524K 窗口的会话中观察到：所谓“90%”线实际在约 99% 才
  触发，而 core 称之为 86% 的请求被 400 拒绝。偏移是按模型作用域的（模型变化
  时清除，从下一个响应重新学习），恢复时用存储用量播种，夹在 `[0, window]`，
  从不持久化——首次响应时重新测量。
- 内置的 `compaction_propose` 可替换：设置
  `NIF_COMPACTION_TOOL=<tool>` 选择另一个 contract-v1 实现，或设为空以禁用
  摘要而保留确定性守卫。`NIF_COMPACTION_TIMEOUT_MS`、
  `NIF_COMPACTION_MAX_LLM_CALLS` 和 `NIF_COMPACTION_MAX_SUMMARY_TOKENS` 约束
  每次尝试。runner 写一份临时的分页 `compaction_input` 快照，校验候选的
  generation/digest/cut/schema/size 和严格缩减，然后用乐观 `expectRev` 提交
  一份 `context_projection` 文档。组件永不写会话或投影记录。
- 成功投影发出 `reason: "reset:compact"`；无模型 prune 发出 `reset:prune`；
  有损回退发出 `reset:trim`。`reset:tools` 保留给真正的 sticky 工具 schema
  提升。这些是唯一有意的提示词前缀重建，使缓存未命中可归因。
- 规范 `message` 文档不可变且只追加。prune 和压缩只改变提供商投影；重启的
  runner 校验并重载持久化检查点加保留的规范尾部，`context_recall` 解析规范/
  spill/当前检查点引用。缺失或损坏的投影引用会显式失败，而不是静默回放超限
  区间。
- 提供商上报的 `context-overflow` 只得到一次带收据的恢复尝试。同样的
  prune → 压缩器 → trim 顺序重新测量；第二次溢出即终止，绝不无限重试。当
  容量未知且拒绝信息中没有可解析的窗口时，尝试会盲减（无损 prune，再 trim 到
  最新请求），且只有候选确实缩小才会发出重试——不可缩减的候选以终止收场，
  而不是重发被拒绝的东西。适配器把提供商的各种溢出措辞（包括某些主机返回的
  裸 `"Context limit exceeded"` 正文）规范化为稳定的 `context-overflow` 前缀；
  runner 的分类器保留原始措辞作为回退。
- 有损 trim 是**持久的**：它把切到的规范 seqNo 记进会话头（`trimThrough`），
  普通恢复会遵守它，因此重启会重建 trim 后的投影，而不是重新膨胀完整 trim 前
  上下文、同时计量器恢复 trim 后的用量。被丢掉的回合仍留在规范历史中供
  `context_recall` 使用。

## Self-extension and component lifecycle

agent 在对话中途、运行时添加能力：

1. 编写组件源码（Nim：`import niffler/sdk`，类型化工具模式；Go：
   `import sdk "niffler.dev/sdk"`；TypeScript：`sdk/ts` 包——见系统提示词）
2. `build {lang, name, source}`（`builder` 组件）把它编译进 `var/bin/`
3. `spawn {name, binary, replicas?}`（core）启动它；它自行注册；新会话直接
   暴露它的工具（非 on-demand 时），已有会话通过 `discover` + `invoke` 触达
   （见 [Progressive tool discovery](#progressive-tool-discovery)）
4. `kill {name}` 临时停止每个副本（下次引导恢复）；`remove {name}` 停止整个组
   并删除其持久化记录

`replicas` 可选（1–16，默认 1）且会持久化。只用于无状态或外部协调的组件：
所有副本共享同一 `svc.<name>.call` NATS 队列组，因此并发请求每个进程分到一条。
绝不复制单写者的 `store`，也不要复制像 `edit` 那样变更/撤销状态是进程本地的
组件。默认 Nim SDK pump 保持串行。它的初始 NATS 连接在总线绑定期间最多重试
60 秒，然后进入 supervisor 的正常退避；关闭会中断该等待。组件在副本不合适时
可以显式拥有原生并发：长期/共享状态的 Nim worker 首选 `std/threads` +
`std/locks`，隔离作业用 `taskpools`，永不使用 `asyncdispatch`。在 Go 中，普通
`Tool` handler 保持独占；经过审计的 handler 可以使用 `ToolConcurrent`
（默认最多 16 个在途，可经 `ConcurrentLimit` 配置）。并发 handler 必须同步
共享状态，且不得同步调用同组件上串行化的工具。这个服务端选择与面向 runner 的
`x-harness.parallel` 提示相互独立。

**形态的持久化**：spawned 组件记录在 store 中（kind `component`），正常引导时
恢复。`--minimal` 不碰这些记录，但不恢复它们。`core` 本身、总线、catalog 和
supervisor 不可移除——这种不对称正是架构（ARCHITECTURE.md）。

## Component ecosystem (`plugins`)

`plugins` 组件是生态门户——社区组件包就是根目录带 `niffler.json` manifest 的
普通 GitHub 仓库（一个仓库 = 一个包 = N 个组件）。带 GitHub topic
`niffler-component` 的仓库无需任何注册表即可被发现：

| 工具 | 做什么 |
|---|---|
| `plugin_search {query?}` | GitHub topic 搜索；返回仓库、描述、star 数 |
| `plugin_installed` | 本 harness 已安装的包 |
| `plugin_install {repo, version?}` | clone 到 `var/plugins/<pkg>@<ref>/`，经 builder 的 `build` 工具从源码构建每个组件，然后 `spawn` 每个服务组件（需审批） |
| `plugin_update {package}` | 更新到最新 release tag：移除、按新 ref 重装；没有 release 的包（跟踪分支）原地拉取（现有 clone 的 `git pull --ff-only`），只在拉取移动了 HEAD 时重建 |
| `plugin_remove {package}` | `core.remove` 每个受监督组件，删除 clone，丢弃记录 |

- 安装/更新/移除都带 `x-harness.approval: "always"`——它们运行第三方代码，
  而且每一次单独的 spawn/remove 还会再经 core 审批。除非信任发布者，绝不要在
  `NIF_AUTO_APPROVE=1` 下运行它们。
- 默认 ref 是最新 release tag，否则默认分支。`version` 显式固定 tag 或分支。
- 组件总是经 `builder` 从源码构建——与 agent 编写组件走同一条路。运行 Niffler
  本身就提供工具链（Nim/Go 和 NATS SDK），因此不需要 NATS C 库；每个平台用
  自己的工具链编译。Go 条目可以声明
  `"sources": ["component/helper.go", ...]`；这些必须是与 `main` 同目录、同包的
  非符号链接 `.go` 文件，builder 把它们作为一个包编译。
- manifest 条目标记 `"interactive": true` 的组件会构建进 `var/bin`，但不会传给
  `core.spawn`。它是终端客户端（例如 TUI），由用户手动启动，因此不受监督、
  不会在引导时重启。移除或更新其包之前先手动停止任何运行中的客户端。
- 安装记录存在 store（kind `plugin`，id = 包名）；它们会像所有组件记录一样被
  `--recover` 清空——重新安装时新引导会按记录的 repo/ref 重新 clone。
- GitHub API 以未认证方式使用（每 IP 60 请求/小时）。
- 发布：添加 `niffler-component` topic 并打 release tag（`v1.0.0`）。
  [`gokr/niffler-weather`](https://github.com/gokr/niffler-weather) 示例的发布
  工作流自我验证：它引导一个 harness 并通过 `plugin_install` 安装该包，因此每个
  tag 都证明包能干净地安装。
- 包可以通过注册一个带 `x-models-source: {version: 1, priority: ...}` 的隐藏
  工具来扩展或修正模型元数据。`models` 组件会自动发现它，并在该组件存在期间
  应用其 JSON Merge Patch。见 [Source plugins](#source-plugins)。

## Skills

`skills` 组件为 agent 提供可复用的工作流指导——开放的
[Agent Skills](https://agentskills.io) 格式（带 YAML frontmatter 的 SKILL.md
文件），与 Claude Code、opencode 和 Cursor 所用约定相同。它只通过总线读取/加载：
没有任何工具把技能加进提示词，加载是经工具结果的渐进式披露。

全部八个工具都是 **on-demand**（`x-harness.onDemand`）：都不在会话冻结的直接
工具集中，因此首次触达要走一次 `discover` + `invoke`（见 [Progressive tool
discovery](#progressive-tool-discovery)）。加载技能会把其文本追加到历史——
这里没有任何东西改写冻结的提示词前缀，所以 `skill_load` 的代价是一次缓存读取，
而不是缓存未命中。

发现覆盖仓库内置技能加上标准 agent 目录（每个技能名首个匹配胜出——项目胜过
内置、胜过 home、胜过 config）：

| 来源 | 目录 |
|---|---|
| project | `$NIF_ROOT/.agents/skills`、`$NIF_ROOT/.claude/skills`、`$NIF_ROOT/.opencode/skills` |
| bundled | `<repo>/skills`（随 Niffler 出厂；`$NIF_ROOT/skills` 为回退，`NIF_SKILLS_BUNDLED_DIR` 覆盖这两者）——永不可移除 |
| home | `~/.agents/skills`、`~/.claude/skills`、`~/.opencode/skills`、`~/.niffler/skills` |
| config | `~/.config/opencode/skills`（`npx skills add -g -a opencode` 安装的位置） |

同一来源内目录按列出顺序尝试，因此 `~/.agents/skills/nats` 会胜过
`~/.claude/skills/nats`。发现是**每次调用都重新遍历**——没有缓存注册表、没有
刷新操作——因此 `skill_install` 或另一个 agent 的 `npx skills add` 立即可见。
遍历**不进入符号链接目录**：只通过符号链接到达扫描目录的技能不会被发现，
`skill_audit` 也不会列出它（因此像 `~/.claude/skills → ~/.agents/skills` 这样
的符号链接农场是不可见的——当链接目标本身也会被扫描时无害，否则静默丢失）。

内置技能（`todo-markdown`——把 todo 状态保存在仓库 TODO.md，而不是工具状态；
`niffler-tools`——哪个工具适合哪项工作；`niffler-fabric`——构造 fabric 程序；
`niffler-harness`——操作运行中的 harness）让 Niffler 开箱即用；把同名技能放进
项目或 home 目录即可遮蔽。

当**没有**可达的内置树时——部署只带 `var/bin` 而没有仓库 checkout，既没有
`<repo>/skills` 也没有 `$NIF_ROOT/skills`——发现会回退到**编译进二进制**的
内置 SKILL.md 文件。这些条目的 source 为 `bundled`、dir 为 `(baked)`；它们不带
资源（`skill_resources` 为空——内置技能本来也不带任何资源），且永不可移除。
磁盘按名称总是优先，因此有 checkout 时不受回退影响。

| 工具 | 做什么 |
|---|---|
| `skill_list {query?, source?}` | 可用技能（name、description、version、tags、source、dir）；按子串或来源过滤；编译内置回退条目的 dir 为 `(baked)` |
| `skill_search {query, owner?}` | 在线搜索 skills.sh 注册表（`npx skills find` 后端）：名称、仓库来源、安装数；`source`+`name` 对可直接喂给 `skill_install` |
| `skill_load {name}` | 完整 SKILL.md 指令 + 资源列表进入会话（加载机制）；正文超过 200 000 字节会截断并带 `truncated: true` |
| `skill_resources {name}` | 技能的 `references/`、`scripts/`、`assets/` 文件 |
| `skill_resource {name, path}` | 按需读取一个资源 |
| `skill_audit` | 磁盘上每个 SKILL.md 的只读、未合并清单——外加仅由编译内置回退提供的名称（dir `(baked)`）：标出每个名称的实际胜出者和每个被遮蔽/无效的副本（无效 = 不可读的 SKILL.md、无法解析的 frontmatter、或没有 `name`；发现结果在 `skill_list` 中合并，因此遮蔽只在这里可见） |
| `skill_install {repo, skill?, global?}` | clone git 仓库，把选定的 SKILL.md 树复制到 `~/.niffler/skills`（默认）或 `$NIF_ROOT/.opencode/skills` |
| `skill_remove {name}` | 只从 Niffler 管理的目录删除技能 |

- `skill_search` 是对 `https://skills.sh/api/search` 的只读 HTTP 调用
  （未认证）；不需要审批。安装需要：search → `skill_install {repo, skill}` →
  审批对话框 → 完成。
- 用 `npx skills add <owner>/<repo>`（skills.sh 生态 CLI）安装的技能落在上面的
  标准目录并被直接发现，无需重装；`skill_install` 的存在是为了让 Niffler 不依赖
  Node，走纯 git。它只复制 SKILL.md 树——不运行任何代码——并接受
  `owner/name`、github.com URL 和 `file://` 本地仓库（封闭测试）。
- 包含多个技能的仓库（例如 `vercel-labs/agent-skills`）需要 `skill` 参数；
  缺少时 `skill_install` 会列出候选。
- `skill_remove` 拒绝 `~/.niffler/skills` 和 `$NIF_ROOT/.opencode/skills` 之外的
  任何东西——其他 agent 装进共享目录的技能要用它们自己的工具卸载。
- 安装和移除带 `x-harness.approval: "always"`（它们写到 `var/` 之外）。

## Provider registry (`provider`)

已配置的 LLM 后端是 store 记录，不是配置文件。`provider` 组件把它们保存在
kind `provider` 下（id = 昵称，外加 `active` 标记文档），并向 agent 和 `llm`
暴露它们：

| 工具 | 做什么 |
|---|---|
| `provider_add {nickname, apiKey, protocol?, baseUrl?, model?, catalog?, context?, plugin?, active?}` | 添加 API-key 提供商（`protocol`：`openai-chat` 默认或 `anthropic`）；第一个会自动成为 active；响应脱敏 |
| `provider_update {nickname, apiKey?, protocol?, baseUrl?, model?, catalog?, context?, plugin?}` | 隐藏的客户端 API，用于部分更新；省略 API key 则保留原值 |
| `provider_oauth_start {protocol, method?, nickname?, model?, active?}` | 隐藏，开始订阅登录：`protocol` 为 `openai-codex`（ChatGPT Plus/Pro）或 `anthropic`（Claude Pro/Max）；`method` 为 `browser`（本地回调）或 `device`（无头，仅 OpenAI）。返回 `{flowId, url, userCode?, callbackAvailable, expiresAt}` |
| `provider_oauth_complete {flowId, code?}` | 隐藏，轮询/完成登录；在回调（或粘贴的 `code`）到达前返回 `{pending, retryAfterMs?}`，然后存储提供商并脱敏上报 |
| `provider_oauth_cancel {flowId}` | 隐藏，取消待处理登录并关闭其回调监听 |
| `provider_list` | 所有已存提供商（脱敏——无密钥/token）、哪个 active；每条带 `authType`（`api_key`/`oauth`）、`protocol` 和 `expiresAt` |
| `provider_status` | 隐藏，脱敏的有效提供商，含环境回退和 `hasKey` |
| `provider_active` | 隐藏的内部读取，返回有效提供商的完整配置（含凭据） |
| `provider_get {nickname}` | 隐藏的内部完整配置读取，用于在一个回合内钉住显式存储的提供商 |
| `provider_models {nickname?\|baseUrl?, apiKey?, refresh?}` | 提供商的 `/models` 端点当前提供的模型 id——按昵称取已存提供商，或显式端点+key（连接表单，凭据尚未保存时）。按端点磁盘缓存 5 分钟（探测失败时提供过期缓存）；错误返回给调用方，便于客户端回退到目录 |
| `provider_switch {nickname}` | 让另一个已存提供商成为 active；实时更新 LLM 后端 |
| `provider_use_environment` | 隐藏的客户端 API，清除存储标记并回到 `NIF_OPENAI_*` |
| `provider_remove {nickname}` | 删除提供商；若它是 active，另一个接管或恢复环境回退 |
| `provider_export` / `provider_import` | JSON 备份/迁移往返，含凭据；import 合并、校验记录并可恢复 active 标记 |

### Wire protocols

每个提供商带一个 `protocol`，`llm` 据此路由：

- `openai-chat` —— OpenAI 兼容的 Chat Completions 端点（默认；DeepSeek、
  OpenRouter、本地 vLLM……）。
- `openai-codex` —— ChatGPT 的 Codex Responses 端点
  （`https://chatgpt.com/backend-api/codex/responses`），带 ChatGPT OAuth 头
  （`chatgpt-account-id`、`OpenAI-Beta: responses=experimental`）；消息被翻译成
  Responses API 输入格式，SSE 事件流（text/reasoning 增量、函数调用）映射回
  共享结果形态。
- `anthropic` —— Anthropic Messages 端点；OAuth 登录发送 Claude Code 身份头
  和 beta，系统提示词以 Claude Code 前言开头，工具调用/结果被翻译成
  `tool_use`/`tool_result` 块（连续工具结果合并进一条 user 消息）。

### Subscription OAuth (ChatGPT Plus/Pro, Claude Pro/Max)

`provider` 组件实现与 Pi 和 opencode 相同的 PKCE 登录流程（固定 localhost 回调
端口、手动重定向/代码回退，以及面向无头机器的 OpenAI 设备码流程）：

1. `provider_oauth_start` 返回授权 URL；交互客户端在系统浏览器中打开。OpenAI
   也可选择 `device` 登录（在 `auth.openai.com/codex/device` 输入短码）。
2. `provider_oauth_complete` 轮询直到授权完成，然后交换代码并存储提供商——
   `authType: "oauth"`，含 access token、refresh token、过期时间和（ChatGPT 时）
   从 JWT 中提取的 account id。
3. 每次凭据读取（`provider_active`、`provider_get`、状态解析）都会在过期前
   5 分钟内透明刷新 token 并持久化轮转后的凭据。`llm` 组件永远看不到 refresh
   token。

环境旋钮：`NIF_OAUTH_CALLBACK_HOST`（默认 `127.0.0.1`）移动本地回调监听器
（端口像参考客户端一样固定为 1455/53692）。导出包含存活的 refresh token——把
`provider_export` 的输出当作密钥。

- `provider_add`/`provider_update`/`provider_import`/`provider_export` 带
  `x-harness.approval: "always"`——它们搬移凭据或修改连接设置。交互客户端在
  用户显式操作后直接调用隐藏的 update/status 工具，且绝不可渲染/记录凭据负载。
- `llm` 在每次 chat 调用时从 active 的已存提供商解析默认后端，因此
  `provider_switch` 立即生效。当 `provider` 组件缺席或没有 active 时，`llm`
  像以前一样回退到 `NIF_OPENAI_*` 和 `NIF_LLM_PROVIDERS` 表。`chat` 或
  `llm_resolve` 的显式 `provider` 参数先解析已存昵称，再解析
  `NIF_LLM_PROVIDERS`，因此会话可以在其回合内钉住一个非 active 的已存提供商
  而不切换全局默认。
- 已存提供商的显式 `context`（token）胜过 models 目录；其 `catalog` id 命名
  用于上下文查找的 models.dev 提供商，`plugin` 可以命名一个挂钩提供商专属工具
  的组件。每次切换时组件发布
  `ev.provider.switch {nickname, previous, source, at}`，让这类插件启用或隐藏
  自己的工具。每次注册表变更还会发布无密钥的
  `ev.provider.changed {op, nickname, active, source, at}`，供交互客户端使其
  provider/model 视图失效。
- `active` 标记是一个普通 store 文档——需要手动手术时用 `store` 工具删除或
  覆盖它。

## Hooks

`hooks` 组件（默认关闭）在选定的总线事件触发时运行操作者的 shell 命令——它是
CodeWhale hooks 中仅观察的子集（docs/research/CODEWHALE.md）。一个 hook 就是
一个普通进程：解码后的事件负载以 pretty JSON 从命令的 stdin 传入，命令本身绝不
与事件数据做插值，失败和超时（默认 10s，最大 60s）会记录日志且绝不致命。这里
有意没有 steering/veto：审批决策在 core 的分发门里。

配置基于环境变量，启动时读取（改配置 = `core.kill` + `core.spawn`）：

```bash
NIF_HOOKS_EVENTS="ev.session.*.turn,ev.log.error"   # 要监视的主题
NIF_HOOKS_EV_SESSION_TURN='notify-send Niffler "turn finished"'
NIF_HOOKS_EV_LOG_ERROR='jq -r .payload.msg | mail -s Niffler you@example.com'
NIF_HOOKS_TIMEOUT_MS=10000
```

主题 → 环境变量名：点和 `>` 变成 `_` 并大写
（`ev.session.*.turn` → `NIF_HOOKS_EV_SESSION_TURN`）。可工作的示例——桌面通知、
声音提醒、邮件、webhook、错误尾部——在 `components/hooks/README.md` 中。

## Fetch

`fetch` 组件是网页访问工具（旧 niffler `fetch` 工具的移植）。一个工具：

| 工具 | 做什么 |
|---|---|
| `fetch {url, method?, headers?, body?, timeout?, maxSize?, convertToText?}` | 对 http(s) URL 执行 GET/POST/PUT/DELETE/HEAD/OPTIONS/PATCH；HTML → 经 Trafilatura 或纯 Nim 回退得到干净文本；跟随重定向；执行各种上限 |

- `convertToText`（默认 true）从 HTML 提取可读文本——JSON 负载总是原样返回。
- 若 `PATH` 上有 `trafilatura`，fetch 把已下载的 HTML 交给它做更高质量的主内容
  提取（限制 30 秒）。缺失、失败、超时或空提取回退到内置的 `htmlparser` 遍历。
  设置 `NIF_TRAFILATURA` 为可执行文件路径/名称以覆盖探测，或用 `off` 禁用它。
- 响应受 `maxSize` 限制（默认 10 MiB，最大 50 MiB）；处理超过 200 KB 的内容会
  写到 `$NIF_FETCH_DIR`（默认 `$NIF_ROOT/var/fetch`）下的文件，工具结果指向它，
  因此 agent 用自己的文件工具读取大页面而不是撑爆会话。
- 错误（非 2xx、超时、超大响应、非法 URL/方法）以 `ok: false` 返回，带状态和
  正文片段。
- 只读网络访问——不设审批门（和 `plugin_search` 一样）。

## Language servers (`lsp`)

Status: **implemented**（Nim 组件；确定性的 fixture 测试；niffler-tui 客户端
提供 `/lsp` 注册表选择器）。

一个面向任何 stdio 语言服务器的通用接缝。组件不认识任何语言：哪个服务器处理
哪个文件扩展名是**数据**——注册表内置了合理的默认值。添加语言是配置条目，
绝不写代码（AGENTS.md 不变量：语言无关的 core）。

### The tools

| 工具 | 做什么 |
|---|---|
| `lsp {operation, path, line?, character?}` | 针对该文件的语言服务器执行一次查询：`diagnostics`（不用跑测试就能拿到编译/lint 错误）、`documentSymbol`（文件大纲：每个符号及其种类、名称和从 1 开始的位置——无需 line/character）、`workspaceSymbol`（全仓符号搜索——模糊 `query` 字符串；服务器在预热后建索引，因此首次调用可能需要重试）、`goToDefinition`、`findReferences`、`goToImplementation`、`hover`——或 `warmup`：`path` 传目录（或 `workspaceRoot`），普查其语言并预启动对应服务器 |
| `lsp_servers {}` | 列出已配置服务器（只读、免审批），带来源：`builtin` 默认或 `user` 注册表条目 |
| `lsp_registry {action: add\|remove, name, command, extensions?}` | 修改用户注册表（写操作，需审批）；`add` 也会覆盖同名内置项 |

模型发送从 1 开始的 line/character（UTF-16，匹配 LSP 的 code-unit 约定）；
`findReferences` 总是包含声明；结果有上限（100 个位置 / 16 KB）并带截断元数据；
结构化 `[E_LSP_*]` 错误（`E_LSP_UNAVAILABLE`、`E_LSP_UNSUPPORTED`、
`E_LSP_TIMEOUT`、`E_LSP_SCOPE`、`E_NOT_FOUND`）让调用方按 code 路由而不是解析
散文——超时和协议错误会附上服务器最后一行 stderr，指明实际失败原因（缺二进制、
崩溃、索引中）。

三个工具都是 **on-demand**（`discover`/`invoke`——见 [Progressive tool
discovery](#progressive-tool-discovery)），保持冻结工具集精简；工具描述就是
模型的 when-to-use 指南。`lsp` 工具只读且免审批；`lsp_registry` 写注册表文件，
需审批。

### Model usage

典型回合：

- 编辑不熟悉的代码前：对符号用 `goToDefinition`/`hover`，而不是从 grep 匹配
  里猜。
- 编辑编译型语言后：对改动的文件跑 `diagnostics`——一次调用拿到编译器裁决，
  而不是一整轮测试。
- 文本匹配有歧义时：`findReferences` 以语义方式解析符号。

查询会临时打开文档（`didOpen` 当前字节 → 请求 → `didClose`），因此每次查询都
看到文件此刻在磁盘上的样子——包括 agent 自己刚写入的编辑。每个
(server, workspace) 保持一个服务器进程并在查询间复用；超时或协议错误会拆掉该
实例，让下一次查询从新进程开始。路径被限制在会话工作区内（相对 `path` 参数相对
它解析；`..` 和绝对逃逸被拒绝）。

会话工作区宣告时（`ev.workspace.opened`）core 会自动触发一次**预热**：组件运行
有界的扩展名普查（5000 个文件或 2 秒预算后停止）并为最常见的语言预启动服务器，
使首次真实查询不必付服务器启动成本。`warmup` 操作显式重跑同一路径。

未配置的语言降级而不中断：没有服务器（或二进制缺失）的扩展名返回
`E_LSP_UNAVAILABLE`，消息里给出修复方式——“add one with the lsp_registry tool
(or edit <registry path>)”。模型自行回退到 grep/read。

### Registry: adding a language

三条路径，都写同一个文件：

1. **TUI 选择器** —— niffler-tui 中的 `/lsp`：浏览已配置服务器，`a` 添加
   （name、command、extensions——例如 `elixir-ls`、`elixir-ls`、`.ex, .exs`），
   ctrl+s 保存（人工审批提示，因为它在写配置）；`e` 编辑（内置项以覆盖形式
   打开），`d` 删除用户条目。
2. **让 agent 来做** —— “register elixir-ls for Elixir files” → 模型自己调用
   `lsp_registry add`（同样需审批）。
3. **直接编辑文件** —— `$XDG_CONFIG_HOME/niffler-lsp/servers.json`：

```json
{
  "elixir-ls": {
    "command": ["elixir-ls"],
    "extensions": {".ex": "elixir", ".exs": "elixir"}
  }
}
```

每个条目：`command`（argv 数组，或按空白拆分的普通字符串）加一个 `extensions`
映射（前导点扩展名 → LSP language id）。可选的 `initializationOptions` 透传给
服务器的 `initialize`。另外两个可选键承载以前要写代码的东西：`requires`（必须
可解析的运行时二进制，例如 jdtls 的 `["java"]`——运行时缺失的服务器会自我报告，
而不是启动后即死），以及 `cheap`（不建索引、因而不占重型预热名额的服务器；
bash-language-server 是内置例子）。

内置默认——gopls、nimtortoise、typescript-language-server、pyright、
rust-analyzer、clangd、bash-language-server、jdtls、intelephense、solargraph、
csharp-ls——只要二进制在 `PATH` 或回退目录（`~/go/bin`、`~/.nimble/bin`、
`~/.local/bin`、`~/.dotnet/tools`）中就可用；`make install-lsp` 幂等地安装它们
（Go、Nim 和 TS 是必需的——Niffler 由它们构建——其余是 y/n 提示，`--all` 用于
无人值守安装；每种语言失败不致命：lsp 工具只是以 `E_LSP_UNAVAILABLE` 跳过它；
`NIF_LSP_BIN` 覆盖安装目录，默认 `~/.local/bin`，它也是默认回退 bin 目录）。
Java 是唯一连*运行时*也会安装的语言：`PATH` 上没有 JDK 17+ 时，装一个用户本地
JDK 21 到 `~/.local/share/niffler-lsp/jdk`（无需 sudo，和服务器下载一样）——
此前没有 JRE 的 jdtls 包装脚本会报告“ok”然后在查询中途死掉。
添加同名条目即可覆盖内置项。注册表每次调用重新读取，因此编辑立即生效。

设置 `NIF_LSP_REGISTRY` 为绝对路径可迁移用户注册表（测试、多 harness 环境）。

**预热预算。** core 在会话引导时发布 `ev.workspace.opened`；组件普查工作区
（有界遍历）并预启动服务器，使首次真实查询不必付冷启动。重型服务器——那些给
整个工作区建索引的（gopls、rust-analyzer、jdtls、clangd、pyright、
intelephense、solargraph）——上限为 `NIF_LSP_WARM_MAX`（默认 2）个；不建索引的
*轻量*服务器有自己的预算（`NIF_LSP_WARM_CHEAP`，默认 1，且只从 2 个以上匹配
文件起）并且绝不挤掉重型名额——否则在一个满是 `.sh` 文件的仓库里
bash-language-server 会占掉两个名额之一，而任务实际所用的语言反而排不上。
`NIF_LSP_WARM_TOTAL`（默认 4）是每个工作区预启动进程的上限。`requires` 运行时
缺失的名额会列在 `skipped`（“jdtls (needs 'java')”）而不是被启动。

## Background processes (`processes`)

Status: **implemented**（Nim 组件；`tests/t_processes.nim`）。

bash 按设计是同步的——服务器、监视器和测试循环需要不同的契约：启动一次、
增量轮询输出、显式终止。

| 工具 | 做什么 |
|---|---|
| `process_start {command, label?, workdir?}` | 分离启动命令（独立进程组、stdin 来自 /dev/null、stdout/stderr 追加到 `var/processes/` 下的输出池文件）并立即返回 id。需审批 |
| `process_poll {id, waitMs?, filter?, tail?}` | 排空自上次 poll 以来追加的输出——增量，绝不重新注入旧字节；`waitMs` 阻塞直到有新输出或进程退出（上限 25 秒）；`filter` 是对新行的正则（排空游标仍会越过全部行推进）；任何非空 `tail` 会重读最后约 64 KB 原始输出。读效应 |
| `process_kill {id}` | 终止整个进程组。需审批 |
| `process_list {}` | 显示注册表——运行中和最近结束的条目及其退出码。读效应 |

细节：

- 子进程以追加模式写输出池文件（绝不用可能死锁的管道）；组件按每流游标读取，
  因此操作系统会吸收输出突发。超过上限（32 MiB，`NIF_PROCESSES_SPOOL_CAP`）的
  输出池会在下次 poll 时被截断为尾部；一次 poll 每流最多返回
  `NIF_PROCESSES_POLL_CHUNK` 个新字节（默认 64 KiB）。
- 上限：32 个并发进程；最近结束的 50 个条目留在注册表中。
- **结束的进程会告知其会话。** 通过 `bash` 工具的 `run_in_background` 标志启动
  进程时，bash 把归属会话交给注册表；该子进程退出时，`processes` 向该会话发布
  退出通知（与子代理结算通知相同的通道），因此接下来的回合以
  `[background process p3 (dev-server) exited(code 0)] ran 412s, 8123 bytes of
  output — read it with \`process_poll\` …` 开头。它是一个指针：输出留在输出池，
  命令文本从不外传。

  这就是后台作业不再被忽略的原因：组件按周期 tick（SDK 的 `onIdle`）回收子进程，
  而不仅是有人轮询时——这也意味着 `process_list` 会及时显示 `exited(code N)`，
  而不是在被问之前一直显示 `running`。没有归属会话启动的进程（直接
  `process_start`，例如来自 `cli`），或其会话 runner 已经退场的进程，不会被告知
  任何人——请轮询。
- `process_list` 条目带 `started_at`（epoch 秒），因此客户端可以显示某物已运行
  多久（`bg 1 (7m)`）。
- 崩溃安全：子进程是进程组组长，因此被 SIGKILL 的组件会留下它们继续运行——
  `registry.json`（pid + /proc starttime，挫败 pid 复用）驱动一次引导清扫，在
  开始服务前杀掉前世遗留的孤儿。进程随 harness 一起死亡。

四个工具都是 on-demand（`discover`/`invoke`）。bash 工具的 `run_in_background`
标志是此组件之上的薄生产者：调用立即返回 id（不适用超时），记录行指向
`process_poll`/`process_kill`。若组件未运行，bash 回答 `[E_BACKGROUND]` 并建议
同步运行该命令。

## External MCP servers (`mcp`)

Status: **implemented**（manager + bridge + 发现集成；UI 界面只是同一批工具上的
薄客户端）。

Niffler 充当 MCP **客户端/宿主**：每个配置的外部 MCP 服务器（Model Context
Protocol）成为一个受监督的 bridge 进程，服务器的工具成为普通目录工具——可发现、
可调用，且像任何组件工具一样受审批门控。bridge 基于官方 Go SDK
（`github.com/modelcontextprotocol/go-sdk`）。

### Shape

```
store kind "mcp"（每个服务器一条记录）
        │ 由 mcp manager 持有（components/mcp）
        ▼
spawn {name: "mcp-<server>", binary: var/bin/mcp-bridge, args: ["--server", <server>]}
        │ 每个服务器一个受监督进程（经组件记录在重启后幸存；
        │ supervisor 在失败时重启它）
        ▼
bridge 宣告 mcp_<server>_<tool> schema  ──►  catalog ──► discover/invoke
        │
        └── 惰性 MCP 会话 ──► stdio 子进程 / streamable-http / sse
```

- **命名**：工具加前缀 `mcp_<server>_<tool>`（niffler 小写约定，在目录中全局
  唯一）；描述带 `[mcp:<server>]` 来源前缀。服务器名必须匹配
  `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`（≤32 字符，保留 `bridge`；每 harness
  ≤100 个服务器）；工具名清洗到同一字母表并截断到 64 字符。manager 拒绝生成的
  工具名与另一服务器或目录工具冲突的服务器。
- **暴露**：默认 on-demand（`x-harness.onDemand`）——schema 经
  `discover {component: "mcp-<server>"}` 进入会话，调用经 `invoke`，因此 MCP
  服务器永不膨胀冻结的直接工具集。`"expose": "direct"` 让某服务器的工具进入
  每个新会话的快照。
- **惰性会话**：添加服务器时用一次真实连接（initialize + tools/list）校验，并在
  记录中缓存工具清单；MCP 子进程/HTTP 会话本身在首次工具调用时启动，并在
  `idleMs`（默认 5 分钟；上限 24 小时）后空闲退出。每次调用获得按调用超时
  （`timeoutMs`，默认 120 秒，上限 24 小时）。引导 harness 从不为
  `npx`/`uvx` 启动付费。
- **取消**：MCP 工具声明 `x-harness.sessionId`——session runner 把活跃会话 id
  注入为 `__session.session`，被取消回合的 `cancel.mcp-<server>` 事件
  （docs/WIRE.md）立即中止在途 MCP 调用。直接调用方（CLI 脚本）得到 `""`——
  它们无法伪造会话，未被归属的调用只受 `timeoutMs` 约束。
- **密钥按引用**：`env` 值、`headers` 值、`args` 和 `url` 可以包含从 harness
  环境在 bridge 连接或启动服务器时解析的 `${NAME}` 引用——store 只保留占位符，
  列表只回显键名，缺失变量会让连接以明确错误失败，而不是发送空凭据。裸 `$`
  保持字面。
- **沙箱**：stdio 服务器在 guard 进程（`mcp-bridge --stdio-guard <cmd>`）下运行，
  guard 拥有服务器的进程组并监视一条生命线管道——bridge 死亡（含 SIGKILL）时
  guard 先 SIGTERM 再 SIGKILL 整组；内核 `PDEATHSIG` 又为 guard 兜底，因此 MCP
  服务器绝不会比其 harness 活得更久。stdio 服务器继承固定的环境白名单
  （PATH、HOME、TMPDIR、USER、SHELL、LANG、TERM）——harness 环境中的 `NIF_*`
  变量和密钥永不触及它们。HTTP/SSE 服务器只看到配置的 `Authorization` 头，且仅
  当它指向服务器自身源时——凭据绝不重放到跨源重定向目标（重定向被拒绝）。
- **结果大小**：≤64 KiB 的 MCP 结果内联返回；更大的溢出到
  `$NIF_ROOT/var/mcp-results/result-*.json`，工具返回短预览加文件路径（可用
  niffler_edit、niffler_grep 或 bash 读取），而不是撑爆上下文窗口。
- **漂移**：每个新会话（以及服务器推送的
  `notifications/tools/list_changed`）时 bridge 重新列出服务器的工具；契约移动
  时它持久化新鲜清单（尽力而为，rev 重试）并以退出码 3 退出，让 supervisor
  重启它宣告当前真相。目录和执行不会长期不一致。
- **隔离**：每个服务器一个进程；挂起或崩溃的服务器无法拖垮其他服务器
  （supervisor 的失败退避会重启它）。服务器被移除后，其工具在已有会话中保留
  冻结 schema——调用随后经正常路由失败。

### The record

每个服务器一个 store 文档（kind `mcp`，id = 清洗后的服务器名；`mcp_servers`
列出它们并把 env/header **值脱敏**）：

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

`type` 选择传输：`stdio`（默认；`command`+`args`+可选 `env`/`cwd`）、`http`
（streamable HTTP；`url`+可选 `headers`）或 `sse`（`url`+`headers`）。
`approval: "always"` 用人工审批提示门控该服务器的每个工具；`effect: "read"`
把工具标记为只读供 fabric 调度；`concurrency: "serial"` 用于无法处理重叠调用的
服务器（默认 `parallel`，经 SDK 有界的 `ToolConcurrent`）。manager 拥有除
`tools` 之外的每个字段——bridge 只在服务器漂移时重写该缓存。

### Tools

都在 `mcp` 组件上，全部 on-demand；写操作需审批：

| 工具 | 效果 |
|---|---|
| `mcp_servers` | 列出记录 + 实时 bridge 状态（已注册工具、会话状态、最后错误） |
| `mcp_add` | 用一次真实连接校验（经 bridge 的 probe 模式——配置在 stdin，不上总线），存储带缓存工具清单的记录，启动 bridge。校验超时：30s 或 `timeoutMs` 中较大者（`NIF_MCP_PROBE_TIMEOUT_MS` 覆盖）——`npx`/`uvx` 服务器的首次运行会下载包 |
| `mcp_edit` | 合并提供的字段，重新校验，重启（禁用时停止） |
| `mcp_remove` | `core.remove` 该 bridge（引导时不会复活）+ 删除记录 |
| `mcp_refresh` | 强制 bridge 丢弃会话、重连并立即重新列出 |

因此添加 MCP 服务器按设计会请求两次审批：一次是 `mcp_add` 本身，一次是它触发
的 `core.spawn`——改变 harness 形态上的人工门控（docs/ARCHITECTURE.md）。

### Prompts, resources, registry

- **Prompts 变成斜杠命令。** 每个服务器 prompt 注册为隐藏目录工具
  `mcp_<server>_prompt`（LLM 不可见，`x-harness.hidden`）加一个斜杠命令
  `mcp-<server>-<promptname>`，其命名参数镜像 prompt 的 arguments（每服务器
  ≤32 个 prompt，每个 ≤16 个参数）。渲染 prompt 是普通总线调用；结果把渲染文本
  作为 `userMessage` 携带，UI 把它作为**用户**消息追加到会话（斜杠结果约定，
  `ui/frontend/src/lib/slashResult.ts`）——prompt 输出绝不以 system/assistant
  内容注入记录。bridge 在漂移时像工具一样重新注册它们（含服务器推送的
  `notifications/prompt_list_changed`）。
- **Resources** 以一个并发工具 `mcp_<server>_resources` 呈现
  （`x-harness.effect: "read"`）：`{op: "list"}` 或 `{op: "read", uri: ...}`。
  文本结果遵循与工具结果相同的 64 KiB 内联上限（更大的溢出到
  `var/mcp-results`）；二进制 blob 以 base64 加 MCP mimeType 返回。
- **Registry**：`mcp_search <query>` 查询官方 MCP Registry
  （`registry.modelcontextprotocol.io`；用 `NIF_MCP_REGISTRY_URL` 覆盖），返回
  name/title/description/version 以及给 npm/PyPI 打包条目建议的 `mcp_add`
  配置——版本从注册表固定（`npx -y <id>@<v>` / `uvx <id>==<v>`）。只有当条目无需
  任何配置时才标记 `installable`；包 id 中的模板变量或声明的必需 env/headers
  以 `requirements`（“configuration required: ...”）呈现，而不是半填的配置。
- **漂移也覆盖 prompts**：`checkDriftLocked`（新会话）和两个 list-changed 通知
  都会重新列出工具*和* prompts；记录的缓存被刷新，bridge 以退出码 3 触发
  supervisor 重启。

### Verification

`tests/t_mcp.nim`（在 `make test` 中）：把一个无依赖的 fixture MCP 服务器
（`tests/fixtures/mcp_server.nim`，stdio 上的换行分隔 JSON-RPC）和一个 mock 注册表
（`tests/fixtures/mock_registry.nim`，纯标准库 HTTP）编译进私有沙箱，并演练整个
契约——add（含密钥脱敏）、bridge 注册、发现提示 + 完整 schema、惰性 invoke、
工具错误传播、飞行中取消（`cancel.mcp-<server>` 中止在途调用）、resources
list/read、prompt 斜杠命令 + 渲染、对 mock 的注册表搜索、服务器推送漂移
（持久化 + 重启 + 重新发现）、edit/respawn、用于引导恢复的 spawn 参数持久化，
以及移除。两个回归测试钉住进程卫生修复：被 SIGKILL 的 guard 不得留下孤儿 MCP
服务器（内核 `PDEATHSIG`），失败的 add 不得留下记录。Go 单元测试（`make gotest`）
覆盖 SDK 的冻结注册门（`Announce` 在迟注册时 panic；ready 后的调用以
`not-ready` 失败）、名称/契约校验、注册表形态解析、传输凭据/重定向规则，以及
取消管线。

## Progressive tool discovery

Status: **implemented**。

Niffler 保持一个完整的全局目录，同时向每个会话暴露一个小而不可变的工具集。
额外的 schema 通过 `discover` 进入只追加的消息历史；对这些工具的调用走固定的
`invoke` 网关。这减少了提示词膨胀，又不削弱 core 的审批或超时策略。

### Model

#### Existence is global; exposure is per conversation

组件在总线上存活即存在。`reg.publish` 把它的所有工具插入 core 的目录；
`reg.depart` 或 supervisor 清理会移除它们。`var/bin` 下的二进制在 manifest
autostart、`core.spawn` 或插件安装启动它之前是惰性的。

暴露是另一回事：

| 级别 | schema 元数据 | 直接 LLM schema | 发现 | 调用 |
|---|---|---|---|---|
| direct | 无 `x-harness.onDemand` | 进入新会话快照 | 提示 + schema 查找 | 直接或 `invoke` |
| on demand | `x-harness.onDemand: true` | 省略 | 提示 + schema 查找 | `invoke` |
| hidden | `x-harness.hidden: true` | 省略 | 省略，含显式查找 | 仅组件/core |

两者同时存在时 hidden 优先。暴露不是 ACL：完整目录仍是路由的权威。面向 LLM 的
`invoke` 网关拒绝隐藏目标，而组件仍可直接经 NATS 请求隐藏工具。

#### Full catalog and projections

- `catalog {op: "snapshot"}` 返回完整组件注册和 schema。session runner 从它
  播种本地目录。
- `catalog {op: "components"}` 返回 CLI 使用的完整组件→工具名映射。
- `catalog {op: "list"}` 返回当前按名称排序的、面向*新*会话的直接投影。它不是
  已有会话的工具集。
- 分发、审批、`x-harness.timeoutMs` 和组件间调用始终查询完整目录。

### Core tools

`discover` 和 `invoke` 是每个新会话中的直接 core 工具。`profile` 是管理命名
工具配置的 on-demand core 工具；`session.profile` 在会话首次创建时选择一个。
Web UI 或 TUI 中的 `/profile` 设置 `/new` 使用的客户端默认值。
`session_info`（onDemand）总结会话（头字段、按角色消息计数、累计 completion
token）；`prompt_preview`（onDemand）展示组合请求的来源——系统提示词来自哪里、
多少个项目上下文文件喂给它、冻结的直接工具名 vs. 目前已发现的 schema、
消息/token 计数——而不发送任何东西。`doctor`（onDemand）是一次性机器可读健康
报告：store 可达性、llm 注册、active provider、systemprompt 是否存在、目录大小、
会话数，外加自检扇出——每个注册了标准 `selftest` 工具（docs/WIRE.md）的组件都会
被要求自检，其逐项结果收集进报告（未实现的组件列为未实现）。`deep: true` 时
探测变成实测——lsp 组件对一次性 fixture 启动每个已配置语言服务器（干净文件 →
0 诊断、hover 有答案、坏文件 → 错误），store 对其引擎做完整的 put/get/rev/list/del
往返。快速模式保持廉价（仅二进制解析）；适合作为 CI 存活门或第一步诊断。UI 把它
暴露为 `/doctor`。报告还带一份渲染好的 Markdown 表（`text`，即 `/doctor` 显示的
内容），`ask: true` 会加一条 `userMessage`（docs/WIRE.md 约定），让客户端把解读
请求作为用户回合提交。

#### Explicit client commands

聊天客户端无需 LLM 回合即可暴露同样的目录状态：

- `/components [all|direct|discovered|undiscovered]` 列出活跃组件并按当前会话中
  每个工具的暴露状态过滤。`direct` 表示 schema 在请求的 tools 数组里；
  `discovered` 表示它已在历史中、可通过 `invoke` 调用；`undiscovered` 表示它
  存活但尚未暴露给本会话。
- `/discover COMPONENT` 或 `/discover tool=NAME` 执行显式发现请求，并把返回的
  schema 记录进会话的持久化发现摘要。它不把工具提升进直接数组；想要直接 schema
  暴露时，在 `/new` 用配置，或 `invoke` 时带 `sticky: true`。
- `/profile NAME` 为新会话选择命名配置；`/profile default` 清除选择。改变它
  绝不改写已有会话的冻结暴露。

Web 的 Components 面板提供相同的 all/direct/discovered/undiscovered 过滤和文本
搜索。隐藏工具保持内部，`/discover` 永不列出。

#### Hints

```json
{"query": "web"}
```

`query` 可选，大小写不敏感地匹配组件名、工具名和描述。多词查询是合取：每个空白
分隔的词都必须出现在组件名或工具名/描述中——像 “mechanical fan-out” 这样的
关键词短语即使没有描述逐字包含它也会匹配。空查询返回只带工具名的总线目录；
`component` 和 `tools` 调用返回完整描述和 schema。结果是确定性的：组件和工具按
名称排序，描述是规范化单行提示，截断到 200 字符，易变字段如 pid 和注册时间被
排除。

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

`discover {component: "fetch"}` 返回该组件的 direct 和 on-demand 提示。没有
非隐藏工具的组件被省略。

#### Schemas

只请求下一步需要的工具，一次最多 16 个：

```json
{"component": "fetch", "tools": ["fetch"]}
```

结果包含规范化完整 schema，按工具名排序：

```json
{
  "component": "fetch",
  "tools": [
    {"name": "fetch", "schema": {"type": "object", "properties": {}}}
  ]
}
```

未知和隐藏工具请求的错误形状相同，因此发现不是隐藏工具的存在性预言机。

不带 `component` 的 `tools` 搜索每个活跃组件——调用方常常知道工具名但不知道
归属。返回的每个 schema 随后携带归属 `component`，没有可发现工具的名称列在
`notFound`（空的 schema 集还是错误，会点名请求的工具）。

#### Invocation

通过固定网关调用已发现的 schema：

```json
{
  "tool": "fetch",
  "arguments": {"url": "https://example.com"}
}
```

`invoke` 递归进入正常的 `dispatchToolCall` 路径。目标工具的审批对话框、超时、
组件路由和错误因此与直接调用完全一致。它也能触达会话启动后新注册的、当时还不
存在的非隐藏工具。

### Session state and caching

提供商提示词缓存包含顶层工具定义。把已发现的具象 schema 加到后续 `tools` 数组
会改变前缀并使累积缓存失效。只把 schema 作为工具结果返回是只追加的，但模型仍
需要一个声明的函数来调用它；这就是 `invoke` 固定且通用的原因。

首个回合，session runner：

1. 计算 `Catalog.promptTools()`；
2. 把确切有序的 schema 存到 store kind `session`、id
   `<sessionId>:tools`；
3. 在每次 LLM 轮次和 runner 重启后都使用该快照。

文档形状：

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

`direct` 携带 schema，因为它是 resume 安全的提供商快照。`discovered` 是供检查
和 UI 状态用的持久化摘要；schema 本身存在于持久化的工具结果消息中。只有成功的
全 schema `discover` 调用会更新它。提示搜索和失败查找不会。

组件注册变动绝不改变已有会话的直接数组。后来的组件通过 `discover` 找到、经
`invoke` 调用。若一个直接组件离场，其冻结 schema 留在该会话中以求缓存稳定；
调用经正常路由失败，当前发现会反映它已消失。

### Shipped policy

完整出厂 manifest 下，有 7 个直接工具：

- Core：`discover`、`invoke`。
- 例行工作：`bash`、`grep` 和文件工具 `read`/`edit`/`write`（`edit` 组件）。

长尾是 on-demand：

- 搜索和检查：`files`（排序列表）、git 工具、`undo_last_edit`，以及
  observe/logfile 诊断。
- 状态和内省：store `get`/`list`、`session_info`，以及技能入口
  `skill_list`/`skill_load`（只在合适时加载工作流指南）。
- 编排：`fabric`、`agent_*` 工具、`expert_follow`。
- Core 生命周期/状态/目录、builder、plugins 和 fetch。
- Models 和 provider 管理。
- 技能资源、在线搜索、安装和移除。

内部工具保持隐藏：core `session`/`session_prepare`、store `del`、LLM
`chat`/`llm_resolve`、systemprompt prompt，以及带凭据的 provider 工具
（`provider_update`、`provider_use_environment`、`provider_status`、
`provider_active`、`provider_get`）。Store 的 `put` 是 on demand（它携带
`x-harness.sessionId` 用于冻结工具集快照）。

缺少 `onDemand` 元数据仍视为直接，以兼容第三方。会话启动后 spawn 的组件仍不会
改变该会话的冻结直接数组；discover/invoke 是新能力握手的途径。

### UI

Live Components 面板把全局 `core.status` 数据与活跃会话的暴露文档结合。工具
chip 用文本加颜色：

- `direct`：在不可变提供商工具数组中；
- `seen`：其 schema 已在本会话成功发现；
- `demand`：存活且非隐藏，但未在本会话暴露；
- `internal`：对 LLM 隐藏。

组件存活是单独的状态点。面板在会话选择、目录变化、发现/完成事件、重连和周期
轮询时重载。删除会话也会删除其暴露文档。

### Verification

`tests/t_discover.nim` 是端到端契约。它证明确定性投影和发现、完整目录保留、
隐藏不泄露、经 invoke 的审批与超时保持、实际的 session-runner LLM 负载、迟
注册下的不可变行为、schema 在消息历史中的持久化，以及持久的 UI 暴露元数据。

用 `make test-discover` 单独运行；它也是 `make test` 的一部分。

---

## Model catalog (`models`)

`models` 组件是 Niffler 可替换的提供商/模型元数据平面。它不属于 core，也不是
通用推理适配器。它回答存在哪些提供商和模型、如何寻址、支持什么、以及限额和
价格。`llm` 组件仍然拥有实际 wire 协议、认证流程、请求变换和流式。

设计借鉴了 Pi 和 OpenCode 中有用的共同形态：

- models.dev 是广泛的精选基线。
- 一个小型内嵌种子让首次离线引导即可用。
- 最后验证过的下载被原子写入，失败时保留。
- 修正和提供商发现是确定性层，不是对下载文件的编辑。
- 用户提供的模型 id 严格解析；含糊的裸 id 绝不按目录顺序选择。

### Merge order

有效目录按此顺序重建：

1. `NIF_MODELS_PATH`、缓存的 models.dev 目录，或内嵌种子。
2. 已注册的 `x-models-source` 插件，按 `priority` 升序、再按
   `component/tool`。因此更大的 priority 胜出。
3. `NIF_MODELS_OVERRIDE`，总是最后。

插件和本地层是 JSON Merge Patch（RFC 7396）：对象合并，数组和标量替换，`null`
删除键。完整的 models.dev 形态被保留，包括 Niffler 尚未使用的字段。

组件在启动时和每小时刷新。models.dev 下载在其缓存年龄小于五分钟时跳过。HTTP
抓取有界、重试、校验（没有可用模型条目的目录被拒绝，因此畸形响应无法替换
last-known-good 缓存），并原子重命名进 `var/models/api.json`。每个已注册插件
来源也有一份 last-known-good 补丁在 `var/models/sources/` 下；来源暂时失败时
使用该补丁，但仅在该来源组件仍注册期间。本地覆盖在文件于重写中途不可读时保留
上一份补丁。失败的刷新会自动重试（30 秒或配置的间隔，取更早者），因此没有
`reg.depart` 的崩溃对账不会拖到下一个小时 tick。`ev.sys.drain` 取消刷新工作并
关闭组件。

### Tools

| 工具 | 用途 |
|---|---|
| `models_providers` | 提供商连接元数据和配置状态，绝不含密钥值 |
| `models_list` | 带能力、模态、限额和成本的过滤模型搜索 |
| `models_get` | 供其他组件使用的精确提供商/模型描述符 |
| `models_resolve` | 严格的 `provider/model` 或全局唯一裸 id 解析 |
| `models_refresh` | 排队刷新 models.dev 和每个活跃扩展来源 |
| `models_sources` | 来源、新鲜度、过期回退和错误诊断 |

`models_list {status: "active"}` 也匹配 status 字段缺失的模型（models.dev 对正常
模型省略它）。列表结果在会超过总线负载限制时被裁剪，单个过大的描述符会报错而
不是在 wire 上超时。描述符元数据递归脱敏：类密钥键（api keys、tokens、
passwords、credentials、authorization headers、private keys、cookies）绝不到达
调用方，无论在提供商还是模型层。

实时来源：models.dev 是元数据权威（限额、定价），但提供商实际提供的 id 来自
提供商自身。存在两个互补接口——`provider` 组件的 `provider_models` 工具用已存
或显式凭据按需探测端点（连接表单），而 `llm` 组件注册一个 `x-models-source`
插件（priority 150），其补丁添加每个提供商被观察到提供的 id（chat 之后后台
探测，10 分钟 TTL），使整个目录收敛到端点实际列出的内容。两者都是尽力而为：
失败绝不影响 chat 或目录基线。

`llm` 向 `models_get` 询问所选模型的上下文窗口。显式提供商 `context` 和
`NIF_OPENAI_CONTEXT` 仍然优先，若移除 `models`，现有小型回退仍可用。提供商端点
按主机名分类，而不是 URL 子串。交互客户端应调用隐藏、无凭据的
`llm_resolve {model?}`，而不是重复这套优先级：它报告有效全局 provider、可选的
会话模型覆盖、catalog、context，以及每个值的来源。

### Source plugins

模型来源是 `plugins` 安装的普通组件。一个隐藏工具携带此注册扩展：

```json
{
  "x-models-source": {"version": 1, "priority": 200},
  "x-harness": {"hidden": true}
}
```

`models` 从 `reg.publish` 和 core 的完整目录快照中发现带标记的工具，因此组件
引导顺序无关紧要。它以 `{"version": 1}` 调用该工具。结果是 JSON Merge Patch
（RFC 7396）：

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

完整的可工作来源组件示例——标记、工具、包布局和验证——见
[MODEL_SOURCES.md](MODEL_SOURCES.md)。

把来源放进普通 `niffler.json` 包。安装、更新、移除、进程隔离和持久化都已由现有
`plugins` 和 core 生命周期处理。移除来源组件会立即从有效目录移除其补丁。core
不添加任何模型专属扩展机制。

### Configuration

配置变量（`NIF_MODELS_*`）列在上面的主 [Environment variables](#environment-variables)
表中。

组件只报告提供商使用哪些凭据环境变量名以及是否设置了其中一个。它绝不返回凭据
值。提供商专属 OAuth、环境凭据、header、请求变换和原生 API 行为属于推理适配器
组件，它们可以独立于本目录以插件形式出厂或安装。

---

## System prompt (`systemprompt`)

Status: **由 `systemprompt` 组件 implemented**。

### Boundary

系统提示词不是 LLM 调用的工具——它是每个会话起始时遵循的常驻指令集。它住在组件
里，不在 core：core 只保留最小的结构性回退，session runner 每个会话从
`svc.systemprompt.call` 获取真正的宪法一次。替换宪法是普通 Niffler 操作：写一个
在同一主题上应答的组件，`build` 它，`kill` 旧的，`spawn` 你的。agent 可以对自己
这么做。

### How it works

- **每会话冻结。** 解析出的提示词在首个回合持久化进会话头（`systemPrompt`
  字段），并在任何 runner 进程的每次恢复中原样复用。提示词前缀保持稳定，因此
  提供商复用缓存；中途死亡或变化的组件绝不改写运行中会话的指令。
- **回退。** 组件缺席、缓慢（500 ms 探测，目录说它已注册时改为 8 s 预算）或
  损坏 → core 内置的最小提示词。core 绝不硬依赖组件来引导。
- **上限。** 应答在两侧都截断于 200 KB。
- **Agent 预取。** `agent` 组件在子代理子会话的首个回合前为其请求提示词，并经
  session 调用的 `systemPrompt` 字段传入（尽力而为——runner 自己的回退覆盖组件
  缺失）。

### The default component's prompt assembly

1. `components/systemprompt/baseprompt.txt` —— 产品提示词（自扩展阶梯、SDK
   示例、仓库布局），做 `$ROOT` 替换，编译期经 `staticRead` 烘焙进二进制。编辑
   它 = 重建 + 重启；没有运行时文件依赖。
2. 仓库的本地上下文文件，Pi 风格，包在 `<project_context>`/
   `<project_instructions path="...">` 标签里，位于产品提示词之后：
   - 每目录首个命中胜出：`AGENTS.override.md`、`AGENTS.md`、`AGENTS.MD`、
     `CLAUDE.md`、`CLAUDE.MD`（每目录一个文件——`AGENTS.md` 遮蔽旁边的
     `CLAUDE.md`；跟随符号链接）；
   - 从会话 cwd 向上到 `/` 的祖先遍历，harness 根优先，按路径去重——越靠近
     cwd 的文件越晚出现，因此最具体的指令是模型最后读到的；
   - worktree 遮蔽规则：harness 根是主仓库下的 `git worktree` 时，跳过主仓库
     根的上下文文件——否则祖先遍历会把同一逻辑仓库范围应用两次。
3. 每会话的 `<workspace>` 尾巴，仅在会话 cwd **不是** harness 根时追加：它点名
   工作目录（相对路径从它解析）和 harness 根，使 `docs/`、`components/` 和
   `sdk/` 从根外工作区也能按绝对路径解析。上面的冻结头要么有要么没有路径——
   根是每会话事实，在同一台机器上每个会话都一样，因此提供商缓存前缀仍然对齐。

该工具是 `x-harness.hidden`——它绝不出现在 LLM 工具集中；它是基础设施，只有
core 和组件可达。

## Observation and logs

Status: **由 `observe` 和 `logfile` 组件 implemented**。

### Boundary

观察总线，而非组件内部。两个组件都是基于 SDK 的普通 NATS 公民；core 从不导入
它们。唯一的 core 集成是可选的 nats-server HTTP 监控：core 拥有总线时分配第二个
loopback 端口，并在服务器就绪后写 `var/nats-monitor-url`。

观察是一项管理能力。总线捕获可能包含工具参数、模型输出、审批和来自每个会话的
数据。Niffler 当前的信任模型是单一可信用户/管理员；不要把 observe 服务或捕获
目录暴露给不可信的总线客户端。

### `observe`: bounded live inspection

`observe` 有一个原始 `>` 订阅。它保留原始 JSON 节点，包括未知信封字段和裸注册
负载。畸形 JSON 在 UTF-8 有效时保留为 `{raw, decodeError}`；任意字节改用无损
`rawBase64`。超大消息以有界 base64 预览表示，而不是让一条消息吃掉进程。

全局环形缓冲同时受消息数和近似 wire 字节约束。每个定向探测有独立的条数和字节
上限；探测数量也有上限。已停止的探测在 `observe_remove` 释放其内存前仍可查询。

| 工具 | 用途 |
|---|---|
| `observe_subjects` | core 可达时列出权威组件/服务视图、已知事件模式，以及最常观察到的具体主题 |
| `observe_listen` | 为词法正确的 NATS 模式（`*` 和结尾 `>`）加可选正则启动有界捕获 |
| `observe_trace` | 捕获对某组件的调用并按信封 id 关联结果/错误收件箱回复 |
| `observe_probes` | 检查探测状态、保留字节、上限和在途 trace |
| `observe_stop` | 冻结探测同时保留其条目 |
| `observe_remove` | 删除探测并释放其内存 |
| `observe_events` | 按时间/kind/component/subject/正则过滤，以最新优先查询探测或全局环形缓冲 |
| `observe_logs` | 在内存中查询最近的 `ev.log.*` 事件 |
| `observe_dump` | 需审批，把单个探测导出到 `NIF_OBSERVE_CAPTURE_DIR` 之下；不接受任意输出路径 |
| `observe_monitor` | 读取 nats-server 连接/订阅计数和最常订阅模式 |
| `observe_send` | 向具体的 `ev.*` 或 `llm.cancel.*` 主题发布事件；需审批 |
| `observe_request` | 对具体 `svc.*.call` 的诊断请求/应答；需审批且限制 30 秒 |

`observe_send` 不能发送 call/result/error 信封或注册。`observe_send`、
`observe_request`、`observe_monitor` 和会改文件的 `observe_dump` 带
`x-harness.approval: always`，因此 LLM 路径必须通过 core 的人工门。
直接与 `svc.observe.call` 对话的客户端已经是可信总线对等方，绕过 core 策略，
正如它可以直接调用任何其他服务主题。生成的捕获按最旧优先修剪到字节配额和
256 文件上限。

Trace 请求在 60 秒后从待关联表过期。探测主题、标签和正则输入有固定上限；超大
探测条目被丢弃并计数，而不是保留在字节预算之外。工具响应在 wire 约 64 KiB 的
内联结果约定之前停止并报告 `truncated`（或大型诊断回复的值字节元数据），而不是
返回无界数据。

### `logfile`: rotating JSONL persistence

`logfile` 是尽力而为的进程本地持久化，不是审计日志。Core NATS 是至多一次：
启动前或重启期间发出的事件会丢失。保证重放需要显式的 JetStream 设计。

默认输入是 `ev.log.>`。合法的组件名得到单个文件：

```text
var/logs/bash.jsonl
var/logs/bash.jsonl.1
...
```

`NIF_LOGFILE_SUBJECTS` 可以选其他主题。非日志流量（包括全总线 `>`）进入单个
`bus.jsonl`；因此动态收件箱主题不会产生无界的文件描述符或文件名。组件日志文件
数有上限，超出的/伪造的组件主题也回退到 `bus.jsonl`。多个配置的模式视为一个
本地过滤的并集，因此重叠模式对每条匹配发布恰好持久化一次。

每行记录写入时间与原始 wire 数据：

```json
{"receivedAt": 1780000000.25, "subject": "ev.log.bash", "message": {"v": 1, "id": "...", "kind": "event", "payload": {"level": "info", "msg": "..."}}}
```

畸形 UTF-8 输入使用无损 `rawBase64`；文本型畸形输入使用 `raw` 和
`decodeError`。落盘对每条记录打开、追加、刷新、关闭。轮转在重命名已关闭文件前
比较 `当前大小 + 记录大小`，因此恰好边界的写入不会留下过期文件句柄。大于配置
文件大小的单条记录被保留为活跃文件，并在下一条记录前轮转。
`NIF_LOGFILE_KEEP=0` 不保留任何轮转代。

`logfile_search` 只从保留文件读取有界尾部，把匹配记录按 `receivedAt` 最新优先
排序，并报告 `truncated`、`scannedBytes`、畸形行计数和读取错误。结果也有编码后
的响应字节预算。结构化日志记录暴露 `component`、`level`、`msg`、`ctx` 和可选
的 emitter 时间；原始总线记录暴露保留的消息。搜索绝不相信 emitter 提供的时间戳
来决定 `since`/`until` 窗口。目录枚举受 `NIF_LOGFILE_DIRECTORY_ENTRIES` 限制，
文件更多时报告 `directoryTruncated`；搜索仍检查有界子集。

`logfile_paths` 报告有界的保留文件列表加 `writeErrors`、`lastError` 和
`lastErrorAt`。文件系统失败也会写 stderr。在平台允许时捕获目录仅用户可访问；
活跃符号链接目标被拒绝。

### SDK APIs

三个 SDK 都暴露相同的观察/日志和原始信封 API：

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

每个 SDK 都让 NATS 做主题匹配，并且只把消息派发给投递它的订阅所绑定的 handler。
这避免了以前的叉积：一次调用可能经 call、event 和 tap 路径重复投递。Nim 保持
无回调、无线程；Go 使用已有的互斥锁，TypeScript 用 promise 链。Go 等待排空的
订阅回调（到其有界关闭宽限），TypeScript 等待排队的 handler，且不会死锁显式
关闭自己组件的 handler。

#### Idle work (`onIdle`)

三个 SDK 都暴露相同的*空闲接缝*——为没有请求能承载的工作准备的回调（回收后台
子进程、健康探测、缓存刷新）。`components/processes` 用它来在无人轮询时察觉后台
子进程退出，这正是其退出通知得以实现的原因。

```nim
proc onIdle*(c: Component, intervalMs: int, handler: IdleHandler): Component
```

```go
func (c *Component) OnIdle(interval time.Duration, handler func(*Component)) *Component
```

```ts
comp.onIdle(intervalMs, handler)
```

API 是镜像的；*执行模型*是各运行时自己的，因此契约按 SDK 分别陈述：

| SDK | 运行于 | 互斥 |
|---|---|---|
| Nim | pump 循环，在遍历之间 | 绝不在 handler 运行时——该循环是串行的 |
| Go | 自己的 ticker goroutine | 取串行 handler 锁；`ToolConcurrent` handler 只持读锁，因此可与它们重叠 |
| TS | promise 链，像每个 handler | 绝不与其他 handler 交错 |

三者共同点：在 connect/run 之前注册，每组件一个 handler（第二次注册替换第一次），
间隔下限 10ms，定时器随连接启动、随关闭停止，idle handler panic 会被记录、
绝不致命。只要“每 N 秒”就是全部需求，优先用它而不是组件线程。

Nim 的任意信封请求辅助函数在等待期间只继续泵原始 tap 订阅。Tool 和 event
handler 保持不嵌套，而观察者可以在 `observe_request` 期间为目标请求和应答打
时间戳。Trace 时长和过期使用单调时钟；显示的 `at` 值仍是墙钟 epoch 秒。

结构化日志在确切主题 `ev.log.<component>` 上发布事件，带
`{component, level, msg, ctx?, at}`。级别为 `debug`、`info`、`warn` 和 `error`。
`NIF_LOG_LEVEL` 默认 `info`，并在每个 SDK 中于发布前压制更低级别。发出的非法
级别会失败；非法阈值回退到 `info`。

### Monitoring

core 自行启动 nats-server 时使用不同的 loopback 客户端和 HTTP 端口，然后写入
（二进制是 `components/nats` 构建出的组件 `var/bin/nats-server`，若不存在则用
PATH 上的 `nats-server`）：

```text
var/nats-url
var/nats-monitor-url
```

监控发现文件仅在客户端连接成功后写入。复用或远程总线没有可发现的 HTTP 端点；
显式配置 `NIF_OBSERVE_MONITOR_URL`。`NIF_NATS_SPAWN=1` 强制在随机端口启动 core
独占的隔离总线（主要用于测试和诊断）——绝不用 4222；环境里显式的
`NIF_NATS_URL` 优先。

`observe_monitor` 每次请求用新的 HTTP 客户端读取 `/subsz` 和 `/connz`。它报告
订阅详情是否被截断；`mostSubscribed` 指订阅者密度，不是消息吞吐。

所有 `NIF_OBSERVE_*`、`NIF_LOGFILE_*` 和 `NIF_LOG_LEVEL` 变量都列在上面的主
[Environment variables](#environment-variables) 表中。

所有上限在启动时校验；非法配置以非零退出，而不是静默替换为默认值。

### Verification

`tests/t_observe.nim` 覆盖精确一次 tap、通配边界、注册捕获、上限/字节淘汰、
诊断请求期间的单调 trace 关联、畸形调用回复、超时行为、内嵌 NUL 和无效 UTF-8
原始数据、响应边界、审批元数据、按配额修剪的安全 dump、监控发现和非法配置。

`tests/t_logfile.nim` 覆盖 SDK 日志过滤、最新优先查询、时间/正则过滤、编码响应
和实际磁盘读取边界、精确一次重叠主题模式、已关闭文件轮转、零保留、内嵌 NUL
全总线保留、有界路径列表、sink 健康和非法配置。两个测试都使用隔离的临时输出
目录，且都是 `make test` 的一部分。

## Fabric and subagents

`fabric` 组件添加可编程工具调用：模型编写一个驱动 Niffler 工具自身的 Nim 程序，
只有程序的 `finish()` 值进入会话。`agent` 组件把会话变成子代理。完整设计和威胁
模型见 [research/FABRIC.md](research/FABRIC.md)（塑造它的外部评审：
[research/FABRIC_FEEDBACK.md](research/FABRIC_FEEDBACK.md)）。带提示措辞和可
工作示例的用户指南：[FABRIC_GUIDE.md](FABRIC_GUIDE.md)。

| 工具 | 做什么 |
|---|---|
| `fabric {code | name, tools?, strings?, timeoutMs?, maxCalls?}` | 运行一个 LLM 编写的 Nim 程序：`var/bin/fabric-exec` 把它编译进私有进程（无内嵌 VM；相同程序缓存在 `var/fabric-cache`）。`code` 是内联程序源码；`name` 运行模型策展的 `fabricprog` 库中的已存程序。带 `tools` 时，选定 schema 被钉住并生成编译期检查的 `tools.<name>(...)` 包装；allowlist 内的 `callTool` 仍是回退。只有 `finish(value)` 到达会话。获批的原生代码就是 bash 级信任，不是沙箱。 |
| `agent_run {task, session?, close?, fork?, model?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | 在子代理会话中运行任务并返回最终回复。不带 `session` 时启动**全新**子代理（自己的 runner、自己的循环）。带 `session`（此前返回的 `sessionId`）时给该**已有子代理再一个回合**——其会话、模型、thinking、工具和预算在首回合冻结，因此调用方的 model/thinking/tools/预算参数被忽略，结果报告子代理的 `effective` 控制；子代理必须属于本会话、未关闭、且不在回合中（否则以 `code: "busy"` 拒绝——改用 `agent_spawn` 排队）。全新运行的每作业可选预算：`maxRounds`（每回合工具轮数，1–`NIF_MAX_TURN_ROUNDS`）、`maxCalls`（工具分发总数，1-500）、`maxTokens`（累计 token）——耗尽会让回合以 budget-exhausted 失败结束。`close: true` 在本回合后使子代理退场（不删除任何东西；后续继续会被拒绝）。 |
| `agent_spawn {task, session?, close?, fork?, model?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | 同样任务在后台启动；立即返回 `{jobId, sessionId}`。不带 `session` 时启动全新子代理；带 `session` 时为已有子代理**排队**另一个回合（冻结控制规则同 `agent_run`，但子代理在回合中也可以——该回合随后运行；只有血缘父会话可以继续）。`close: true` 在排队/后台回合结算后使子代理退场。`timeoutMs` 是作业预算：超过后该作业会在下次被观察时被取消（agent_stop 语义）。 |
| `agent_status {jobId}` | 非阻塞的持久化作业查询（running/done/failed/stopped + 回复或错误）。 |
| `agent_wait {jobId, timeoutMs?}` | 阻塞直到后台作业终态；迟到的等待读取持久化记录。 |
| `agent_stop {jobId}` | 真正取消运行中的作业：子代理的 LLM 请求被中止，其回合迅速结束，在途 bash 命令被杀（整棵进程树）。终态记录写 "stopped"。 |
| `agent_steer {session_id, message}` | 向运行中的后台作业回合注入消息（在 LLM 轮次之间排空）。 |
| `agent_list {scope?}` | 调用方的子代理名册，由持久化血缘推导：每个子代理一行，带 `sessionId`、`jobId`、`task` 和基于驻留的 `status`——`running`（正在工作）、`idle`（回合之间驻留）、`ready`（仅在存储中；**可恢复，不是已完成**）。`scope: "descendants"` 遍历整棵树（当前深度 1）。子代理结算时你会被通知，因此这是用于定位，不是轮询。 |
| `agent_notices {session?, peek?}` | 排空本会话待处理的子代理**结算通知**——每个结束、被停止或失败的后台子代理一条。通知会自动投递（见下文）；这里用于会话空闲期间到达的通知，`peek` 查看而不消费。 |

### Settlement notices

到达终态的后台子代理会告知其**父会话**，而不只是 UI（`ev.agent.done` 仅观察）。
通知是一条在任何投递尝试之前写入的持久化 `agentnotice` 记录，它是*指针*，
不是回复：

- 父会话回合运行中时，通知立即折入（steer 通道）为带结构标记的用户消息；
  would-stop 点也会排空通知，因此回合不能在最后一步收到结算时关闭
  （`NIF_AGENT_NOTICE_HOLD=0` 只禁用这一保持）；
- 否则父会话被**唤醒**：agent 组件启动一个唯一工作就是折入待处理通知的回合，
  因此结算无需人类询问即可见。唤醒受 `NIF_AGENT_WAKES`（默认 3 个连续唤醒
  回合；人类的下一条消息重置预算，`0` 禁用唤醒）约束。被拒绝的唤醒不持久化
  任何东西，父会话下一回合在回合顶部排空所有待处理通知（pull 通道）——模型
  无需轮询；
- 无论哪条通道，通知携带有界 `summary`、`replyBytes`（未截断长度）和
  `fullReplyIn: "agent_status"`，因为完整回复已经持久化在 `agentjob` 记录中、
  一次调用可达。

通知是尽力而为：store 或 agent 组件不可达只损失一条通知，绝不损失一个回合。

### Continuation (sessions with memory)

两个驱动都接受 `session`：此前返回的 `sessionId` 给该子代理另一个回合而不是
新建。子代理保留其会话——只发送新任务即可。授权是持久化血缘关系
（`sessionmeta.parent`），因此只有子代理自己的父会话可以继续它，每种失败都
显式拒绝：未知会话、根会话、外来的子代理、已关闭子代理和 store 不可达都返回
不同的错误，而不是静默启动全新子代理。

两个驱动的区别正是其承诺的区别：

- `agent_run {session}` 承诺**现在**给结果，因此回合中的子代理被拒绝
  （`code: "busy"`，点名 `agent_spawn`/`agent_wait`/`agent_status`）；
- `agent_spawn {session}` 承诺工作**会发生**，因此它排队——子代理的 runner
  串行化回合，下一个执行排队的那个。

继续是只追加历史：后续任务作为下一条用户消息持久化（无前言、无系统提示词），
因此子代理的缓存前缀存活。每个回合推进子代理的激活账本
（`sessionmeta.activations`，附 `firstActivationAt`），后台继续在 `agentjob`
记录上盖 `continued`/`activation` 章。`close: true` 在回合后使子代理退场
（`sessionmeta.closed`）——记录和记录文本幸存；只有进一步继续被拒绝。

### Delegation depth

`NIF_AGENT_MAX_DEPTH`（默认 **1**）限制委托可嵌套多深，在分发时通过遍历
`sessionmeta.parent` 链接求值。`0` 完全禁止委托。到达上限时 spawn 工具仍然
可见：被拒绝的启动返回点名限制和调用方深度的错误，让模型知道原因。把它提到
1 以上是刻意行为——子代理的同步 `agent_run` 由 agent 组件可重入地服务
（见 WIRE.md "Delegation depth"），而来自子代理的 `agent_spawn` 完全不需要
重入（后台作业从不持有 pump）。

### Fork (a child that has read the discussion)

`fork: true | {"lastK": n} | {"maxChars": n}`——仅用于**全新 spawn**（fork 是
出生，不是继续；`fork` + `session` 被拒绝）——在子代理首次请求前用本会话
**已完成回合**播种其消息日志，让子代理*读过*讨论而不是被告知。结果和
`session_info` 携带来源（`{source, uptoId, copied}`）。

- **切点是均衡且从 0 连续的**：只落在已完成回合边界——绝不切进工具轮中途——
  种子是能重放为合法提供商消息列表的最长记录前缀（每个 `tool_calls` 都有其
  tool 记录应答，没有孤儿 tool 记录）。尾部在途回合被排除；崩溃留下的悬空中途
  历史把 fork 截在那里（fail-closed 胜过复制不均衡前缀）。
- **预算按回合边界切**，并且丢弃一切的选择会 fail closed——空子代理看起来像
  成功，但那是错的。
- **不复制什么**：每条消息的 `usage` 计量（子代理的账目是自己的）、
  `summary`/`error` 角色记录（summary 是所复制原始记录的派生；error 记录是
  父会话的审计）、工具集快照（`<session>:tools`），以及头的控制字段——fork 是
  出生：调用方的 `tools`/`maxRounds`/… 参数从此调用冻结子代理的控制，而绝不是
  父会话的。
- **出生即冷**：子代理的首次请求未缓存地重放继承的历史；第二个回合起变暖。
  这是*判断*继承的代价，只有当前言否则不得不叙述上下文时才是正确取舍。不需要
  判断的大批搬运正是 `fabric` 的用途。

- **治理而非沙箱**：guest 在 bash 的信任类——人类批准程序一次
  （`x-harness.approval: always`）。每个嵌套调用穿过会话嵌套调用代理
  （`svc.session.<id>.tool`），重新进入单一分发门（审批、完整 schema 校验、
  截止时间）。执行器子进程不持有 NATS 连接，也没有凭据。
- **审批清单**：程序审批显示源码摘要、`var/approval-sources/<digest>.nim` 下的
  完整程序（权限 0600）、选定的工具和声明的预算。持久化自动批准按
  `fabric:<digest>` 键控——批准一个程序绝不覆盖另一个。
- **守卫**：代理拒绝隐藏工具和内部/递归接口（`fabric`、`agent`、`chat`、
  `session`、`invoke`、`session_prepare`）；每回合租约使过期请求失效；
  `maxCalls` 约束调用；`x-harness.noSpawn` 在分发时拒绝来自子代理的子代理
  spawn。
- **上下文经济**：中间结果绝不进入会话；过大的 `finish()` 值溢出到
  `var/fabric-artifacts/<run>.json`（权限 0600），工具结果指向该路径。
- **Guest API**：`import fabricguest` 提供结构化的
  `call(tool, JsonNode) -> JsonNode`、`batch`、`finish(JsonNode)`、`log`/`logg`、
  `stringArg`/`inputs`（外加遗留的 `callTool`/`j*` 字符串辅助函数）。
  `fabricmeta.nim` 把钉住的运行时 schema 变成输入类型化的包装；结果除非工具
  声明标量 `outputSchema`，否则是 `JsonNode`。`fabric_help` 工具从组件内部返回
  参考和示例源码，无需定位文件。可工作示例：`components/fabric/examples/`。
- **何时用哪个**：判断逐步进行的直接循环；机械的已知形态编排用 `fabric`；
  需要自己上下文的探索性子任务用 `agent_run`；混合程序可以调用 `agent_run`。

## Expert advisory peer (`expert`)

`expert` 组件是非交互的顾问同伴（设计：
[research/EXPERT.md](research/EXPERT.md)）。它并发跟随一个或多个工作会话——
用 `expert_follow {session_id}` 显式武装（需审批，默认关闭）——把每个被跟随
会话的 `ev.session.<id>.*` 事件看进一个有界的每会话内存当前回合帧，并询问 LLM 裁判
（一次无状态隐藏 `chat` 调用：固定缓存稳定的知识前缀 + 一条临时观察，无工具）
证据是否值得 steer。只有高置信度、点名活跃非隐藏工具的 steer 会被投递，经
回合绑定的 `svc.session.<id>.advise` 请求/应答接口：runner 仅在该确切回合仍在
运行时接受建议——迟到的建议被拒绝（`stale-turn`/`no-active-turn`），绝不排进
下一回合。被接受的建议作为带标记的用户消息折入
（`[Niffler advisor: expert] ...`），持久化，并在 `ev.session.<id>.advice` 上宣告。
裁判通道本身保持全局：一次只有一条判断在途、共享冷却、每会话最新状态合并。

| 工具 | 做什么 |
|---|---|
| `expert_follow {session_id, model?, provider?}` | 跟随一个会话（多目标：每个被跟随会话保留自己的帧、知识前缀、判断预算和每跟随指标）；重新跟随会重置其帧。`model`/`provider` 为该跟随覆盖判断调用。需审批。 |
| `expert_unfollow {session_id?}` | 带 `session_id`：丢弃该跟随。不带：丢弃所有跟随并扔掉它们的帧。 |
| `expert_reload` | 从实时目录重建每个被跟随会话的知识前缀（新的缓存纪元）。 |
| `expert_status {session_id?}` | 带 `session_id`：该跟随的帧、知识版本和每会话计数器（judgments、silences、steers、accepted、rejected、staleDrops、errors）。不带：被跟随目标加生命周期诊断。 |

设计不变量：工作会话绝不等待 expert（尽力而为、冷却、最新状态合并）；没有增长
的 expert 记录文本（每次判断都是无状态的）；fail closed（任何解析/校验/传输
错误都是沉默）；expert 绝不行动——它只建议，需审批的工作仍留给工作会话的人类门。

## Recovery

仓库是快照；`var/` 是可丢弃的构建输出。如果 agent（或 bug）弄坏了出厂组件
——覆盖了 `var/bin` 中的二进制、损坏了 spawned 组件记录，或自加组件在引导时
崩溃——以 recover 模式启动 Niffler：

```bash
make recover        # 先停掉一切，再 ./var/bin/niffler --recover
```

`--recover` 按顺序做三件事：

1. **从源码重建出厂二进制**（`make build`，回退到 `nimble all`）——修复被覆盖/
   损坏的 `var/bin/*`。
2. **清空 store 的组件记录**——没有遗留的持久化额外组件形态可供恢复。
3. 引导所请求的配置（通常是完整交互 harness；`--recover --minimal` 选择
   minimal 配置）。**会话和消息幸存**——只有组件形态被重置。

对于*源码*被破坏：

```bash
# 先停止 harness（关闭 UI，或 Ctrl-C ./var/bin/niffler）
git restore components/ core/ sdk/      # 或：git checkout -- .
make build
./var/bin/niffler                       # 或直接重开 UI
```

## The store

`store` 和其他组件一样——总线上的文档存储，带 `put` / `get` / `list` / `del`
和基于 rev 的乐观并发（`put` 接受 `expectRev`，不匹配时以 `rev-conflict`
失败）。core 使用的 kind：

| Kind | Id | 值 |
|---|---|---|
| `conversation` | `conv-<ts>` | `{createdAt, model, title}` —— 会话头（也携带冻结的系统提示词、模型/thinking 选择、每会话预算控制和 token 计量） |
| `message` | `<convId>:<seq>` | `{conversationId, role, content, ...}` |
| `component` | `<name>` | `{name, binary, policy, addedAt}` —— 引导时恢复的持久化形态 |
| `plugin` | `<pkg name>` | `{name, repo, ref, dir, version, components, addedAt}` —— `plugins` 组件的安装记录 |
| `provider` | nickname（外加 `active` 标记文档） | `provider` 组件的静态脱敏 LLM 提供商注册表 |
| `session` | `<sessionId>:tools` | 会话冻结的直接工具集快照（见 [Progressive tool discovery](#progressive-tool-discovery)） |
| `slash` | `slash` | UI 渲染的合并斜杠命令表（见 [WIRE.md](WIRE.md)） |
| `agentjob` | `<jobId>` | 持久化后台 `agent_spawn` 作业记录（继续会盖 `continued`、`activation`，并排队 `close`） |
| `agentnotice` | `<parentSession>:<seq>` | 子代理结算通知（摘要 + 完整回复的追索；`deliveredAt`/`deliveredVia` 标记投递） |
| `sessionmeta` | `<sessionId>` | 子代理血缘 / runner 元数据：spawn 时 `{parent}`；继续添加 `activations`（回合数，从 1 开始）和 `firstActivationAt`；`close: true` 退场设置 `closed` |
| `fabricprog` | 程序名 | 模型策展的 fabric 程序库（`fabric {name}` 运行其中一个） |

后端是所选引擎——默认 SQLite 位于 `var/store.db`，或 `NIF_STORE_BACKEND=barrel`
时 BitBarrel 位于 `var/barrel-db`。**有且只有一个进程拥有该文件**——绝不要对
同一数据库运行两个 `store` 进程（对同一根启动第二个 core 就会如此；实验请用
临时 `NIF_ROOT` 副本）。

## Testing

```bash
make test           # 完整门：前端测试，然后是总线契约套件
make test-server    # ... 仅服务端：每个测试一个测试自有 NATS，不用 node
make test-ui        # ... 仅前端：lib 单元测试 + `npm run typecheck`
make test-bash      # ... 或只跑一个：test-store、test-builder、test-console、
                 # test-plugins、test-skills、test-fetch、test-models、
                 # test-observe、test-logfile、test-core、test-cli、
                 # test-autostart、test-smoke
```

每个测试都引导真实组件二进制（Nim、Go *和* TypeScript——信封才是产物，所以
一个 harness 测试每个 SDK）并通过其 loopback 端口由 NATS 分配的私有 NATS 服务器
驱动它们。前端测试是例外：它们导入 TypeScript lib 模块
（`ui/frontend/src/lib/*.ts`）并在纯 node 上以类型剥离运行，因此 `make test-ui`
既不需要依赖也不需要总线（`npm run typecheck` 需要 `ui/frontend/node_modules`，
由 `make ui` 安装）。`make test` 就是 `make test-ui` + `make test-server`；
服务端工作用 `make test-server`，前端工作用 `make test-ui`。
基于 core 的测试把所需二进制快照进唯一临时 `NIF_ROOT`；Barrel、插件 clone、
生成组件、日志和缓存因此都被隔离。单独的 `make test-*` 目标可以彼此以及与运行中
的开发 harness 并发运行。仓库构建写入被串行化，而 agent 构建的测试组件使用
沙箱本地 Nim 缓存。网络可选项：`NIF_TEST_INSTALL=1` 运行真实的
`cli install gokr/niffler-weather` + 工具验证；`NIF_TEST_NETWORK=1` 运行针对
GitHub 的 `plugin_search`、针对 skills.sh 的 `skill_search`，以及 TypeScript
builder 构建（npm registry）。安装管线本身由 `t_plugins` 经本地 `file://` git
仓库封闭覆盖。Observe/logfile 测试使用临时输出目录，绝不删除开发者的
`var/logs` 或 `var/captures`。外部网络可选项即使本地状态隔离，仍可能共享提供商
速率限制。

## Starting and stopping

没有启动器脚本——二进制自己拥有生命周期：

- **桌面图标 / `niffler-ui`** —— 常见情况。bridge 的第一件事是 SDK 的
  `ensureHarness`：探测 `NIF_NATS_URL` → `var/nats-url` → 127.0.0.1:4222，寻找
  服务**本 root** 的 core（目录携带所属 harness 的 root；外来 clone 的 core
  绝不被采纳）；无人应答时，以 `NIF_AUTOSTART=1` 分离启动 `var/bin/niffler`。
  仓库根在 `make ui` 时经 ldflags 烘焙进去，因此安装的图标与树内二进制一样
  工作。
- **交互插件**（例如 `niffler-tui`）——它们**不**调用 `ensureHarness`，绝不
  启动 harness：它们探测实时总线（`NIF_NATS_URL` → `var/nats-url` →
  127.0.0.1:4222），连接并注册 `client: true`（这样 autostarted core 在它们
  运行期间保持存活）。先启动 harness——桌面 UI 或 `./var/bin/niffler`。
- **终端管理 shell** —— 直接 `./var/bin/niffler`，或
  `./var/bin/niffler --minimal` 用三组件引导配置。手动启动的 core 绝不自行
  终止；用 Ctrl-C / SIGTERM 停止它。

交互前端注册 `"client": true`（SDK 的 `interactive()` / `Component.Client`
标记）。**Autostarted** core 会数它们：最后一个离开后，它会在
`NIF_AUTOSTART_IDLE_S`（默认 10s——重启的 UI 在该窗口内重新注册）后关闭，
带走其组件和 spawned 总线；若从未有客户端到达，它在 `NIF_AUTOSTART_BOOT_S`
（默认 60s）后放弃。关闭附着到*手动*启动 core 的 UI 不改变任何东西——core
保持运行。`NIF_ENSURE_ATTACH=0` 让 `ensureHarness` 无条件启动（测试）。

## Common tasks

```bash
./var/bin/niffler             # 终端中的完整 harness（管理 shell）
./var/bin/niffler --minimal   # 引导时只要 store + bash + llm
niffler-ui                    # 桌面 UI；autostart 完整配置
make build          # 重建发生变化的部分
make install        # PATH 条目（niffler、niffler-cli、niffler-console，
                    # + 询问后安装 niffler-tui 包装脚本——绝不含组件
                    # 二进制，因此 PATH 不会遮蔽 grep/git/...）
make install-tui    # 同上，安静地安装 niffler-tui 终端客户端
                    # (= make install WITH_TUI=1)
make uninstall      # 再次移除这些 PATH 条目
make install-ui     # 构建桌面 UI，然后添加启动器条目 + 图标
                    # (Linux; = make ui-install; -uninstall 对应 ui-uninstall)
make install-lsp    # 安装 lsp 组件的默认语言服务器
make test           # 完整门：前端测试 + 总线契约套件
make test-server    # 仅总线契约套件（每个测试拥有自己的私有总线）
make test-ui        # 仅前端：lib 单元测试 + typecheck（无 NATS）
make doctor         # 检查前置条件
make ram            # 运行中各栈的 RAM（harness + 组件 + nats + 客户端）
make down-here      # 只停掉此 checkout 的 harness、组件和 spawned 总线
                    # ——bench worktree 和其他 clone 幸存
make clean          # 删除所有构建产物（var/、nimcache/、UI build）
```

- **无头服务模式**（无 tty，供 UI/自动化）：
  `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null`——
  服务 `svc.core.call`；需要审批的工具会被拒绝，除非有 UI 附着或设置了
  `NIF_AUTO_APPROVE=1`。
- **附着到任何总线**：`NIF_NATS_URL=nats://host:4222`（甚至远程），或先自行在
  默认端口启动 nats-server——core 复用 `127.0.0.1:4222` 上的实时总线，只在无人
  应答时启动自己的（构建出的 `var/bin/nats-server` 组件）。
- **不用 LLM 探测总线**：`tests/` 中的一次性 `nim c -r` 脚本
  （见 AGENTS.md "Debugging the bus"）。
- **Wails**：只用 `wails build -tags webkit2_41` 构建（Linux）；裸
  `go build` 会产出桩。`make dev` 在浏览器中运行 SPA，bridge 为桩。
- **监控 RAM**：用 `make ram`（或 `watch -n5 scripts/niffler-ram.sh`）：按栈
  统计——你的 clone、`nifflerprod` 和每个 bench 私有 harness 分开——harness +
  NATS + 所有 spawned 组件 + session runner + 客户端。成员按可执行文件路径
  （`*/var/bin/*`、`niffler-ui`）判定，而不是进程树：tui 是 autostarted harness
  的*父*进程，而 bench 运行的私有总线属于 bench 驱动，因此 PPID 遍历会两者都
  漏掉。读 PSS，不是 RSS：共享同一 `var/bin` 构建的栈会在 RSS 中重复计算文件
  支撑页。`bash` 工具的工作负载子进程（编译器、测试二进制）按设计排除。

## Troubleshooting

| 症状 | 原因 / 修复 |
|---|---|
| 桌面应用内 UI 显示 "Running in a browser" | `nats.ts` 绑定不匹配——`window.go.main.Bridge` 必须匹配 Go 结构体名（ui/README.md） |
| UI 横幅：bus unreachable | core autostart 仍在进行或失败——在终端启动 `./var/bin/niffler` 查看引导错误 |
| 引导时 `core: WARNING missing binary for <name>` | 运行 `make build` |
| llm error HTTP 401/403 | `NIF_OPENAI_API_KEY` 缺失或错误——检查 `.env` 和 shell 环境 |
| 无头模式下 "approval denied" | 预期行为：没有可达的人类。附着 UI，用 `make run`，或有意识地设置 `NIF_AUTO_APPROVE=1` |
| 两个 store 争抢同一数据文件（`var/store.db` 或 `var/barrel-db`） | 单写者规则——每个 root 只有一个 core；在临时 `NIF_ROOT` 副本中实验 |
| 引导拒绝："this harness has conversation history in var/barrel-db" | 默认引擎改为 SQLite 而你的历史仍在 barrel——运行 `niffler-store-migrate --root <path>`（错误会打印它），或设置 `NIF_STORE_BACKEND=barrel` 继续用旧引擎 |
| 孤立的 `nats-server` | 只有其 core 被 SIGKILL（退出 defer 被跳过）时才可能——杀掉 `var/nats-pid` 中的 pid，否则 `pkill -f nats-server` |
| 组件引导时崩溃、在退避循环中重启 | 经 UI/终端 `core.remove` 它，或 `make recover` |
| agent 改动了源码 | `git restore components/ core/ sdk/` 然后 `make build`（见 Recovery） |
