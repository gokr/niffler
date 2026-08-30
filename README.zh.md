# Niffler

[English](README.md) · 简体中文 · [繁體中文](README.zh-TW.md) ·
[Discord](https://discord.gg/ThJFEAJUAk)

Niffler（重生版）是一个极简、可自我扩展的 agent harness，理念上与
[Pi](https://pi.dev) 或新的 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
相近。但 Niffler 采用了完全不同的软件组合方式：Unix 风格的“组件即进程”，
以 NATS 作为通信平面。组件因此可以用不同语言编写、彼此严格隔离、
运行时重写与重启，甚至远程运行。

Niffler 的设计是把它 clone 出来、以自己的 git 仓库为“家”运行，从而可以自我扩展。

Agent 可以在运行时添加能力——写源码、用 `builder` 组件编译、
通过 `core.spawn` 启动——全程发生在对话中途。设计理由：
[docs/research/REBOOT.md](docs/research/REBOOT.md)。线上协议：[docs/WIRE.md](docs/WIRE.md)。

```
core (Nim) ── NATS ──┬── store (Nim SDK)           ← 持久化
                     ├── bash (Nim SDK)            ← shell 执行
                     ├── builder (Nim SDK)         ← 组件编译
                     ├── plugins (Nim SDK)         ← 组件生态
                     ├── skills (Nim SDK)          ← Agent Skills (SKILL.md)
                     ├── fetch (Nim SDK)           ← 网页内容抓取
                     ├── models (Go SDK)           ← 可插拔模型目录
                     ├── provider (Go SDK)         ← LLM 提供商注册表（持久化）
                     ├── llm (Go SDK)              ← 流式 LLM 适配器
                     ├── edit (Nim SDK)            ← 读写文件工具 + 撤销
                     ├── grep (Nim SDK)            ← 代码搜索 + 文件列表
                     ├── git (Nim SDK)             ← 只读仓库检查
                     ├── write (Nim SDK)           ← 原子整文件写入
                     ├── observe (Nim SDK)         ← 总线实时检查
                     ├── logfile (Nim SDK)         ← 轮转 JSONL 日志
                     ├── cli (Nim SDK)             ← 按需脚本客户端
                     ├── console (Nim SDK)         ← 按需总线查看器
                     └── 你自己的工具（任何有 SDK 移植的语言）
```

Core 只讲一种协议（基于 NATS 的 JSON envelope，见
[docs/WIRE.md](docs/WIRE.md)）；上面列出的每种能力都是独立进程组件，
使用各自语言的 SDK，而不是编译进 core 的代码。

正常启动时，`manifest.yaml` 自动启动 `store`、`bash`、`builder`、
`plugins`、`skills`、`fetch`、`models`、`provider`、`llm`、`edit`、
`grep`、`git`、`observe` 和 `logfile`。除 Go 编写的 `models`、`provider`、
`llm` 外，其余均由 Nim SDK 驱动；`cli` 和 `console` 是内置的 Nim
客户端，按需运行。另附一个极简的非流式 Go 适配器 `llm-openai` 作为
替换示例。TypeScript SDK（`sdk/ts`）让 agent 也可以在对话中途添加
Node.js 组件。

操作指南：[docs/MANUAL.md](docs/MANUAL.md)（环境变量、`.env`、总线、
审批、恢复、排障，以及发现、模型目录、观测/日志、供应商、fetch、插件、技能、fabric 与子代理等参考章节）。
更新日志：[CHANGELOG.md](CHANGELOG.md)。

## 快速开始

```bash
make                    # 一次性构建全部
ui/build/bin/niffler-ui # 或点击安装好的桌面图标
```

构建一次，然后启动 UI——任何 UI（桌面应用、`niffler-tui` 之类的交互式
终端插件）都会在 core 未运行时自动启动它，**最后一个关闭的 UI 会停掉
它启动的 harness**。

想并行使用多个 UI？手动启动 core：`./var/bin/niffler`；它的管理
shell 会一直运行，直到你主动停止。然后随意启动任意多个 UI。

## 环境要求

Core + 组件需要 **Nim**、**Go** 和 **nats-server**；TypeScript 组件和
桌面 UI 额外需要 **Node/npm**（builder 的 `lang: "ts"` 每次构建会从
npm registry 拉取 typescript）；UI 还需要 **wails CLI**，以及（Linux
上）WebKit/GTK 开发库。

```bash
make setup    # 为你的平台安装一切（Ubuntu/macOS）
make doctor   # 检查缺了什么
```

Makefile 会在 `~/go/bin` 里找到 wails，即使它不在 PATH 上。下面的手动
命令就是 `make setup` 所执行的内容。

### Ubuntu 24.04+

```bash
# Go —— 或从 https://go.dev/dl 下载
sudo snap install go --classic

# Nim 2.x（Ubuntu apt 的版本太旧）—— 会把 ~/.nimble/bin 加入 PATH
curl -sSf https://nim-lang.org/choosenim/init.sh | sh

# nats-server —— 或从 https://github.com/nats-io/nats-server/releases 拿二进制
go install github.com/nats-io/nats-server/v2@latest

# Node/npm（前端；wails 会自己跑 npm install）。Ubuntu 24.04 自带
# node 18，可用。更老的 Ubuntu 需要 NodeSource 或 nvm —— 见 docs/MANUAL.md。
sudo apt install nodejs npm

# Wails CLI（落在 ~/go/bin —— Makefile 会去那里找）
go install github.com/wailsapp/wails/v2/cmd/wails@latest

# Wails 构建依赖：webkit2gtk 4.1、GTK3、构建工具
sudo apt install libwebkit2gtk-4.1-dev libgtk-3-dev build-essential pkg-config libssl-dev
```

### macOS（Homebrew）

```bash
brew install go nim nats-server node
go install github.com/wailsapp/wails/v2/cmd/wails@latest   # → ~/go/bin/wails
```

macOS 无需额外 GUI 依赖——Wails 使用系统 WebKit。请确保安装了 Xcode
命令行工具（`xcode-select --install`）。

### Nim 包

Niffler 的 Nim 依赖声明在 `niffler.nimble` 中（`yaml`，以及来自 GitHub
的 `gokr/natswrapper` 和 `gokr/bitbarrel`），首次构建（`make build`）
时由 nimble 自动安装。

## 运行

| 命令 | 作用 |
|---|---|
| `niffler-ui` | 桌面 UI——必要时自动启动 core；最后一个 UI 会停掉自动启动的 core |
| `./var/bin/niffler` | 终端里的 harness：管理 shell，永不自我退出 |
| `./var/bin/niffler --minimal` | 最小启动配置：只有 `store`、`bash`、`llm` 服务 |
| `make run` | 带 tty 管理 shell 的 harness（状态命令） |
| `make test` | 总线契约测试套件（每个测试自建总线）—— `make test-<comp>` 跑单个组件契约，包括 `test-grep`、`test-git`、`test-edit`、`test-models`、`test-observe`、`test-logfile` |
| `make recover` | 停掉一切，从源码重建自带二进制，清掉已生成组件记录，重启（见下文 Recovery） |
| `make dev` | 浏览器里的 Svelte 开发服务器（桥接为 stub） |
| `make clean` | 删除所有构建产物 |

### 最小启动配置

`./var/bin/niffler --minimal` 启动最小可用的持久 agent 配置：

| 组件 | 保留原因 |
|---|---|
| `store` | 会话/消息持久化与组件记录 |
| `bash` | 一个通用机器工具 |
| `llm` | OpenAI 兼容的模型访问与流式输出 |

Core 和 NATS 总线仍然运行；会话首次使用时系统会启动一个临时的
`session` runner——这些是控制面进程，不是 manifest 服务。其余自带
服务——包括 `builder`、`models`、`provider`、文件工具、plugins/skills、
观测/日志——保持停止。agent 自己添加并持久化的组件在此模式下不恢复，
但记录原样保留，下次正常启动时回来。这是启动配置，不是锁死：
`core.spawn` 之后仍可启动组件。

没有 `provider` 或 `models` 服务时，`llm` 直接使用环境变量/`.env`：

```bash
NIF_OPENAI_API_KEY=sk-... \
NIF_OPENAI_BASE_URL=https://api.deepseek.com/v1 \
NIF_OPENAI_MODEL=deepseek-chat \
NIF_OPENAI_CONTEXT=1000000 \
./var/bin/niffler --minimal
```

`NIF_OPENAI_CONTEXT` 可选；不设时 `llm` 使用内置小模型表，再退到
保守的 128K。桌面 UI 总是自动启动正常配置，所以请先手动启动
`--minimal`，再启动 UI；它会挂到已经在跑的 core 上。`--minimal` 可与
`--recover` 组合。

**测试。** `make test` 跑整套：每个非 LLM 组件一个脚本，各自启动私有
NATS 服务器，在总线上驱动真实二进制快照（envelope 即契约——同一个
harness 同时测试 Nim 和 Go 组件）。可写状态放在唯一的临时 `NIF_ROOT`
下，因此组件测试可以与彼此、与开发中的 live harness 并行。
可选开关：`NIF_TEST_INSTALL=1` 会真实安装 `gokr/niffler-weather`
并验证其工具；安装管线本身通过本地 `file://` git 仓库密封覆盖。
详见 [docs/MANUAL.md](docs/MANUAL.md#testing)。

**Harness 自动启动。** 任何 UI 的第一件事都是 SDK 的 `ensureHarness`：
探测 live core（`NIF_NATS_URL` → `var/nats-url` → 127.0.0.1:4222），
否则自己拉起 `var/bin/niffler`（`NIF_AUTOSTART=1`）。交互式前端注册
`"client": true`；自动启动的 core 在最后一个客户端离开后退出。Core
本身会复用默认端口上已在运行的总线，否则在那里拉起 nats-server
（4222 被占用时退回随机回环端口）并写 `var/nats-url`。设置
`NIF_NATS_URL` 可挂到任意总线，包括远程的。

**审批。** 会改变机器或 harness 的工具——包括 `bash`、`builder.build`、
`edit`/`write`（会写文件的工具）、`core.spawn`/`kill`/`remove`——都带
`x-harness.approval: "always"`，需要真人把关：终端 harness 里是 y/N
提示，Web UI 里是对话框。会话中，请求会路由到驱动该对话的特定交互
组件（其私有 `svc.approval.<name>.request` 主题，由调用的自报 `caller`
推导），客户端不在时广播兜底。无头（没有 UI 挂着）的调用会被拒绝——
绝不静默放行。`NIF_AUTO_APPROVE=1` 可绕过（见
[docs/MANUAL.md](docs/MANUAL.md)）。

**密钥。** `.env`（gitignored）保存 `NIF_OPENAI_API_KEY` 和
`NIF_OPENAI_BASE_URL`（默认指向 DeepSeek）；已有 shell 环境变量总是
优先。服务模式（无 tty）：`NIF_NATS_URL=... NIF_OPENAI_API_KEY=...
./var/bin/niffler < /dev/null`。

## 目录结构

```
docs/                MANUAL.md（操作指南）、WIRE.md（线上协议）、
                     ARCHITECTURE.md（核心边界）、research/（设计历史）
manifest.yaml        启动组件清单
sdk/envelope.nim     envelope 编解码（std/json，刻意保持可移植）
sdk/niffler/         Nim 组件 SDK（约 250 行）
sdk/go/              Go 组件 SDK（Nim 版的镜像）
sdk/ts/              TypeScript/Node.js 组件 SDK（镜像，npm 包）
core/                catalog、supervisor、dispatch、对话循环
components/          Nim：store、bash、builder、plugins、skills、fetch、
                     edit（读写文件工具）、grep、git、observe、logfile、
                     cli、console；Go：models、provider、llm
                     + llm-openai 示例
tests/               总线契约套件：helpers + 每组件一个 t_*.nim
ui/                  NATS 之上的 Web SPA —— 方向 + Wails 桥接设计
var/                 运行时：二进制、构建缓存（gitignored）
```

## 持久化

`store` 和其他组件一样——一个总线上的哑文档存储
（`put/get/list/del`，基于 rev 的乐观并发）。底层是**内嵌 BitBarrel**
（Bitcask KV，critbit 索引）的 critbit 模式；恰好一个进程拥有 barrel
文件（`var/barrel-db`），其余全部走 envelope——因此后端选择是封闭、
可替换的（将来带 FTS/向量的 store-tidb 变体用同样的工具即可无缝替换）。

Barrel 自带的 pubsub **故意不用**——NATS 是唯一总线。Kind 键：
`component`、`conversation`、`message`、`plugin`（plugins 组件的安装
记录）。Core 持久化已生成组件（正常启动时恢复；`--minimal` 有意让它们
停着）和对话消息。

**恢复。** 仓库即快照；`var/` 是一次性构建输出。如果组件损坏——
二进制被覆盖、自加的组件坏了、记录损坏——`make recover` 从源码重建
自带二进制、清掉已生成组件记录并全新启动（会话保留）。见
docs/MANUAL.md。

## 写一个组件

Nim —— `import niffler/sdk`，类型化工具模式（doc 注释即 schema）：

```nim
import niffler/sdk

let comp = newComponent("weather", "0.1.0")
comp.tool:
  proc weather(city: string): JsonNode =
    ## Current weather for a city
    ## - city: the city name
    %*{"temp": 21}
comp.run()
```

Go —— `import sdk "niffler.dev/sdk"`，同样的接口（`Tool`、`On`、`Emit`、
`Request`、`Run`）。

TypeScript —— 跑在 Node.js 下（`import sdk from "niffler-sdk"`，
同样的接口，handler 可以是 async）：

```ts
import sdk from "niffler-sdk";
const comp = sdk.newComponent("weather", "0.1.0");
comp.tool("weather", {
  type: "object",
  description: "Current weather for a city",
  properties: { city: { type: "string" } },
  required: ["city"],
}, async (_c, args: any) => {
  return { temp: 21, city: args.city };
});
comp.run();
```

其他语言：移植 SDK——envelope 即契约（约 200 行）。

然后：`builder.build {lang, name, source}` → `core.spawn {name, binary}`
→ 工具上线。用 `core.remove {name}` 退役（`core.kill {name}` 临时停掉）。
Agent 在对话中途自己完成这一切——这就是该架构的验证标准。

## 组件生态

第三方组件包以普通 GitHub 仓库分发——一仓库 = 一包 = N 个组件，根目录
有 `niffler.json` manifest。打上 GitHub topic
[`niffler-component`](https://github.com/topics/niffler-component) 的
仓库可在对话中发现（说“给我找个天气组件”）或用 `plugin_search` 搜；
`plugin_install {repo}` 把仓库 clone 到 `var/plugins/<pkg>@<ref>/`，
通过 `builder` 从源码编译每个组件（与 agent 自写组件同一条路——无需
额外工具链，各平台用自己的编译），然后 `core.spawn` 每个服务组件
（经真人审批）。Go 组件可以在 manifest 的 `"sources"` 数组里列出额外的
同包文件。标记 `"interactive": true` 的组件会构建进 `var/bin` 但不
自动启动，由用户在终端里手动打开。
`plugin_update` / `plugin_remove` 管理已安装的包；安装记录存在 store
的 `plugin` 记录里，重启后仍在。

示例包：[`gokr/niffler-weather`](https://github.com/gokr/niffler-weather)
（Open-Meteo 天气，无需 API key）。其 README 记录了 manifest 格式；
其发布流程本身就是 dogfooding——拉起 harness，用 **cli 组件**
（`./var/bin/cli`：`catalog` / `wait` / `call` / `install <repo>[@<ref>]`，
成功即退出 0）驱动它，所以每个 tag 都证明该包能装、工具能用。
这套 cli 流程也是给任意插件仓库做 CI 的首选方式——Niffler 自己也在用。

## 里程碑状态

- [x] wire spec、envelope、Nim + Go + TypeScript SDK
- [x] supervisor（spawn/monitor/restart/drain）、catalog、dispatch
- [x] bash + builder 组件、Go 流式 LLM 适配器（OpenAI 兼容）
- [x] 类型化工具定义（nimcp 启发：proc → schema + handler）
- [x] **agent 端到端给自己加工具**（docs/research/REBOOT.md 里程碑，用 DeepSeek
      实测：写 → 构建 → 启动 → 调用 `greet`）
- [x] **store 组件** —— 总线上 barrel 支撑的文档存储（put/get/list/del，
      基于 rev 的乐观并发）；core 持久化会话、消息与已生成组件；已生成
      组件开机恢复（形态持久化，跨重启实测）
- [x] **session 服务** —— svc.core.call 的 `session` 回合 + ev.session.*
      事件；UI 的服务模式（无 tty）；实测通过
- [x] **session runner** —— 一对话 = 一进程：系统为每个会话确保
      `var/bin/session <id>`，并把回合转发到 `svc.session.<id>.call`；
      runner 是临时的、从 store 恢复；杀掉一个只丢进行中的回合
      （实测：新 runner + 恢复 + 干净 drain）
- [x] **Wails SPA 外壳** —— Go 桥接（总线公民）、Svelte 5 聊天：store
      里的会话、实时工具卡片、markdown、会话恢复、模型/token/上下文
      显示；构建 + 端到端验证
- [x] **审批** —— dispatch 里的 x-harness.approval 拦截器：终端提示
      （tty）或定向到调用方的 UI 审批（带 ack、广播兜底、
      ev.approval.resolved 清理）；无人在场即拒绝；端到端验证（service
      + tty 探针）
- [x] **恢复模式** —— `--recover` / `make recover`：从源码重建自带
      二进制、清已生成组件记录、保留会话
- [x] **最小启动配置** —— `--minimal` 只启动 `store`、`bash`、`llm`，
      直接用 `NIF_OPENAI_*`，已持久化的额外组件保持停止且不删记录
- [x] **plugins 组件** —— 总线服务形式的生态发现 + 安装：GitHub topic
      搜索、`niffler.json` 包 manifest、总是经 builder 从源码构建
      （或用 `file://` 本地仓库密封安装）、spawn/update/remove、store
      记录；用 `gokr/niffler-weather` 端到端实测
- [x] **UI 自持生命周期** —— 任何交互客户端经 SDK 的 `ensureHarness`
      自动启动 core；自动启动的 core 在最后一个交互客户端离开后退出，
      手动启动的永不退出。没有启动脚本——桌面图标即整个系统
- [x] **models 组件** —— models.dev 基线 + 内嵌离线种子、验证过的原子
      缓存、严格模型解析、可搜索的能力/限制/价格，以及确定性的
      `x-models-source` 插件补丁与 last-known-good 回退；`llm` 消费其
      上下文元数据
- [x] **provider 组件** —— store 支撑的 LLM 提供商注册表
      （add/list/switch/active/remove/export/import，list 永不泄露
      密钥）、`ev.provider.switch` 通知、live 后端切换：`llm` 从激活的
      存储提供商解析默认值，缺失时回退 `NIF_OPENAI_*` / `NIF_LLM_PROVIDERS`
- [x] **grep + write 组件** —— ripgrep 支撑的代码搜索（`grep`：
      path:line:match 结果，处理 .gitignore/hidden/binary；`files`：排序
      仓库列表）与审批门控的原子整文件写入（临时文件 + rename、保留
      权限）
- [x] **observe 组件** —— 一个精确的原始总线 tap、有界 live ring 与
      listen/trace 探针、请求/响应关联、安全的抓包导出，以及
      core 发现的 nats-server 监控
- [x] **logfile 组件** —— 所有 SDK 的结构化 `ev.log.*` 事件、轮转
      JSONL 持久化、有界新到旧搜索、原始整总线抓取、显式的 sink 健康
      上报
- [x] **console 组件** —— 被动总线查看器：订阅一切，可读地渲染线上
      流量（第二个终端里跑）
- [x] **skills 组件** —— Agent Skills（SKILL.md）：跨标准 agent 目录
      发现、在线 skills.sh 搜索（`npx skills find` 后端）、渐进披露
      加载、按需资源、git 安装到 `~/.niffler/skills` / 项目
      `.opencode/skills`（无需 Node）、删除仅限 Niffler 管理的目录
- [x] **fetch 组件** —— 老 Niffler 的 `fetch` 工具总线化：http/https
      支持方法/头/体、Trafilatura 优先的 HTML→文本抽取（纯 Nim 回退）、
      重定向、超时与大小上限、超大内容落到 `var/fetch` 文件
- [x] **cli 组件** —— 从终端或脚本驱动 harness（`catalog` / `wait` /
      `call` / `install`），成功即退出 0；给插件仓库做 CI 的首选方式
      （niffler-weather 的 workflow 在用）
- [x] **core 重入** —— dispatch 轮询私有 inbox，在回合进行中服务
      `svc.core.call`，因此组件回调 core（`plugin_install` →
      `core.spawn`）不会死锁会话；并发会话请求排队，绝不嵌套
- [x] **总线契约测试套件** —— `make test`：每个非 LLM 组件一个脚本
      （含 models、observe、logfile、edit），各自在私有 NATS 上驱动
      真实二进制；`file://` 密封插件安装；网络项在
      `NIF_TEST_INSTALL`/`NIF_TEST_NETWORK` 之后
- [x] **流式输出** —— `llm` 适配器流式发 `ev.llm.token` 增量（内容 +
      推理），core 转发为 `ev.session.token`，UI 追加到 live assistant
      气泡；按调用取消（`llm.cancel.<sessionId>`）；最终 assistant 事件
      总是携带完整内容
- [x] **hashline-edit** —— 哈希锚定的 `read`/`replace`/`undo_last_replace`
      （pi-hashline-edit-pro 的 Nim 移植），锚点跨编辑稳定；已抽出为
      [niffler-hashline](https://github.com/gokr/niffler-hashline) 插件
- [x] **edit 组件** —— 文件工具：`read`（纯文本、可分页）、精确文本
      `edit` 作为主编辑器：强制 old_string 唯一（歧义匹配带次数拒绝）、
      一次调用多个不重叠编辑、守护式回退级联（尾部空白、缩进、Unicode
      标点、块锚点、转义文本）、`replace_all`、LF 规范化、原子 `write`
      （自原 write 组件并入）、审批门控、跨重启持久化的单层
      `undo_last_edit`
- [x] **git 组件** —— 只读仓库检查（`git_status`/`git_diff`/`git_log`/
      `git_show`/`git_blame`）：无需审批、固定 argv（无 shell）、路径
      限定在 harness 根目录并做参数校验、带收窄提示的输出上限、干净
      的非仓库处理；变更类操作留在 bash
- [x] **TypeScript SDK** —— sdk/ts（npm 包，Go SDK 的镜像）；builder 经
      tsc 把 `lang: "ts"` 组件编进 node wrapper 二进制；实测（builder →
      spawn → 从 Node.js 调用）
- [x] **渐进式工具发现** —— 一个完整的全局 catalog，但每个会话冻结
      一个小型不可变直接工具集（13 个自带）；`discover` 把提示/完整
      schema 返回进 append-only 历史，`invoke` 经正常审批/超时路径调用
      任意 live 非隐藏工具（docs/MANUAL.md）；UI Live Components 面板
      按活动会话给 direct/seen/demand/internal 上色
      （tests/t_discover.nim）
- [x] **定向审批路由** —— 审批请求经私有
      `svc.approval.<caller>.request` 路由到驱动回合的组件（ack 门控、
      驱动方不在时广播兜底、`ev.approval.resolved` 清过期弹窗）；四个
      SDK 的调用 envelope 都带自报 `caller`；Web UI 在私有主题上 ack +
      应答
- [ ] Level 1 UI 动态化：x-ui schema 提示 + 通用渲染器注册表
- [ ] 终端 harness + UI 的取消（ev.cancel 流程打磨）

## 任务 —— Niffler 自己该做的事（或者我们闲着的时候做）

1. **store-sqlite 对比** —— 把 components/store/main.nim 移植到 SQLite
   （如 nim-community/libsql），同样的工具，两个都跑，对比。契约即
   产物；Niffler 能读自己的源码（`bash cat …/store/main.nim`）、构建、
   拉起并基准测试该变体——真正的 dogfooding 任务。
2. **node/TS 组件 SDK** —— 把 sdk/go（约 200 行）移植到 TypeScript；
   让 agent 无需编译步骤就能加 JS 工具。（已完成 —— sdk/ts + builder
   的 `lang: "ts"`；经 tsx 免编译跑 JS 仍是可能的后续。）
3. **pipewrap** —— stdio/NDJSON 桥，让普通脚本也能成为组件。
4. **Level 2 UI 动态化** —— builder 把 Svelte 组件编成 JS 模块，
   catalog 注册 ui-modules，桥接服务 var/ui/，SPA blob 导入（见
   ui/README.md）。
5. **store-tidb** —— 同样的工具，SQL 表，FTS + 向量搜索用于会话记忆；
   跨 harness/主机共享。
6. **组件包模板仓库** —— 把 niffler-weather 的仓库布局 + 发布 CI 做成
   可 `gh repo create` 的模板；可选地做一个精选索引仓库用于
   `plugin_search` 排序。
