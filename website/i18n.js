/* niffler website — en/zh/zh-TW chrome localization.
 * English lives in the HTML; its original DOM values are captured once so
 * switching back from zh or zh-TW can restore them without a page reload.
 * The choice persists to
 * localStorage and falls back to navigator.language
 * (zh-Hant/TW/HK -> Traditional, other zh -> Simplified). */

(function () {
  "use strict";

  var CATALOGS = {
    zh: {
      "meta.title": "Niffler — 可自我扩展的 agent harness",
      "meta.description": "Niffler 是一个极简、可自我扩展的 agent harness。组件以独立进程运行并通过 NATS 总线通信；agent 可以在对话过程中编写、编译并启动自己的工具。",
      "meta.titleComponents": "Niffler — 组件与状态",
      "meta.descComponents": "Niffler 的每个能力都是独立的进程组件，通过 NATS 上的 JSON envelope 通信——内置 Nim、Go 和 TypeScript，可移植到任何语言。",
      "locale.label": "语言",
      "nav.home": "首页",
      "nav.why": "为什么",
      "nav.architecture": "架构",
      "nav.quickstart": "快速开始",
      "nav.components": "组件",
      "nav.status": "状态",
      "nav.gitclone": "git clone",
      "hero.h1": "一个能在对话中途<br><span class=\"accent\">扩展自身能力</span>的 harness。",
      "hero.sub": "Niffler 是一个高度模块化、可自我扩展的 agent harness。组件是<strong>任意语言</strong>编写的<strong>独立进程</strong>，总线是 <strong>NATS</strong>；agent 在对话过程中自行编写、编译并启动新工具。",
      "hero.release": " —— 总线现在运行纯 Nim 的 NATS 客户端（无需安装 libnats）；本版本同时发布 <code>niffler-tui</code> 终端客户端与桌面 UI",
      "hero.badgeAny": "任意语言",
      "hero.ctaMake": "make install-tui && niffler-tui",
      "hero.ctaGithub": "github →",
      "hero.ctaDiscord": "discord →",
      "term.build": "安装 niffler-tui 终端客户端（一个插件）· 客户端按需启动 harness",
      "term.l1": "→ 主总线：已认领 nats://127.0.0.1:4222 · root ~/niffler @ 8094748",
      "term.l2": "→ core 正在监听 svc.core.call",
      "term.typed": "niffler — 等待输入…",
      "term.note": "那个终端是管理 shell（不含聊天）——对话在 niffler-ui 与 niffler-tui 中进行",
      "why.title": "为什么",
      "why.1h": "<span class=\"num\">01</span> 进程，而非插件",
      "why.1p": "无需 <code>dlopen</code>，也不受 ABI 兼容和进程内状态残留困扰。每个组件都是独立进程；停止组件只需结束进程，操作系统会回收相关资源。单个组件崩溃不会直接带崩 core 或其他组件。",
      "why.2h": "<span class=\"num\">02</span> 一种协议",
      "why.2p": "Core 只使用一种通信格式：通过 NATS 传输的 JSON envelope。编解码器约 200 行，仅依赖 <code>std/json</code>。目前提供 Nim、Go 和 TypeScript SDK，也可以移植到其他语言。",
      "why.3h": "<span class=\"num\">03</span> 自我扩展",
      "why.3p": "agent 写源码 → 调用 <code>builder.build</code> → 调用 <code>core.spawn</code> → 新工具立即可用。新增能力本身就是一次工具调用，LLM 可以在对话过程中自行完成整套流程。社区组件也以相同方式安装：<code>plugin_install</code> 会克隆源码、编译并启动；执行前需人工批准，并始终从发布的源码构建。<code>fabric</code> 更进一步：LLM 可以编写掌控整个回合内工具调用流程的 Nim guest 程序，由组件编译为本地进程运行。外部 MCP 服务器也接入同一条总线：<code>mcp</code> 管理器为每个服务器启动一个桥接进程，其工具以普通目录工具的形式出现。",
      "why.4h": "<span class=\"num\">04</span> 能力形态持久化",
      "why.4p": "能力可以跨重启保留：已启动的组件记录在 store 中，并在下次启动时自动恢复。仓库保存可复现的源码；<code>var/bin/</code> 可以重新构建，持久化状态保存在 store 引擎中（默认 SQLite 的 <code>var/store.db</code>，可通过 <code>NIF_STORE_BACKEND</code> 换用 barrel 或 TiDB）。",
      "arch.title": "架构",
      "arch.core": "对话循环 · supervisor<br>catalog · dispatch",
      "arch.note1": "一个对话 = 一个进程：系统为每个对话启动一个 <code>var/bin/session &lt;id&gt;</code> runner。终止某个 runner 不会影响其他会话。",
      "arch.yourtool": "你的工具",
      "arch.anylang": "任意语言",
      "arch.note2": "每个方框都是一个通过对应语言组件 SDK 构建的小型可执行程序——<br>彼此对等、相互隔离，可以独立停止。",
      "loop.title": "自我扩展循环",
      "qs.title": "快速开始",
      "qs.clone": "git clone git@github.com:gokr/niffler.git && cd niffler",
      "qs.setup": "# 安装环境依赖（Ubuntu / macOS）",
      "qs.env": "# 填入 LLM API key，按需修改其他设置",
      "qs.make": "# 首次构建 core + 组件（无需 UI 工具链）",
      "qs.install": "# 将 niffler / niffler-cli / niffler-console 放入 PATH（按需加装 niffler-tui）",
      "qs.installtui": "# 同上，并静默安装 niffler-tui 终端客户端",
      "qs.installlsp": "# 幂等安装 lsp 组件的默认语言服务器",
      "qs.tui": "# 终端聊天——没有运行中的 harness 时会按需启动一个",
      "qs.installdesktop": "# 桌面 UI——通过插件生命周期安装 gokr/niffler-ui 并构建 var/bin/niffler-ui",
      "qs.test": "# 总线契约套件——完整门禁，每个测试独占 NATS + 临时根目录",
      "qs.see": "└─ make run / recover / down / down-here / ram / uninstall / dev · 见 docs/MANUAL.md",
      "qs.requirements": "环境要求",
      "qs.req.nim": "Nim 2.2.12+",
      "qs.req.go": "Go",
      "qs.req.nats": "nats-server（从源码构建）",
      "qs.req.node": "Node.js / npm",
      "qs.req.wails": "Wails CLI <span class=\"dim\">（仅构建 niffler-ui 插件时需要）</span>",
      "qs.req.trafilatura": "Trafilatura <span class=\"dim\">（可选，提供更完整的 HTML 正文提取）</span>",
      "qs.note": "所有 Nim 依赖都来自 nimble——yaml、htmlparser、checksums、natsnim、bitbarrel——首次构建时自动安装。",
      "qs.clonehome.h": "一个克隆 = 一个实例",
      "qs.clonehome.p": "harness 只会认领自己的主总线（<code>.env</code> 中的 <code>NIF_NATS_URL</code>，默认 <code>nats://127.0.0.1:4222</code>），且仅当应答的 core 服务于本根目录时才接入——每个 catalog 响应都携带 <code>root</code> + <code>gitHash</code>；遇到陌生 core 会高声让位。开发克隆可设 <code>NIF_NATS_SPAWN=1</code> 获得隔离的随机端口总线，且任何子进程（组件、nats-server）都不会比所属 harness 活得更久。",
      "comp.title": "自带组件",
      "comp.th.component": "组件",
      "comp.th.language": "语言",
      "comp.th.purpose": "用途",
      "comp.core.p": "对话循环、进程管理（supervisor）、组件目录（catalog）和调用分发（dispatch）——以及每次 provider 请求前的上下文窗口准入守卫；属于人类的两个对话级控件通过 <code>session</code> 调用设置，并以 <code>/approvals</code>（本对话的门禁模式：<code>ask</code> 或 <code>auto</code>，auto 会高声自动放行）与 <code>/limit</code>（软性 rounds/tokens/seconds 预算，触及时询问“是否继续”而非结束回合）暴露，随对话持久化；回合进行中到达的 session 调用会立即以 <code>busy</code> 拒绝，不再悬挂；<code>session {export: true}</code> 导出下一回合将要发送的确切请求（消息、经允许清单过滤的工具 schema、模型、provider、<code>reasoning_effort</code>），不产生用户消息、LLM 调用或 store 写入；超时或被取消的工具调用会带着部分输出以显式错误返回，而不是被记成静默的成功",
      "comp.session.p": "一个对话 = 一个进程——临时按会话启动的 runner，从 store 恢复；杀掉一个只会丢失进行中的回合",
      "comp.bash.p": "以工具形式提供 shell 访问；执行前需人工批准；支持进程树取消与超大输出分页读取",
      "comp.builder.p": "将 agent 编写的源码编译为可执行程序，并用 <code>build_package</code> 构建 manifest-v2 插件项目——依赖清单与锁文件由包自己持有，builder 负责暂存项目、只展开受控的 SDK/输出占位符、执行有界 argv 配方（不允许 shell 包装），并校验声明的产物",
      "comp.store.p": "总线文档存储，使用版本号（rev）进行乐观并发控制——同一契约下引擎可互换：SQLite（默认，<code>var/store.db</code>）、barrel 与 TiDB/MySQL，通过 <code>NIF_STORE_BACKEND</code> 选择；<code>list</code> 是分页读取（单页上限 1000 条），返回 <code>hasMore</code> 与 <code>nextAfter</code> 游标，core 自身的全量读取会自动分页；存在未迁移 <code>var/barrel-db</code> 历史的 harness 会拒绝启动——<code>niffler-store-migrate</code> 可离线在任意引擎对之间迁移根目录（<code>--scan</code>/<code>--all</code>/<code>--dry-run</code>）",
      "comp.plugins.p": "组件生态：按 topic 搜索，通过 <code>niffler.json</code> 描述包——manifest v1 的紧凑形式，或 manifest v2（<code>manifestVersion: 2</code>）项目：由包自带依赖清单与锁文件、经 builder 的 <code>build_package</code> 配方构建——支持安装/更新/移除；始终从源码构建；提供按组件名加前缀的 <code>/plugins</code>/<code>/plugins-search</code>/<code>/plugins-install</code>/<code>/plugins-update</code>/<code>/plugins-remove</code> 斜杠命令；仓库没有发布 release 时标签解析会回退到它的 tags，分支钉选的安装会跟随分支原地更新，不会被改指到 release 标签",
      "comp.skills.p": "Agent Skills 的发现、渐进式加载、资源访问，以及受管的安装/移除；skill_audit 盘点未合并的磁盘清单；内置的自我知识集同时烘焙进二进制作为最后兜底（<code>NIF_SKILLS_BUNDLED_DIR</code> 可重定位；烘焙条目报告目录 <code>(baked)</code>）",
      "comp.systemprompt.p": "对话宪法组件化——session runner 每个对话只调用一次 <code>svc.systemprompt.call</code> 获取系统提示词；替换组件即可替换宪法。组件与插件通过隐藏的 <code>prompt_hint</code> 工具登记提示词片段——命名槽位（<code>tool_usage</code>、<code>efficient_tools</code>、<code>after_instructions</code>）在新对话中按确定性顺序渲染进 <code>&lt;prompt_slot&gt;</code> 块，绝不改写已冻结的提示词——指令还按需懒加载：<code>AGENTS.local.md</code> 加入遮蔽链，读取进入 monorepo 子目录时以工具结果注入该子树的规则（每会话一次），不占用系统前缀",
      "comp.recall.p": "隐藏的 <code>context_recall</code> 解析器——被修剪和溢出的内容以引用替代，本组件负责解析它们：canonical 消息、晋升的溢出文档和当前持久的 compaction 检查点；每条修剪/溢出通知都逐字给出引用名，让 recall 可被发现",
      "comp.compaction.p": "可替换的上下文摘要器——长回合能在自己的上下文中存活：每次 provider 请求前 core 都会按 provider 自己的 token 尺度估算请求规模，在压力线执行确定性阶梯（无损工具结果修剪 → 摘要压缩 → 整回合裁剪 → 显式 <code>context-recovery-required</code>），绝不发出超出窗口的请求；持久化裁剪会记录水位线，重放可跨重启安全进行，归一化后的 provider 溢出 400 会先获得一次带回执的恢复尝试再转为终态。本组件是默认的 contract-v1 <code>compaction_propose</code> 实现（<code>NIF_COMPACTION_TOOL</code> 可选择其他实现）：它校验 runner 的分页快照、选择允许的裁剪点并起草检查点候选——只有 runner 会验证并提交 <code>context_projection</code>，canonical 消息保持不可变；任何 contract-v1 实现都可用 <code>make test-conformance</code> 对照契约验证",
      "comp.fetch.p": "带超时和大小限制的 HTTP(S) 内容获取，支持 method/header/body；优先使用 Trafilatura 提取 HTML，并提供纯 Nim 备用方案和超大结果落盘。出站访问失败即拒绝：预先解析主机，回环、私有、链路本地、运营商级 NAT、组播与未指定地址一律拒绝（IPv4 映射 IPv6 归一化处理），<code>localhost</code>/<code>.localhost</code>/<code>.local</code>/<code>.internal</code> 主机名、内嵌凭据的 URL 以及 DNS 解析失败同样拒绝；重定向逐跳重新校验，上限五跳且仅限 http(s)。<code>NIF_FETCH_ALLOW_PRIVATE=1</code> 可为可信的本地开发恢复回环访问",
      "comp.edit.p": "文件工具：<code>read</code>（单个 <code>path</code>，或用规范的 <code>reads</code> 数组一次批量读取最多 12 个文件/区间，逐项报错，可分页；对有语言服务器支持的大文件整读时返回 lsp 符号大纲——可用 offset/limit 开窗，或 <code>offset: 1</code> 强制整读）、带守卫回退级联的精确匹配 <code>edit</code>、原子 <code>write</code>、单层撤销（<code>undo_last_edit</code>）；未变更的整文件重读返回精简的 <code>[unchanged]</code> 标记而不重复输出字节（<code>force</code> 或窗口读取可重新输出），文件在对话上次见过后被改动时 <code>edit</code> 以 <code>E_STALE</code> 拒绝——重读观察到不同字节时会持久化该摘要修正，陈旧状态不会跨重启残留——已读状态按（会话，文件）记录；<code>edit</code> 成功后返回精简的变更预览（删除/新增的行及上下文，过大时明确截断）；修改操作需人工批准",
      "comp.lsp.p": "语言服务器接缝——一个 <code>lsp</code> 工具（无需跑测试即可获得 <code>diagnostics</code>、<code>documentSymbol</code>——文件大纲、<code>workspaceSymbol</code>——全仓库模糊符号搜索、<code>goToDefinition</code>、<code>findReferences</code>、<code>goToImplementation</code>、<code>hover</code>），可对接任意已配置的 stdio 语言服务器（默认 gopls、nimtortoise、typescript-language-server、pyright、rust-analyzer、clangd、bash-language-server、jdtls、csharp-ls）；注册表是数据（<code>$XDG_CONFIG_HOME/niffler-lsp/servers.json</code>）——新增一门语言只是加一条配置，或由 agent 自己发起需审批的 <code>lsp_registry add</code>，绝不需要写代码；<code>make install-lsp</code> 按语言安装默认语言服务器，core 会在打开工作区时按清单预热它们；只读的 <code>lsp_servers</code> 列出合并后的注册表，niffler-tui 的 <code>/lsp</code> 可浏览并编辑它",
      "comp.repomap.p": "排序后的仓库地图（aider repomap 的移植）——以约 1KB 的篇幅给出最关键的文件及其关键定义，由 tree-sitter + 原生 Nim 的 tags 图经个性化 PageRank 排序得出；<code>repo_map</code> 是 onDemand 且只读的工具：模型主动询问，绝不主动注入。工作区打开时的自动附加（每个新对话一条只追加条目）需通过 <code>NIF_REPOMAP_AUTOAPPEND=1</code> 显式开启——默认关闭，因为 A/B 显示 token 代价增加而准确率无收益——即使开启也设有门禁：低于普查下限（<code>NIF_REPOMAP_MIN_CENSUS</code>，默认 50）的工作区不建图，骨架图（字节/符号/文件阈值）不注入，被拦截的地图会留下日志。缓存位于 <code>var/repomap-tags/</code>；组件缺席只意味着没有地图，别无影响",
      "comp.processes.p": "有主的后台进程——bash 的 <code>run_in_background</code> 标志转发到 <code>process_start</code>（脱离会话、独立进程组、spool 文件在 <code>var/processes/</code> 下）；<code>process_poll</code> 增量读取输出，<code>process_kill</code> 停止进程组，<code>process_list</code> 查看注册表并携带 <code>started_at</code>；子进程是进程组组长，<code>registry.json</code> 驱动启动时的孤儿扫描——结束的子进程会通知其对话：退出通知（<code>kind: \"process-exited\"</code>，与 subagent 结算通知同一条通道）被折入只追加历史并指向 spool（“运行 412 秒、8123 字节输出——用 process_poll 读取”）；组件通过 SDK 的 <code>onIdle</code> 周期性收割子进程，无需有人轮询也能发现退出",
      "comp.grep.p": "基于 ripgrep 的内容搜索（<code>grep</code>——默认直接工具集，输出按行数与 32KB 字节上限截断）和有序仓库文件列表（<code>files</code>——按需加载），提供明确的截断标记",
      "comp.git.p": "只读仓库检查：<code>status</code>/<code>diff</code>/<code>log</code>/<code>show</code>/<code>blame</code>；无需审批，固定 argv，路径限定在 harness 根目录；另有 <code>review_receipt</code> 做推送前的 diff 指纹交接",
      "comp.hooks.p": "操作员 shell 命令，挂在选定的总线事件上（<code>ev.session.*.turn</code>、<code>ev.log.&gt;</code>）——stdin 接收 JSON 载荷，只观察不干预，由环境变量配置，默认关闭",
      "comp.observe.p": "实时查看总线——subject 发现、监听、请求/响应追踪和监控",
      "comp.logfile.p": "将 <code>ev.log.*</code> 持久化到 JSONL——支持日志轮转、范围受限的搜索和保留策略",
      "comp.models.p": "通过总线提供 models.dev 的 provider/model 目录——内置离线数据、缓存刷新和 <code>x-models-source</code> 插件补丁",
      "comp.provider.p": "基于 store 的 LLM provider 注册表——add/list/switch/active/remove/export/import，运行时切换后端，订阅制 OAuth 登录并自动轮换令牌；provider_models 探测 provider 自己的 /models 端点获取实时模型 id",
      "comp.llm.p": "流式聊天 adapter——默认 OpenAI 兼容 Chat Completions（DeepSeek），另支持 OpenAI Codex（ChatGPT OAuth）Responses 与 Anthropic Messages 协议——实时 <code>ev.llm.token</code> token 流、推理 token，以及单次调用取消；重试按故障类型拆分预算——带 <code>Retry-After</code> 的 429 按服务器指示等待（封顶、不限尝试次数），流超时与连接拒绝各有独立的有界预算（<code>NIF_LLM_MAX_STREAM_RETRIES</code>/<code>NIF_LLM_MAX_CONNECT_RETRIES</code>，默认 2），永久性错误（鉴权、配额、错误请求）快速失败",
      "comp.mcp.p": "把外部 MCP 服务器（Model Context Protocol）变成总线组件——基于 store 的注册表，带需审批的 <code>mcp_add</code>/<code>mcp_edit</code>/<code>mcp_remove</code>（每次新增/编辑都通过一次真实连接验证）、检索官方 MCP Registry 的 <code>mcp_search</code>，以及在连接时从 harness 环境解析 <code>${ENV}</code> 秘密引用（令牌不落库）；服务器的工具成为普通目录工具，经 <code>discover</code> + <code>invoke</code> 调用；配置为 <code>expose: direct</code> 且发布工具数超过 <code>NIF_MCP_DIRECT_THRESHOLD</code>（默认 10）的服务器会改为按需发现，避免淹没工具提示词",
      "comp.mcpbridge.p": "每个 MCP 服务器一个受监督进程（官方 Go SDK；stdio / streamable HTTP / SSE）——空闲即退出的惰性会话、确保服务器不比 harness 活得更久的 stdio 守护、进行中调用的取消、工具契约漂移时持久化并重启桥接以保持发现结果真实、提示词变成斜杠命令、资源收敛为一个读取工具、超过 64 KiB 的结果落盘",
      "comp.fabric.p": "可编程工具调用——LLM 编写 Nim 程序掌控回合内控制流；每个程序都编译为本地 guest 进程（内容寻址的二进制缓存、结构化的 <code>fabricguest</code> SDK、按需的 <code>fabric_help</code> 参考文档），回合被取消时数秒内即被终止；带目录钉选的类型化包装、命名程序库、宿主并发的 <code>batch</code> 调用、审批清单，以及按 runId 关联的 <code>ev.fabric.*</code> 生命周期事件——组件还自带经实测运行的示例程序",
      "comp.agent.p": "subagent 会话——同步 <code>agent_run</code> 把任务委派给拥有全新上下文的子 runner；持久化后台任务（<code>agent_spawn</code>/<code>status</code>/<code>wait</code>/<code>stop</code>/<code>steer</code>）跨重启存续；子会话是有记忆的会话：<code>agent_run</code>/<code>agent_spawn {session}</code> 让既有子会话再跑一回合（只追加历史、基于持久血缘关系的授权、busy 与排队两种语义、激活账本、<code>close: true</code> 退役），<code>fork: true | {lastK} | {maxChars}</code> 用调用方的已完成回合播种一个全新子会话；未显式指定 <code>model</code> 的新子会话继承父对话的生效模型，也可用 <code>modelTier: weak | medium | strong</code>（会被钳制到父对话的档位）；委派深度有上限（<code>NIF_AGENT_MAX_DEPTH</code>，默认 1——子代理不能再派生子代理），嵌套调用使用按 id 键控、带独立截止时间的租约，并行的会话上下文分发因此安全；已结束的后台子会话以结算通知送达父对话（是指向 <code>agent_status</code> 所返回完整回复的指针），无需轮询；<code>agent_list</code> 给出派生的子会话名册，对空闲子会话的 steer 会排入持久的父邮件并在其下一回合送达，<code>agent_ask</code> 返回子会话的回答；空闲 runner 自动退役",
      "comp.expert.p": "咨询同伴——可同时跟随一个或多个工作中的会话，对每个会话的有界观察做 LLM 判定（判定前缀内嵌内置的 niffler-tools/niffler-fabric/niffler-harness 技能），只把高置信度的 steer 作为标记消息投递；默认沉默、失败即静默",
      "comp.dialog.p": "纯 bash 组件——<code>dialog_show</code>/<code>dialog_ask</code> 桌面对话框（zenity → notify-send → 日志回退），只用 nats CLI + jq 说 envelope，无 SDK、无需编译",
      "comp.cli.p": "通过脚本驱动 harness：<code>catalog</code>/<code>wait</code>/<code>call</code>/<code>install</code>——插件仓库的标准 CI 入口；安装确认以 core 已接受的目录为准，而非原始注册广播",
      "comp.nats.p": "总线服务器本身，从源码构建——components/nats 将官方 nats-server 编译为 <code>var/bin/nats-server</code>；core 优先使用该二进制而非 PATH 安装，因此仅 <code>make build</code> 即可满足总线依赖；内置构建以 8 MiB 载荷上限运行（上游默认 1 MiB），携带完整对话的 LLM 请求也放得下；回退到 PATH 安装时经配置文件取得同样的 8 MiB 上限（core 回退时会警告一次），core 还会在启动时检查所连总线的最大载荷，发现不够就大声警告而不是在对话中途失败",
      "comp.console.p": "总线查看器——将每个 envelope 输出到 stdout，可在第二个终端中实时查看",
      "comp.ui.p": "桌面聊天 UI，以交互插件 gokr/niffler-ui 发布（源码在独立仓库中）——会话、流式 token、工具运行、审批、模型控制；由 Wails 承载的 SPA，架构上是 NATS client；<code>make install-ui</code> 经插件生命周期安装（按最新 release 标签克隆、针对本 harness 构建、发布为 <code>var/bin/niffler-ui</code>）——由用户手动启动，绝不作为服务被 spawn",
      "comp.your.p": "移植 SDK；envelope 是跨语言契约（约 200 行）",
      "comp.your.name": "你的工具",
      "comp.your.lang": "任意",
      "screens.ui.name": "niffler-ui",
      "screens.ui.desc": "桌面聊天 UI：会话、流式 token、工具运行、审批、模型控制（一个插件——make install-ui 安装 gokr/niffler-ui）",
      "screens.tui.name": "niffler-tui",
      "screens.tui.desc": "终端聊天客户端（一个插件——安装好的 niffler-tui 包装器可按需启动 harness，并在 /restart 后重新拉起客户端）",
      "screens.note": "<code>./var/bin/niffler</code> 在终端里是管理 shell——help/status/catalog/tools/sessions，不含聊天。对话在 <code>niffler-ui</code> 和 <code>niffler-tui</code> 中进行；脚本走 <code>./var/bin/cli</code>。",
      "wire.title": "一种协议，统领一切",
      "wire.note1": "core → <code>svc.core.call</code>，组件 → <code>svc.&lt;name&gt;.call</code>，<br>事件走 <code>ev.*</code>。这就是全部总线契约。",
      "wire.note2": "规范：<a href=\"https://github.com/gokr/niffler/blob/main/docs/WIRE.md\" target=\"_blank\" rel=\"noopener\">docs/WIRE.md</a> · 理由：<a href=\"https://github.com/gokr/niffler/blob/main/docs/research/REBOOT.md\" target=\"_blank\" rel=\"noopener\">docs/research/REBOOT.md</a>",
      "bench.title": "实测，而非声称",
      "bench.1h": "<span class=\"num\">01</span> SWE-bench 试点",
      "bench.1p": "10 个 sympy 实例、单轮提交，由官方 <code>swebench</code> Docker 环境评分——niffler、pi、opencode 与 claudecode 在多个模型上同场对比。GLM 通道上 niffler 解题数量较少，但每个任务少用 2.3–2.9 倍 token；在 DeepSeek V4.1 Flash（Synthetic，thinking=high）上，同一试点 niffler 以 10/10 对 claudecode 8/10 取胜——首个满分试点成绩。第二个试点 SWE-bench Multilingual（10 个真实 OSS 任务、7 种语言）在配套的 <code>swebench</code> 5.0.2 虚拟环境中运行，用于携带内嵌评测规范的 dataset；其首次运行三条通道均为官方评分 6/10（niffler / pi / claudecode），其中 9 题三条通道判定完全一致。报告：<code>bench/reports/swe-sympy10-*.md</code>。",
      "bench.2h": "<span class=\"num\">02</span> harness 基准",
      "bench.2p": "harness 对比基准框架：30 道基础版本即失败的题目（17 道核心题、10 道面向 2–10 分钟/单元的中级题，以及 3 道扇出题——机械工作逐项各异或中间数据超大，正是 guest 程序与脚本化批量作业发挥作用的场景），按类型标注（general / fabric / expert / selfextend），全部经参考实现验证通过；逐轮反馈循环、受保护文件防篡改、按 provider 统计 token——niffler / pi / opencode / codewhale / claudecode × 多个模型、<code>--thinking low|max</code> 矩阵，另有配对的 niffler-expert 变体用于度量咨询同伴。SWE-bench Verified 与 Datacurve 的 DeepSWE（113 道长程任务）作为额外基准接入；<code>bench/container</code> 提供 Docker 任务镜像，<code>bench/launch.mjs</code> 是引导式启动器。完整 17 题矩阵全通道通过（340/340）；中级题集校准为 20/20（niffler 对 pi，GLM low）；在完整的 30 题题集上，syn-large（Synthetic 的 GLM-5.3-Flash）与 deepseek-v4.1-flash 全部通过——两个模型在 thinking=low 时 niffler 均为 30/30，pi 在 deepseek 的 low 与 high 档均为 30/30（<code>bench/reports/full30-{syn-large,deepseek-v4.1-flash}-*-report.md</code>）；full30 上的首次 claudecode 配对为 30/30 对 30/30，niffler 每回合更精简（平均 7.3 对 9.7 回合）；优化栈上的 niffler 单通道重跑保持 30/30，提示词量约减半（每单元 48 秒 / 20.5k 提示词 token，基线 63 秒 / 38.9k，<code>bench/reports/full30-synlarge-low-niffler-report.md</code>）；瘦身后的 trimmed-prefix 运行保持全绿，high effort 下未命中缓存的输入减少约 40%（<code>bench/reports/full27-syn-large-{low,high}-trimmed-report.md</code>）。",
      "status.title": "状态",
      "status.i18n": "UI + TUI 界面本地化——en/zh/zh-TW 语言环境、CJK 安全的截断与编辑",
      "status.l32": "session_info——LLM 可自省当前对话：模型、effort、上下文占用、消息计数",
      "status.l33": "systemprompt 组件化——对话宪法可通过总线替换",
      "status.l34": "内置 skills——仓库的 skills/ 树随 harness 发布，可被项目/用户目录遮蔽且不可移除",
      "status.l35": "回合内 steer——向运行中的回合注入消息（<code>svc.session.&lt;id&gt;.steer</code>）",
      "status.l36": "expert 咨询同伴——一个 LLM 判定式顾问可同时跟随一个或多个会话：有界观察、回合内 steer、失败即静默",
      "status.l58": "基准扩展——DeepSWE（Datacurve）移植（113 道长程任务、5 种语言）、niffler-bench Docker 任务镜像与引导式启动器；最新完整矩阵全通道通过（340/340）",
      "status.l59": "8 MiB 总线载荷——内置 nats-server 以提高后的 max_payload 运行（上游默认 1 MiB），携带完整对话的聊天请求也能放进大上下文窗口",
      "status.l60": "外部 MCP 服务器——mcp 管理器 + 每个服务器一个受监督桥接进程：服务器的工具、提示词和资源成为目录工具（提示词另作斜杠命令）；惰性沙箱会话、进行中调用取消、契约漂移重启、从 harness 环境解析的 ${ENV} 秘密引用、注册表检索，以及 Web UI 的 MCP 管理面板",
      "status.l61": "工具档案 + 显式发现——命名档案在对话创建时解析为冻结的直接工具集，<code>invoke {sticky: true}</code> 把发现的工具持久提升，<code>/components</code>、<code>/discover</code> 与 <code>/profile</code>（以及组件面板过滤器）无需 LLM 回合即可查看目录状态",
      "status.l62": "基准中级题 t18–t27——核心 17 题饱和后新增的十道规格保真题，目标 2–10 分钟/单元；启动器支持按题名选择，验证脚本执行位已修复；首次校准 niffler 对 pi 20/20",
      "status.l63": "提示词二次瘦身——工具描述只序列化一次（<code>function.description</code>）：冻结提示词前缀从 2479 降至约 1540 token（−38%）",
      "status.l64": "文件工具已读状态——<code>read</code>/<code>write</code>/<code>edit</code> 按（会话，文件）记录对话上次观察到的字节摘要：未变更的整文件重读返回 <code>[unchanged]</code>，字节在之后被改动时 <code>edit</code> 以 <code>E_STALE</code> 拒绝，重读观察到不同字节时修正会持久化",
      "status.l65": "基准 syn-large——在 Synthetic 的 GLM-5.3-Flash（thinking=low）上进行首次 full27 运行：两条通道均在第 1 轮 27/27 全绿，每单元平均 niffler 73 秒 / pi 74 秒（<code>bench/reports/full27-syn-large-low-report.md</code>）",
      "status.l66": "基准扇出题层——题集现为 full30（t01–t30）：三道机械工作逐项各异或中间数据超大的题目——27 个文件的包文档回填、36 个日志文件（约 450 KB）汇总为字节级精确的 summary.json、24 个模块迁移到新 API——单个 <code>sed</code> 无法应付，逐文件编辑会烧掉预算；经 syn-large 基准验证，high 档会动用 fabric",
      "status.l67": "fabric 运行中取消——停止启动该程序的回合（或对其任务执行 <code>agent_stop</code>）会在数秒内结束 guest：进行中的桥接调用被放弃，运行结果报告为 <code>cancelled</code>，排队中的运行被跳过，嵌套的 agent 子任务被一并拆除",
      "status.l68": "fabric 编译型 Nim 执行器——内嵌 VM 已移除：guest 以 <code>nim c</code> 编译为本地进程，相同程序复用内容寻址的二进制缓存（<code>var/fabric-cache</code>），结构化的 <code>fabricguest</code> SDK 取代被 lint 禁止的 VM 接口，<code>fabric_help</code> 按需提供参考文档；任意 Nim ≥ 2.2.12 发行版均可使用",
      "status.l69": "基准 full30 报告——deepseek-v4.1-flash 在 thinking=low 与 high 档双通道全绿；syn-large 全绿，niffler 30/30（pi 覆盖扇出题层）；在编译型 fabric 构建上的 niffler 单通道 high 重跑，在加固后的 t30 验证器下保持 30/30，并附单次运行的方差说明（<code>bench/reports/full30-*.md</code>）",
      "status.l70": "Web UI 斜杠命令注册表——一份注册表驱动分发、<code>/help</code> 与 Tab 补全，并配有针对分发表的漂移测试；<code>/info</code> 展示对话统计（含补全 token）",
      "status.l71": "合并后的 <code>read</code>，<code>grep</code> 进入直接工具集——<code>read</code> 接受单个 <code>path</code> 或规范的 <code>reads</code> 数组（1–12 个 <code>{path, offset?, limit?}</code> 项，逐项报错，相同项去重，合计 512KB 上限），直接工具集因此少一个 schema，批处理形态在读的时候一目了然；<code>grep</code> 输出上限 32KB，宽泛模式不再让对话上下文翻倍",
      "status.l72": "语言服务器接缝——一个 <code>lsp</code> 工具（diagnostics/定义/引用/实现/hover）可对接任意已配置的 stdio 服务器，注册表即数据（7 个内置服务器）、只读 <code>lsp_servers</code>、需审批的 <code>lsp_registry add</code>，以及 niffler-tui 的 <code>/lsp</code> 选择器；<code>make install-lsp</code> 安装默认服务器，core 在打开工作区时预热",
      "status.l73": "plugins 斜杠命令 + 更新语义——<code>/plugins</code>/<code>/plugins-search</code>/<code>/plugins-install</code>/<code>/plugins-update</code>/<code>/plugins-remove</code> 按组件名加前缀；仓库没有 release 时标签解析回退到 tags，分支钉选的安装跟随分支更新，不会被改指到 release 标签",
      "status.l74": "edit 变更预览——编辑成功后返回删除与新增的行及上下文，过大时截断（仅工具结果历史；冻结提示词不变）",
      "status.l75": "UI 注册表 + 外部工作区——交互客户端注册并续租（\"Niffler 1\"、\"Niffler 2\"…），对话所有权由注册表协调，第二个 UI 会被告知当前持有者；对话的 cwd 可以是任意已存在的目录，不再局限于 harness 根目录",
      "status.l76": "流式节奏——附着 token 流时 dispatch 以 5 ms 轮询（其余 100 ms），token 增量按生产速度渲染，不再在 reply-wait 边界被批量合并",
      "status.l77": "后台进程——<code>processes</code> 组件接管长时间运行的命令：bash 的 <code>run_in_background</code> 转发到 <code>process_start</code>，<code>process_poll</code> 增量读取输出，<code>process_kill</code> 停止进程组，<code>registry.json</code> 驱动启动时的孤儿扫描",
      "status.l78": "SQLite 默认存储 + 迁移——SQLite（<code>var/store.db</code>，文档与 rev 原子写入）成为默认引擎；<code>list</code> 是带 <code>after</code>/<code>hasMore</code>/<code>nextAfter</code> 游标的分页，core 的全量读取自动分页；未迁移的 <code>var/barrel-db</code> 会拒绝启动，<code>niffler-store-migrate</code>（<code>--root</code>/<code>--scan</code>/<code>--all</code>/<code>--dry-run</code>）可离线在任意引擎对之间迁移根目录",
      "status.l79": "总线安全——回退到 PATH 的 nats-server 经配置文件取得 8 MiB 载荷上限（core 回退时警告一次），core 启动时检查所连总线的最大载荷，身份回收先验证被复用的 pid 确实是 nats-server 再发信号",
      "status.l80": "基准——SWE-bench Multilingual 试点（10 题、7 种语言）在配套的 <code>swebench</code> 5.0.2 虚拟环境中运行，用于内嵌评测规范的 dataset，首次运行三条通道均为官方评分 6/10；claudecode 通道加入 harness 基准（full30：30/30 对 30/30，niffler 每回合更精简）；在 DeepSeek V4.1 Flash（Synthetic，thinking=high）上 niffler 以 10/10 对 claudecode 8/10 拿下 Sym10 试点；优化栈上的 niffler 单通道 full30 重跑保持 30/30，提示词量减少 47%",
      "status.l81": "上下文压缩——每次 provider 请求前先做准入，配合确定性阶梯（无损修剪 → 摘要压缩 → 整回合裁剪 → 显式 <code>context-recovery-required</code>）、可替换的 contract-v1 压缩器（<code>NIF_COMPACTION_TOOL</code>）、不可变的 canonical 消息与 <code>context_recall</code> 引用、可归因的 <code>reset:*</code> 前缀重建，以及能证明任意 contract-v1 实现的 <code>make test-conformance</code> 运行器",
      "status.l82": "subagent 续聊 + fork——<code>agent_run</code>/<code>agent_spawn {session}</code> 让既有子会话再跑一回合（只追加历史、基于持久血缘关系的授权、busy 与排队两种语义、激活账本、<code>close: true</code> 退役）；<code>fork</code> 用调用方的已完成回合播种全新子会话——从 0 起连续、均衡的裁剪点，失败即拒绝，出生时缓存为冷；未显式指定 <code>model</code> 的新子会话继承父对话的生效模型",
      "status.l83": "<code>/doctor</code> 自检扇出——组件通过隐藏的 <code>selftest</code> 工具（SDK：<code>selfTest()</code>）自检自身；<code>deep: true</code> 会用一次性夹具启动每个已配置的语言服务器并对 store 做完整的 put/get/rev/list/del 往返，报告附带渲染好的 Markdown 表格与 <code>ask: true</code> 解读交接；报告还会说明覆盖面——没有自检的组件列入 <code>selftestMissing</code>（并作为一行 <code>selftest (not implementing)</code> Markdown）而不是被静默省略，两个 Go store 引擎同样注册了隐藏自检",
      "status.l84": "lsp 七个查询操作——<code>documentSymbol</code>（文件大纲）与 <code>workspaceSymbol</code>（全仓库模糊符号搜索）加入接缝；内置注册表默认改为 gopls、nimtortoise（Nim）、typescript-language-server、pyright、rust-analyzer、clangd、bash-language-server、jdtls（Java）与 csharp-ls（C#），<code>make install-lsp</code> 提供对应的按语言安装",
      "status.l85": "委派深度上限 + 键控嵌套租约——<code>NIF_AGENT_MAX_DEPTH</code>（默认 1；0 完全禁止委派）在分发时沿 <code>sessionmeta.parent</code> 链行走，血缘无法验证时失败即拒绝，被拒绝的派生仍能看到工具并得到说明上限与调用方深度的错误；嵌套调用按 id 键控租约校验并带独立截止时间，子会话的同步 <code>agent_run</code> 以可重入方式服务，深度大于 1 也不会循环等待",
      "status.l86": "子代理模型档位——<code>agent_run</code>/<code>agent_spawn</code> 接受 <code>modelTier: weak | medium | strong</code> 为新子会话选型，经 <code>NIF_AGENT_MODEL_WEAK/MEDIUM/STRONG</code> 解析并钳制到父对话的生效档位（<code>NIF_AGENT_DEFAULT_TIER</code>，默认 strong）；与精确 <code>model</code> 互斥，<code>agent_status</code> 报告解析后的档位",
      "status.l87": "子代理通知、名册、持久 steer 与 <code>agent_ask</code>——后台子会话结束时以结算通知送达父对话（是指向 <code>agent_status</code> 完整回复的指针），回合中即时送达或在下一回合顶部统一排空；<code>agent_list {scope}</code> 是派生的子会话名册；对空闲或已退役子会话的 steer 会排入持久的父邮件而不是被静默丢弃；<code>agent_ask {session, question}</code> 从空闲子会话直接取回答案，对回合中的子会话则排队为邮件；<code>session_info</code> 携带血缘信息（fork、激活、closed、子会话计数）",
      "status.l88": "<code>session {export: true}</code>——导出下一回合将要发送的确切 provider 请求（消息、经允许清单过滤的工具 schema、模型、provider、<code>reasoning_effort</code>），不产生用户消息、LLM 调用或 store 写入；与回合自身的请求组装刻意保持同步，便于复现或调试 provider 请求",
      "status.l89": "确定性提示词槽位 + 懒加载指令——组件与插件通过隐藏的 <code>prompt_hint</code> 工具登记片段（命名槽位、聚合或单例、稳定的贡献键），仅对新对话按确定性顺序渲染进 <code>&lt;prompt_slot&gt;</code> 块；<code>AGENTS.local.md</code> 加入指令遮蔽链，读取进入 harness 根目录之下的子树时以 <code>&lt;lazy_project_instructions&gt;</code> 块在工具结果中注入该子树的指令（每会话一次）",
      "status.l90": "fetch 出站守卫——阻止私有目的地并校验重定向：回环、私有、链路本地、CGNAT、组播与未指定地址一律拒绝（IPv4 映射 IPv6 归一化），<code>localhost</code>/<code>.local</code>/<code>.internal</code> 主机名与内嵌凭据的 URL 拒绝，DNS 解析失败即错误，每个重定向跳都重新校验（≤5 跳、仅 http(s)）；<code>NIF_FETCH_ALLOW_PRIVATE=1</code> 恢复本地访问",
      "status.l91": "重试预算按故障类型拆分——带提示的 429 遵循服务器的 <code>Retry-After</code>（由 <code>NIF_LLM_RETRY_AFTER_CAP_MS</code> 封顶、不限尝试次数），未提示的 429、流超时与连接拒绝各有独立的有界预算（<code>NIF_LLM_MAX_STREAM_RETRIES</code>/<code>NIF_LLM_MAX_CONNECT_RETRIES</code>，默认 2），永久性错误快速失败，<code>retry</code> 事件携带 <code>budget</code>/<code>retryAfterMs</code>",
      "status.l92": "部分工具输出随错误一起返回——组件在分发超时或取消时交回已捕获的字节，现在以 <code>ERROR:</code> 原因开头、在 <code>toolcall</code> 事件上标记 <code>error</code> 字段，绝不会被记成普通成功",
      "status.l93": "MCP 直连工具集阈值——配置为 <code>expose: direct</code> 且发布工具数超过 <code>NIF_MCP_DIRECT_THRESHOLD</code>（默认 10）的服务器改为按需标记，避免淹没工具提示词；较小的直连服务器仍前置发布全部工具",
      "status.l94": "压缩实机冒烟——可选的 §8 门禁（<code>SYNTHETIC_API_KEY=... make live-smoke</code>）用真实组件对接真实 provider，度量跨重启的连续性、召回与延迟；报告完成十个审计批次、两次压缩、无损裁剪为零且跨重启连续，一致性夹具还覆盖纯检查点替换实现（<code>NIF_FIXTURE_CHECKPOINT_ONLY=1</code>）",
      "status.l95": "排序仓库地图（repomap 组件）——aider 风格的工作区地图，由 tree-sitter + 原生 Nim 的 tags 图经个性化 PageRank 排序得出；<code>repo_map</code> 是 onDemand 且只读（模型主动询问），工作区打开时的自动附加需显式开启（<code>NIF_REPOMAP_AUTOAPPEND=1</code>）且设有准入门禁（普查下限与字节/符号/文件骨架阈值；<code>bench/reports/repomap-gates-full30.md</code> 验证强制开启时 30/30 个工作区被拦截、0 次发布——A/B 中 +41% 的 token 代价因构造而消失，<code>bench/reports/repomap-ab-*.md</code>）",
      "status.l96": "对话控件——<code>/approvals</code>（本对话的门禁模式：<code>ask</code> 或 <code>auto</code>，auto 高声自动放行）与 <code>/limit rounds|tokens|seconds</code>（软性预算：触及时通过审批通道询问“是否继续”，回答是则延长一步，拒绝或无应答则以明确的 <code>limit-&lt;dimension&gt;</code> 记录结束回合）；两者都属于人类，经 <code>session</code> 调用设置并随对话持久化，而任务级预算与 <code>NIF_MAX_TURN_ROUNDS</code> 保持硬性、绝不协商（无界面自动化用 <code>NIF_AUTO_CONTINUE=1</code>）；回合中到达的 session 调用会立即以 <code>busy</code> 拒绝，不再悬挂到客户端超时",
      "status.l97": "后台进程回报退出——由 <code>run_in_background</code> 启动的子进程结束时发布退出通知（<code>kind: \"process-exited\"</code>，走结算通知通道），被折入所属对话的只追加历史并指向 spool（输出留在 spool，命令文本不随行）；收割改为周期性进行，依托三个 SDK 新增的 <code>onIdle</code> 空闲接缝（Nim 泵循环、TS promise 链、Go ticker goroutine），<code>process_list</code> 不再把已结束的子进程显示为 <code>running</code>，条目还携带 <code>started_at</code>",
      "status.l98": "按 provider 尺度核算上下文——准入计价改用 provider 的 token 尺度而非本地估算；持久化裁剪记录水位线，重放跨重启安全；归一化后的 provider 溢出 400 在转为终态前会获得一次带回执的恢复尝试",
      "status.l99": "SDK 初始连接有界重试——Nim SDK（所有生产组件）现在会在总线绑定期间重试初始 NATS 连接至多 60 秒（感知关停），之后响亮地失败并交给 supervisor 退避；启动/重启时的总线竞态只留在崩溃日志里，不再导致组件崩溃（TS 与 Go 本就自动重连）",
      "status.l100": "桌面 UI 变为插件——<code>ui/</code> 源码已迁至 <code>gokr/niffler-ui</code> 仓库；<code>make install-ui</code> 会启动一个隔离的自动批准 harness，并经插件管理器安装 UI（按最新 release 标签克隆、针对本 harness 构建、发布为 <code>var/bin/niffler-ui</code>），<code>make build</code> 只构建 core + 组件，前端测试也迁入 UI 自己的仓库——<code>make test</code> 重新成为纯粹的总线契约套件",
      "status.l101": "manifest v2 包构建——包可声明 <code>{manifestVersion: 2, components: [{name, lang, project, build: {steps, artifact}}]}</code> 并自带依赖清单与锁文件（<code>package.json</code>/锁文件、<code>go.mod</code>/<code>go.sum</code>、Nimble）；builder 的 <code>build_package</code> 暂存项目、只展开受控的 SDK/输出占位符、执行有界 argv 配方（工具链可以组合——例如 <code>npm ci</code> 后接 <code>wails build</code>——但不允许 shell 包装），并在发布前校验声明的产物",
      "status.l102": "小组件的自愿自检——<code>grep</code>、<code>logfile</code>、<code>observe</code> 与 <code>hooks</code> 注册了 WIRE.md 描述的隐藏 <code>selftest</code>：快速接线检查，外加 deep 探针——真实的有界 rg 搜索、写入真实日志汇、演练 hooks 去重环、经 stdin 管道送入临时文件",
      "status.l37": "订阅制 OAuth——ChatGPT Plus/Pro 与 Claude Pro/Max 登录，令牌自动刷新",
      "status.l38": "持久化 agent 任务——基于 store 记录的 <code>agent_spawn</code>/<code>status</code>/<code>wait</code>/<code>stop</code>/<code>steer</code>；真正的中止取消、惰性预算、陈旧任务恢复",
      "status.l39": "fabric 类型化模式——目录钉选的类型化包装、命名程序库、带摘要键自动批准的审批清单、有界 batch 调用",
      "status.l40": "batch 效应声明——<code>x-harness.effect</code>：读并发执行，写独占执行",
      "status.l41": "生命周期事件 + 活动条——总线上关联的 <code>ev.fabric.*</code>/<code>ev.agent.*</code>，console 与桌面 UI 实时渲染；产物保留清理",
      "status.l42": "SWE-bench Verified 试点——10 个 sympy 实例经官方 Docker 环境评分，niffler/pi/opencode 对比；每个任务少用 2.3–2.9 倍 token",
      "status.l43": "bash 加固——回合取消时终止整个进程树；超大输出溢出到临时文件并用 <code>read</code> 分页读取",
      "status.l44": "subagent 预算——每个任务的 <code>maxCalls</code>/<code>maxTokens</code> 上限冻结进子对话",
      "status.l45": "提示词缓存经济——每个 session 状态事件携带嵌套的 <code>cache {prompt, read, hitRate}</code>（对话头持久化 <code>cachePrompt</code>/<code>cacheRead</code>/<code>cacheHitRate</code>，由 <code>session_info</code> 上报），低的前缀命中率因此可见、可归因",
      "status.l46": "LLM 自动重试——瞬时故障（429/5xx/超时）按指数退避重试，每次重试都有事件播报",
      "status.l47": "并行工具波 + 进程副本——相互独立的调用并行分发；无状态组件可设 <code>replicas: N</code>（grep 默认 ×4）",
      "status.l48": "实时模型 id——<code>provider_models</code> 探测 provider 自己的 <code>/models</code> 端点，以 <code>x-models-source</code> 补丁合并进目录",
      "status.l49": "提示词瘦身——精简 baseprompt 与工具描述，只给 LLM 纯 JSON Schema（首请求 −31%，缓存读 −35%）",
      "status.l50": "hooks + 运维工具——<code>hooks</code> 在总线事件上运行 shell 命令（可选启用）；<code>prompt_preview</code>、<code>doctor</code>、<code>review_receipt</code>、<code>skill_audit</code> 用于检查与交接",
      "status.l51": "dialog——纯 bash 组件：<code>dialog_show</code>/<code>dialog_ask</code> 经 zenity/notify-send 弹出桌面对话框",
      "status.l52": "store 引擎——SQLite（默认）、barrel 与 TiDB/MySQL 由 NIF_STORE_BACKEND 选择；同一总线契约、相同的工具",
      "status.l53": "内置总线服务器——<code>make build</code> 将官方 nats-server 编译进 <code>var/bin/nats-server</code>；core 优先使用它而非 PATH 安装",
      "status.l54": "内置技能 niffler-tools + niffler-harness——该用哪个工具，以及如何操作运行中的 harness",
      "status.l55": "权威的 cli 安装——<code>cli install</code> 以 core 已接受的目录确认注册，而非原始注册广播",
      "status.l56": "一个克隆 = 一个实例——主总线只为本根目录认领（catalog 携带 <code>root</code> + <code>gitHash</code>），遇到陌生 core 高声让位；<code>NIF_NATS_SPAWN=1</code> 强制隔离总线；父进程死亡级联清理，任何子进程都不会比所属 harness 活得更久",
      "status.l57": "<code>make install</code> / <code>make uninstall</code>——将 niffler、niffler-cli、niffler-console 放入 PATH（按需加装 niffler-tui 包装器，<code>WITH_TUI=1</code>）；只安装 niffler 前缀的命令，绝不安装组件二进制，因此 PATH 不会遮蔽 Unix 工具",
      "status.l1": "wire 规范、envelope、Nim + Go + TypeScript SDK",
      "status.l2": "supervisor、catalog、dispatch",
      "status.l3": "bash + builder + store + llm（流式适配器）",
      "status.l4": "agent 端到端为自己添加工具（已使用 DeepSeek 实测）",
      "status.l5": "能力形态跨重启持久化",
      "status.l6": "session 服务 + Wails SPA 外壳",
      "status.l7": "session runner——一个对话 = 一个进程",
      "status.l8": "审批——终端 y/N、带 ack 的定向 UI 请求和广播回退；无界面运行时默认拒绝，并通过 resolved 事件清理状态",
      "status.l9": "恢复模式——<code>make recover</code>",
      "status.l10": "插件——组件生态（发现、安装、更新、移除）",
      "status.l11": "skills——Agent Skills 的渐进发现与加载",
      "status.l12": "fetch——带超时和大小限制的网页内容获取，优先使用 Trafilatura 提取正文",
      "status.l13": "edit——read/edit/write/undo 文件工具（hashline-edit 已提取为 niffler-hashline 插件）",
      "status.l14": "grep + git——仓库搜索和只读 Git 检查",
      "status.l15": "console + cli——在终端中观察并驱动总线",
      "status.l16": "流式输出——UI 里实时 <code>ev.session.&lt;id&gt;.token</code> 增量",
      "status.l17": "UI：组件面板、工具运行视图、明暗主题、About 对话框",
      "status.l18": "总线契约测试套件——<code>make test</code>，每个测试隔离 NATS + 临时根目录",
      "status.l19": "tty 管理 shell——help/status/catalog/tools/sessions，REPL 里没有聊天",
      "status.l20": "observe + logfile——实时观测总线、持久化轮转 JSONL 日志",
      "status.l21": "models——总线上的 models.dev 目录、目录驱动的上下文窗口",
      "status.l22": "provider——基于 store 的 LLM provider 注册表、运行时切换",
      "status.l23": "由 UI 管理 harness 生命周期——桌面图标即整个系统：构建一次，任何 UI 都会自动启动 core，最后一个 UI 退出时停止 core",
      "status.l24": "最小启动配置——<code>--minimal</code> 只启动 store、bash 和 llm，同时保留被跳过的记录",
      "status.l25": "provider/model 控制——已保存的 provider、模型选择、上下文用量指示器和实时 session 状态",
      "status.l26": "渐进式工具发现——每个 session 的直接工具集保持不变，通过 discover/invoke 访问其他工具，并显示 Live Components 可见性状态",
      "status.l27": "fabric——可编程工具调用：LLM 编写 Nim 程序，由编译为本地 guest 进程的执行器运行并从程序内部调用总线工具",
      "status.l28": "subagent session——将任务委派给拥有全新上下文的子 runner，并把结果摘要返回给调用方",
      "status.l29": "斜杠命令——通过 <code>niffler.json</code> 为 UI 声明命令，并将命令注册信息持久化到 store",
      "status.l30": "thinking effort——每个对话可设置 <code>reasoning_effort</code>（ctrl+g），TUI 支持流式显示推理过程",
      "status.l31": "取消——按调用取消 LLM 请求与 TUI 两段式停止（ESC、ESC）",
      "status.t1": "Level 1 UI 动态化（x-ui schema 提示）",
      "status.t3": "store 的 FTS + 向量记忆（TiDB 引擎已落地，检索后续提供）",
      "footer.text": "niffler — 可自我扩展的 agent harness · <a href=\"https://github.com/gokr/niffler\" target=\"_blank\" rel=\"noopener\">github.com/gokr/niffler</a> · <a href=\"https://discord.gg/ThJFEAJUAk\" target=\"_blank\" rel=\"noopener\">discord.gg/ThJFEAJUAk</a>"
    },
    "zh-TW": {
      "meta.title": "Niffler — 可自我擴展的 agent harness",
      "meta.description": "Niffler 是一個極簡、可自我擴展的 agent harness。組件以獨立行程執行並透過 NATS 訊息匯流排通訊；agent 可以在對話過程中撰寫、編譯並啟動自己的工具。",
      "meta.titleComponents": "Niffler — 組件與狀態",
      "meta.descComponents": "Niffler 的每個能力都是獨立的行程組件，透過 NATS 上的 JSON envelope 通訊——內建 Nim、Go 和 TypeScript，可移植到任何語言。",
      "locale.label": "語言",
      "nav.home": "首頁",
      "nav.why": "為什麼",
      "nav.architecture": "架構",
      "nav.quickstart": "快速開始",
      "nav.components": "組件",
      "nav.status": "狀態",
      "nav.gitclone": "git clone",
      "hero.h1": "一個能在對話途中<br><span class=\"accent\">擴展自身能力</span>的 harness。",
      "hero.sub": "Niffler 是一個高度模組化、可自我擴展的 agent harness。組件是以<strong>任意語言</strong>撰寫的<strong>獨立行程</strong>，透過 <strong>NATS 訊息匯流排</strong>通訊；agent 可以在對話過程中自行撰寫、編譯並啟動新工具。",
      "hero.release": " —— 匯流排現在執行純 Nim 的 NATS 客戶端（無需安裝 libnats）；本版本同時發布 <code>niffler-tui</code> 終端客戶端與桌面 UI",
      "hero.badgeAny": "任意語言",
      "hero.ctaMake": "make install-tui && niffler-tui",
      "hero.ctaGithub": "github →",
      "hero.ctaDiscord": "discord →",
      "term.build": "安裝 niffler-tui 終端機客戶端（一個外掛）· 用戶端視需求啟動 harness",
      "term.l1": "→ 主匯流排：已認領 nats://127.0.0.1:4222 · root ~/niffler @ 8094748",
      "term.l2": "→ core 正在監聽 svc.core.call",
      "term.typed": "niffler — 等待輸入…",
      "term.note": "那個終端機是管理 shell（不含聊天）——對話在 niffler-ui 與 niffler-tui 中進行",
      "why.title": "為什麼",
      "why.1h": "<span class=\"num\">01</span> 行程，而非外掛",
      "why.1p": "不需要 <code>dlopen</code>，也不受 ABI 相容性與行程內狀態殘留困擾。每個組件都是獨立行程；停止組件只需結束行程，作業系統會回收相關資源。單一組件當機不會直接拖垮 core 或其他組件。",
      "why.2h": "<span class=\"num\">02</span> 一種協定",
      "why.2p": "Core 只使用一種通訊格式：透過 NATS 傳輸的 JSON envelope。編解碼器約 200 行，僅依賴 <code>std/json</code>。目前提供 Nim、Go 與 TypeScript SDK，也可以移植到其他語言。",
      "why.3h": "<span class=\"num\">03</span> 自我擴展",
      "why.3p": "agent 寫原始碼 → 呼叫 <code>builder.build</code> → 呼叫 <code>core.spawn</code> → 新工具立即可用。新增能力本身就是一次工具呼叫，LLM 可以在對話過程中自行完成整套流程。社群組件也以相同方式安裝：<code>plugin_install</code> 會複製原始碼、編譯並啟動；執行前需經人工確認，且一律從發布的原始碼建置。<code>fabric</code> 更進一步：LLM 可以撰寫掌控整個回合內工具呼叫流程的 Nim guest 程式，由元件編譯為本機行程執行。外部 MCP 伺服器也接入同一條匯流排：<code>mcp</code> 管理器為每個伺服器啟動一個橋接行程，其工具以普通目錄工具的形式出現。",
      "why.4h": "<span class=\"num\">04</span> 能力形態持久化",
      "why.4p": "能力可以跨重啟保留：已啟動的組件記錄在 store 中，並在下次啟動時自動復原。倉庫保存可重現的原始碼；<code>var/bin/</code> 可以重新建置，持久化狀態保存在 store 引擎中（預設 SQLite 的 <code>var/store.db</code>，可透過 <code>NIF_STORE_BACKEND</code> 改用 barrel 或 TiDB）。",
      "arch.title": "架構",
      "arch.core": "對話迴圈 · supervisor<br>catalog · dispatch",
      "arch.note1": "一個對話 = 一個行程：系統為每個對話啟動一個 <code>var/bin/session &lt;id&gt;</code> runner。終止某個 runner 不會影響其他對話。",
      "arch.yourtool": "你的工具",
      "arch.anylang": "任意語言",
      "arch.note2": "每個方框都是一個透過對應語言組件 SDK 建置的小型執行檔——<br>彼此對等、相互隔離，可以獨立停止。",
      "loop.title": "自我擴展迴圈",
      "qs.title": "快速開始",
      "qs.clone": "git clone git@github.com:gokr/niffler.git && cd niffler",
      "qs.setup": "# 安裝環境依賴（Ubuntu / macOS）",
      "qs.env": "# 填入 LLM API key，視需求修改其他設定",
      "qs.make": "# 首次建置 core + 組件（無需 UI 工具鏈）",
      "qs.install": "# 將 niffler / niffler-cli / niffler-console 放入 PATH（視需求加裝 niffler-tui）",
      "qs.installtui": "# 同上，並靜默安裝 niffler-tui 終端機客戶端",
      "qs.installlsp": "# 冪等安裝 lsp 組件的預設語言伺服器",
      "qs.tui": "# 終端機聊天——沒有執行中的 harness 時會視需求啟動一個",
      "qs.installdesktop": "# 桌面 UI——透過外掛生命週期安裝 gokr/niffler-ui 並建置 var/bin/niffler-ui",
      "qs.test": "# 匯流排契約套件——完整門檻，每個測試獨佔 NATS + 暫存根目錄",
      "qs.see": "└─ make run / recover / down / down-here / ram / uninstall / dev · 見 docs/MANUAL.md",
      "qs.requirements": "環境需求",
      "qs.req.nim": "Nim 2.2.12+",
      "qs.req.go": "Go",
      "qs.req.nats": "nats-server（從原始碼建置）",
      "qs.req.node": "Node.js / npm",
      "qs.req.wails": "Wails CLI <span class=\"dim\">（僅建置 niffler-ui 外掛時需要）</span>",
      "qs.req.trafilatura": "Trafilatura <span class=\"dim\">（選用，提供更完整的 HTML 內容擷取）</span>",
      "qs.note": "所有 Nim 依賴都來自 nimble——yaml、htmlparser、checksums、natsnim、bitbarrel——首次建置時自動安裝。",
      "qs.clonehome.h": "一個克隆 = 一個實例",
      "qs.clonehome.p": "harness 只會認領自己的主匯流排（<code>.env</code> 中的 <code>NIF_NATS_URL</code>，預設 <code>nats://127.0.0.1:4222</code>），且僅當應答的 core 服務於本根目錄時才接入——每個 catalog 回應都攜帶 <code>root</code> + <code>gitHash</code>；遇到陌生 core 會明確讓位。開發克隆可設 <code>NIF_NATS_SPAWN=1</code> 取得隔離的隨機埠匯流排，且任何子程序（組件、nats-server）都不會比所屬 harness 活得更久。",
      "comp.title": "內建組件",
      "comp.th.component": "組件",
      "comp.th.language": "語言",
      "comp.th.purpose": "用途",
      "comp.core.p": "對話迴圈、行程管理（supervisor）、組件目錄（catalog）與呼叫分派（dispatch）——以及每次 provider 請求前的上下文視窗准入守衛；屬於人類的兩個對話級控制透過 <code>session</code> 呼叫設定，並以 <code>/approvals</code>（本對話的把關模式：<code>ask</code> 或 <code>auto</code>，auto 會明確地自動放行）與 <code>/limit</code>（軟性 rounds/tokens/seconds 預算，觸及時詢問「是否繼續」而非結束回合）呈現，隨對話持久化；回合進行中抵達的 session 呼叫會立即以 <code>busy</code> 拒絕，不再懸掛；<code>session {export: true}</code> 匯出下一回合將要發送的確切請求（訊息、經允許清單過濾的工具 schema、模型、provider、<code>reasoning_effort</code>），不產生使用者訊息、LLM 呼叫或 store 寫入；逾時或被取消的工具呼叫會帶著部分輸出以明確錯誤回傳，而不是被記成靜默的成功",
      "comp.session.p": "一個對話 = 一個行程——臨時按對話啟動的 runner，從 store 復原；終止一個只會遺失進行中的回合",
      "comp.bash.p": "以工具形式提供 shell 存取；執行前需經人工確認；支援行程樹取消與超大輸出分頁讀取",
      "comp.builder.p": "將 agent 撰寫的原始碼編譯為執行檔，並以 <code>build_package</code> 建置 manifest-v2 外掛專案——相依清單與鎖檔由套件自持，builder 負責暫存專案、只展開受控的 SDK/輸出佔位符、執行有界 argv 配方（不允許 shell 包裝），並驗證宣告的產物",
      "comp.store.p": "匯流排文件儲存，使用版本號（rev）進行樂觀並行控制——同一契約下引擎可互換：SQLite（預設，<code>var/store.db</code>）、barrel 與 TiDB/MySQL，透過 <code>NIF_STORE_BACKEND</code> 選擇；<code>list</code> 是分頁讀取（單頁上限 1000 筆），回傳 <code>hasMore</code> 與 <code>nextAfter</code> 游標，core 自身的全量讀取會自動分頁；存在未遷移 <code>var/barrel-db</code> 歷史的 harness 會拒絕啟動——<code>niffler-store-migrate</code> 可離線在任意引擎對之間遷移根目錄（<code>--scan</code>/<code>--all</code>/<code>--dry-run</code>）",
      "comp.plugins.p": "組件生態：依 topic 搜尋，透過 <code>niffler.json</code> 描述套件——manifest v1 的緊湊形式，或 manifest v2（<code>manifestVersion: 2</code>）專案：由套件自帶相依清單與鎖檔、經 builder 的 <code>build_package</code> 配方建置——支援安裝/更新/移除；一律從原始碼建置；提供依組件名加前綴的 <code>/plugins</code>/<code>/plugins-search</code>/<code>/plugins-install</code>/<code>/plugins-update</code>/<code>/plugins-remove</code> 斜線命令；倉庫沒有發布 release 時標籤解析會回退到它的 tags，分支釘選的安裝會沿分支原地更新，不會被改指到 release 標籤",
      "comp.skills.p": "Agent Skills 的探索、漸進式載入、資源存取，以及受管理的安裝/移除；skill_audit 盤點未合併的磁碟清單；內建的自我知識集同時烘焙進二進位做為最後兜底（<code>NIF_SKILLS_BUNDLED_DIR</code> 可重新定位；烘焙條目回報目錄 <code>(baked)</code>）",
      "comp.systemprompt.p": "對話憲法組件化——session runner 每個對話只呼叫一次 <code>svc.systemprompt.call</code> 取得系統提示詞；替換組件即可替換憲法。組件與外掛透過隱藏的 <code>prompt_hint</code> 工具登記提示詞片段——命名槽位（<code>tool_usage</code>、<code>efficient_tools</code>、<code>after_instructions</code>）在新對話中按確定性順序渲染進 <code>&lt;prompt_slot&gt;</code> 區塊，絕不改寫已凍結的提示詞——指令還按需懶載入：<code>AGENTS.local.md</code> 加入遮蔽鏈，讀取進入 monorepo 子目錄時以工具結果注入該子樹的規則（每個工作階段一次），不佔用系統前綴",
      "comp.recall.p": "隱藏的 <code>context_recall</code> 解析器——被修剪與溢出的內容以參照替代，本組件負責解析它們：canonical 訊息、晉升的溢出文件與目前持久的 compaction 檢查點；每條修剪/溢出通知都逐字給出參照名，讓 recall 可被發現",
      "comp.compaction.p": "可替換的上下文摘要器——長回合能在自己的上下文中存活：每次 provider 請求前 core 都會按 provider 自己的 token 尺度估算請求規模，在壓力線執行確定性階梯（無損工具結果修剪 → 摘要壓縮 → 整回合裁剪 → 明確的 <code>context-recovery-required</code>），絕不送出超出視窗的請求；持久化裁剪會記錄水位線，重放可跨重啟安全進行，正規化後的 provider 溢位 400 會先獲得一次帶回執的復原嘗試再轉為終態。本組件是預設的 contract-v1 <code>compaction_propose</code> 實作（<code>NIF_COMPACTION_TOOL</code> 可選擇其他實作）：它校驗 runner 的分頁快照、選擇允許的裁剪點並起草檢查點候選——只有 runner 會驗證並提交 <code>context_projection</code>，canonical 訊息保持不可變；任何 contract-v1 實作都可用 <code>make test-conformance</code> 對照契約驗證",
      "comp.fetch.p": "具有逾時與大小限制的 HTTP(S) 內容擷取，支援 method/header/body；優先使用 Trafilatura 擷取 HTML，並提供純 Nim 備援方案與大型結果寫入檔案。出站存取失敗即拒絕：預先解析主機，回環、私有、鏈路本地、電信級 NAT、群播與未指定位址一律拒絕（IPv4 對映 IPv6 正規化處理），<code>localhost</code>/<code>.localhost</code>/<code>.local</code>/<code>.internal</code> 主機名、內嵌憑證的 URL 以及 DNS 解析失敗同樣拒絕；重定向逐跳重新校驗，上限五跳且僅限 http(s)。<code>NIF_FETCH_ALLOW_PRIVATE=1</code> 可為可信的本地開發恢復回環存取",
      "comp.edit.p": "檔案工具：<code>read</code>（單一 <code>path</code>，或用規範的 <code>reads</code> 陣列一次批次讀取最多 12 個檔案/區間，逐項回報錯誤，可分頁；對有語言伺服器支援的大檔整讀時回傳 lsp 符號大綱——可用 offset/limit 開窗，或 <code>offset: 1</code> 強制整讀）、帶守衛回退級聯的精確匹配 <code>edit</code>、原子 <code>write</code>、單層復原（<code>undo_last_edit</code>）；未變更的整檔重讀回傳精簡的 <code>[unchanged]</code> 標記而不重複輸出位元組（<code>force</code> 或視窗讀取可重新輸出），檔案在對話上次見過後被改動時 <code>edit</code> 以 <code>E_STALE</code> 拒絕——重讀觀察到不同位元組時會持久化該摘要修正，陳舊狀態不會跨重啟殘留——已讀狀態按（會話，檔案）記錄；<code>edit</code> 成功後回傳精簡的變更預覽（刪除/新增的行及上下文，過大時明確截斷）；修改操作需經人工確認",
      "comp.lsp.p": "語言伺服器接縫——一個 <code>lsp</code> 工具（不必跑測試即可取得 <code>diagnostics</code>、<code>documentSymbol</code>——檔案大綱、<code>workspaceSymbol</code>——全倉庫模糊符號搜尋、<code>goToDefinition</code>、<code>findReferences</code>、<code>goToImplementation</code>、<code>hover</code>），可對接任意已設定的 stdio 語言伺服器（預設 gopls、nimtortoise、typescript-language-server、pyright、rust-analyzer、clangd、bash-language-server、jdtls、csharp-ls）；登錄檔是資料（<code>$XDG_CONFIG_HOME/niffler-lsp/servers.json</code>）——新增一門語言只是加一筆設定，或由 agent 自己發起需核准的 <code>lsp_registry add</code>，絕不需要寫程式；<code>make install-lsp</code> 依語言安裝預設語言伺服器，core 會在開啟工作區時按清單預熱它們；唯讀的 <code>lsp_servers</code> 列出合併後的登錄檔，niffler-tui 的 <code>/lsp</code> 可瀏覽並編輯它",
      "comp.repomap.p": "排序後的倉庫地圖（aider repomap 的移植）——以約 1KB 的篇幅給出最關鍵的檔案及其關鍵定義，由 tree-sitter + 原生 Nim 的 tags 圖經個人化 PageRank 排序得出；<code>repo_map</code> 是 onDemand 且唯讀的工具：模型主動詢問，絕不主動注入。工作區開啟時的自動附加（每個新對話一筆僅附加條目）需透過 <code>NIF_REPOMAP_AUTOAPPEND=1</code> 明確開啟——預設關閉，因為 A/B 顯示 token 代價增加而準確率無收益——即使開啟也設有門檻：低於普查下限（<code>NIF_REPOMAP_MIN_CENSUS</code>，預設 50）的工作區不建圖，骨架地圖（位元組/符號/檔案門檻）不注入，被攔截的地圖會留下日誌。快取位於 <code>var/repomap-tags/</code>；組件缺席只意味著沒有地圖，別無影響",
      "comp.processes.p": "有主的背景行程——bash 的 <code>run_in_background</code> 旗標轉送到 <code>process_start</code>（脫離工作階段、獨立行程群組、spool 檔案在 <code>var/processes/</code> 下）；<code>process_poll</code> 增量讀取輸出，<code>process_kill</code> 停止行程群組，<code>process_list</code> 檢視登錄檔並攜帶 <code>started_at</code>；子行程是行程群組組長，<code>registry.json</code> 驅動啟動時的孤兒掃描——結束的子行程會通知其對話：退出通知（<code>kind: \"process-exited\"</code>，與 subagent 結算通知同一條通道）被折入僅附加歷史並指向 spool（「執行 412 秒、8123 位元組輸出——用 process_poll 讀取」）；組件透過 SDK 的 <code>onIdle</code> 週期性收割子行程，無需有人輪詢也能發現退出",
      "comp.grep.p": "以 ripgrep 為基礎的內容搜尋（<code>grep</code>——預設直接工具集，輸出按行數與 32KB 位元組上限截斷）與排序後的倉庫檔案清單（<code>files</code>——按需載入），提供明確的截斷標記",
      "comp.git.p": "唯讀倉庫檢查：<code>status</code>/<code>diff</code>/<code>log</code>/<code>show</code>/<code>blame</code>；無需核准，固定 argv，路徑限定在 harness 根目錄；另有 <code>review_receipt</code> 做推送前的 diff 指紋交接",
      "comp.hooks.p": "操作員 shell 指令，掛在選定的匯流排事件上（<code>ev.session.*.turn</code>、<code>ev.log.&gt;</code>）——stdin 接收 JSON 承載，只觀察不干預，由環境變數設定，預設關閉",
      "comp.observe.p": "即時檢視匯流排——subject 探索、監聽、請求/回應追蹤與監控",
      "comp.logfile.p": "將 <code>ev.log.*</code> 持久化為 JSONL——支援日誌輪替、範圍受限的搜尋與保留策略",
      "comp.models.p": "透過匯流排提供 models.dev 的 provider/model 目錄——內建離線資料、快取更新與 <code>x-models-source</code> 外掛修補",
      "comp.provider.p": "以 store 為基礎的 LLM provider 登錄檔——add/list/switch/active/remove/export/import，執行期間切換後端，訂閱制 OAuth 登入並自動輪換權杖；provider_models 探測 provider 自己的 /models 端點取得即時模型 id",
      "comp.llm.p": "串流聊天 adapter——預設 OpenAI 相容 Chat Completions（DeepSeek），另支援 OpenAI Codex（ChatGPT OAuth）Responses 與 Anthropic Messages 協定——即時 <code>ev.llm.token</code> token 串流、推理 token，以及單次呼叫取消；重試按故障類型拆分預算——帶 <code>Retry-After</code> 的 429 按伺服器指示等待（封頂、不限嘗試次數），串流逾時與連線拒絕各有獨立的有界預算（<code>NIF_LLM_MAX_STREAM_RETRIES</code>/<code>NIF_LLM_MAX_CONNECT_RETRIES</code>，預設 2），永久性錯誤（鑑權、配額、錯誤請求）快速失敗",
      "comp.mcp.p": "把外部 MCP 伺服器（Model Context Protocol）變成匯流排組件——以 store 為基礎的註冊表，帶需核准的 <code>mcp_add</code>/<code>mcp_edit</code>/<code>mcp_remove</code>（每次新增/編輯都透過一次真實連線驗證）、檢索官方 MCP Registry 的 <code>mcp_search</code>，以及在連線時從 harness 環境解析 <code>${ENV}</code> 秘密引用（權杖不入庫）；伺服器的工具成為普通目錄工具，經 <code>discover</code> + <code>invoke</code> 呼叫；設定為 <code>expose: direct</code> 且發布工具數超過 <code>NIF_MCP_DIRECT_THRESHOLD</code>（預設 10）的伺服器會改為按需探索，避免淹沒工具提示詞",
      "comp.mcpbridge.p": "每個 MCP 伺服器一個受監督行程（官方 Go SDK；stdio / streamable HTTP / SSE）——閒置即退出的惰性工作階段、確保伺服器不比 harness 活得更久的 stdio 守護、進行中呼叫的取消、工具契約漂移時持久化並重啟橋接以保持探索結果真實、提示詞變成斜線命令、資源收斂為一個讀取工具、超過 64 KiB 的結果寫入檔案",
      "comp.fabric.p": "可程式化工具呼叫——LLM 撰寫 Nim 程式掌控回合內控制流程；每個程式都編譯為本機 guest 行程（內容定址的二進位快取、結構化的 <code>fabricguest</code> SDK、按需的 <code>fabric_help</code> 參考文件），回合被取消時數秒內即被終止；帶目錄釘選的型別化包裝、命名程式庫、宿主並行的 <code>batch</code> 呼叫、核准清單，以及依 runId 關聯的 <code>ev.fabric.*</code> 生命週期事件——組件還自帶經實際執行驗證的範例程式",
      "comp.agent.p": "subagent 對話——同步 <code>agent_run</code> 把任務委派給擁有全新脈絡的子 runner；持久化背景任務（<code>agent_spawn</code>/<code>status</code>/<code>wait</code>/<code>stop</code>/<code>steer</code>）跨重啟存續；子對話是有記憶的對話：<code>agent_run</code>/<code>agent_spawn {session}</code> 讓既有子對話再跑一回合（僅附加歷史、基於持久血緣關係的授權、busy 與排隊兩種語義、激活帳本、<code>close: true</code> 退役），<code>fork: true | {lastK} | {maxChars}</code> 用呼叫方的已完成回合播種一個全新子對話；未明確指定 <code>model</code> 的新子對話繼承父對話的生效模型，也可用 <code>modelTier: weak | medium | strong</code>（會被鉗制到父對話的層級）；委派深度有上限（<code>NIF_AGENT_MAX_DEPTH</code>，預設 1——子代理不能再派生子代理），巢狀呼叫使用按 id 鍵控、帶獨立期限的租約，並行的對話脈絡分派因此安全；已結束的背景子對話以結算通知送達父對話（是指向 <code>agent_status</code> 所回傳完整回覆的指標），無需輪詢；<code>agent_list</code> 給出派生的子對話名冊，對閒置子對話的 steer 會排入持久的父郵件並在其下一回合送達，<code>agent_ask</code> 回傳子對話的回答；閒置 runner 自動退役",
      "comp.expert.p": "諮詢同伴——可同時跟隨一個或多個工作中的對話，對每個對話的有界觀察做 LLM 判定（判定前綴內嵌內建的 niffler-tools/niffler-fabric/niffler-harness 技能），只把高置信度的 steer 作為標記訊息投遞；預設沉默、失敗即靜默",
      "comp.dialog.p": "純 bash 組件——<code>dialog_show</code>/<code>dialog_ask</code> 桌面對話框（zenity → notify-send → 日誌回退），只用 nats CLI + jq 說 envelope，無 SDK、無需編譯",
      "comp.cli.p": "透過腳本驅動 harness：<code>catalog</code>/<code>wait</code>/<code>call</code>/<code>install</code>——外掛倉庫的標準 CI 入口；安裝確認以 core 已接受的目錄為準，而非原始註冊廣播",
      "comp.nats.p": "匯流排伺服器本身，從原始碼建置——components/nats 將官方 nats-server 編譯為 <code>var/bin/nats-server</code>；core 優先使用該執行檔而非 PATH 安裝，因此僅 <code>make build</code> 即可滿足匯流排依賴；內建建置以 8 MiB 承載上限執行（上游預設 1 MiB），攜帶完整對話的 LLM 請求也放得下；回退到 PATH 安裝時經設定檔取得同樣的 8 MiB 上限（core 回退時會警告一次），core 還會在啟動時檢查所連匯流排的最大承載，發現不足就明確警告而不是在對話中途失敗",
      "comp.console.p": "匯流排檢視器——將每個 envelope 輸出到 stdout，可在第二個終端機中即時查看",
      "comp.ui.p": "桌面聊天 UI，以互動外掛 gokr/niffler-ui 發布（原始碼在獨立倉庫中）——對話、串流 token、工具執行、核准、模型控制；由 Wails 承載的 SPA，架構上是 NATS client；<code>make install-ui</code> 經外掛生命週期安裝（依最新 release 標籤複製、針對本 harness 建置、發布為 <code>var/bin/niffler-ui</code>）——由使用者手動啟動，絕不會被 spawn 為服務",
      "comp.your.p": "移植 SDK；envelope 是跨語言契約（約 200 行）",
      "comp.your.name": "你的工具",
      "comp.your.lang": "任意",
      "screens.ui.name": "niffler-ui",
      "screens.ui.desc": "桌面聊天 UI：對話、串流 token、工具執行、核准、模型控制（一個外掛——make install-ui 安裝 gokr/niffler-ui）",
      "screens.tui.name": "niffler-tui",
      "screens.tui.desc": "終端機聊天客戶端（一個外掛——安裝好的 niffler-tui 包裝器可視需求啟動 harness，並在 /restart 後重新執行客戶端）",
      "screens.note": "<code>./var/bin/niffler</code> 在終端機裡是管理 shell——help/status/catalog/tools/sessions，不含聊天。對話在 <code>niffler-ui</code> 和 <code>niffler-tui</code> 中進行；腳本走 <code>./var/bin/cli</code>。",
      "wire.title": "一種協定，統領一切",
      "wire.note1": "core → <code>svc.core.call</code>，組件 → <code>svc.&lt;name&gt;.call</code>，<br>事件走 <code>ev.*</code>。這就是全部匯流排契約。",
      "wire.note2": "規範：<a href=\"https://github.com/gokr/niffler/blob/main/docs/WIRE.md\" target=\"_blank\" rel=\"noopener\">docs/WIRE.md</a> · 理由：<a href=\"https://github.com/gokr/niffler/blob/main/docs/research/REBOOT.md\" target=\"_blank\" rel=\"noopener\">docs/research/REBOOT.md</a>",
      "bench.title": "實測，而非聲稱",
      "bench.1h": "<span class=\"num\">01</span> SWE-bench 試點",
      "bench.1p": "10 個 sympy 實例、單輪提交，由官方 <code>swebench</code> Docker 環境評分——niffler、pi、opencode 與 claudecode 在多個模型上同場對比。GLM 通道上 niffler 解題數量較少，但每個任務少用 2.3–2.9 倍 token；在 DeepSeek V4.1 Flash（Synthetic，thinking=high）上，同一試點 niffler 以 10/10 對 claudecode 8/10 取勝——首個滿分試點成績。第二個試點 SWE-bench Multilingual（10 個真實 OSS 任務、7 種語言）在配套的 <code>swebench</code> 5.0.2 虛擬環境中執行，用於攜帶內嵌評測規範的 dataset；其首次執行三條通道均為官方評分 6/10（niffler / pi / claudecode），其中 9 題三條通道判定完全一致。報告：<code>bench/reports/swe-sympy10-*.md</code>。",
      "bench.2h": "<span class=\"num\">02</span> harness 基準",
      "bench.2p": "harness 對比基準框架：30 道基礎版本即失敗的題目（17 道核心題、10 道面向 2–10 分鐘/單元的中級題，以及 3 道扇出題——機械工作逐項各異或中間資料超大，正是 guest 程式與腳本化批次作業發揮作用的場景），依類型標註（general / fabric / expert / selfextend），全部經參考實作驗證通過；逐輪回饋迴圈、受保護檔案防竄改、依 provider 統計 token——niffler / pi / opencode / codewhale / claudecode × 多個模型、<code>--thinking low|max</code> 矩陣，另有配對的 niffler-expert 變體用於度量諮詢同伴。SWE-bench Verified 與 Datacurve 的 DeepSWE（113 道長程任務）作為額外基準接入；<code>bench/container</code> 提供 Docker 任務映像，<code>bench/launch.mjs</code> 是引導式啟動器。完整 17 題矩陣全通道通過（340/340）；中級題集校準為 20/20（niffler 對 pi，GLM low）；在完整的 30 題題集上，syn-large（Synthetic 的 GLM-5.3-Flash）與 deepseek-v4.1-flash 全部通過——兩個模型在 thinking=low 時 niffler 均為 30/30，pi 在 deepseek 的 low 與 high 檔均為 30/30（<code>bench/reports/full30-{syn-large,deepseek-v4.1-flash}-*-report.md</code>）；full30 上的首次 claudecode 配對為 30/30 對 30/30，niffler 每回合更精簡（平均 7.3 對 9.7 回合）；優化棧上的 niffler 單通道重跑保持 30/30，提示詞量約減半（每單元 48 秒 / 20.5k 提示詞 token，基準 63 秒 / 38.9k，<code>bench/reports/full30-synlarge-low-niffler-report.md</code>）；瘦身後的 trimmed-prefix 執行保持全綠，high effort 下未命中快取的輸入減少約 40%（<code>bench/reports/full27-syn-large-{low,high}-trimmed-report.md</code>）。",
      "status.title": "狀態",
      "status.i18n": "UI + TUI 介面在地化——en/zh/zh-TW 語言環境、CJK 安全的截斷與編輯",
      "status.l32": "session_info——LLM 可自省當前對話：模型、effort、脈絡占用、訊息計數",
      "status.l33": "systemprompt 組件化——對話憲法可透過匯流排替換",
      "status.l34": "內建 skills——倉庫的 skills/ 樹隨 harness 發布，可被專案/使用者目錄遮蔽且不可移除",
      "status.l35": "回合內 steer——向執行中的回合注入訊息（<code>svc.session.&lt;id&gt;.steer</code>）",
      "status.l36": "expert 諮詢同伴——一個 LLM 判定式顧問可同時跟隨一個或多個對話：有界觀察、回合內 steer、失敗即靜默",
      "status.l58": "基準擴充——DeepSWE（Datacurve）移植（113 道長程任務、5 種語言）、niffler-bench Docker 任務映像與引導式啟動器；最新完整矩陣全通道通過（340/340）",
      "status.l59": "8 MiB 匯流排承載——內建 nats-server 以提高後的 max_payload 執行（上游預設 1 MiB），攜帶完整對話的聊天請求也能放進大上下文視窗",
      "status.l60": "外部 MCP 伺服器——mcp 管理器 + 每個伺服器一個受監督橋接行程：伺服器的工具、提示詞和資源成為目錄工具（提示詞另作斜線命令）；惰性沙箱工作階段、進行中呼叫取消、契約漂移重啟、從 harness 環境解析的 ${ENV} 秘密引用、註冊表檢索，以及 Web UI 的 MCP 管理面板",
      "status.l61": "工具設定檔 + 顯式探索——具名設定檔在對話建立時解析為凍結的直接工具集，<code>invoke {sticky: true}</code> 把探索到的工具持久晉升，<code>/components</code>、<code>/discover</code> 與 <code>/profile</code>（以及組件面板篩選器）無需 LLM 回合即可檢視目錄狀態",
      "status.l62": "基準中級題 t18–t27——核心 17 題飽和後新增的十道規格保真題，目標 2–10 分鐘/單元；啟動器支援按題名選擇，驗證指令稿執行位已修復；首次校準 niffler 對 pi 20/20",
      "status.l63": "提示詞二次瘦身——工具描述只序列化一次（<code>function.description</code>）：凍結提示詞前綴從 2479 降至約 1540 token（−38%）",
      "status.l64": "檔案工具已讀狀態——<code>read</code>/<code>write</code>/<code>edit</code> 按（會話，檔案）記錄對話上次觀察到的位元組摘要：未變更的整檔重讀回傳 <code>[unchanged]</code>，位元組在之後被改動時 <code>edit</code> 以 <code>E_STALE</code> 拒絕，重讀觀察到不同位元組時修正會持久化",
      "status.l65": "基準 syn-large——在 Synthetic 的 GLM-5.3-Flash（thinking=low）上進行首次 full27 執行：兩條通道均在第 1 輪 27/27 全綠，每單元平均 niffler 73 秒 / pi 74 秒（<code>bench/reports/full27-syn-large-low-report.md</code>）",
      "status.l66": "基準扇出題層——題集現為 full30（t01–t30）：三道機械工作逐項各異或中間資料超大的題目——27 個檔案的套件文件回填、36 個日誌檔（約 450 KB）彙總為位元組級精確的 summary.json、24 個模組遷移到新 API——單一 <code>sed</code> 無法應付，逐檔編輯會燒掉預算；經 syn-large 基準驗證，high 檔會動用 fabric",
      "status.l67": "fabric 執行中取消——停止啟動該程式的回合（或對其任務執行 <code>agent_stop</code>）會在數秒內結束 guest：進行中的橋接呼叫被放棄，執行結果回報為 <code>cancelled</code>，排隊中的執行被略過，巢狀的 agent 子任務被一併拆除",
      "status.l68": "fabric 編譯型 Nim 執行器——內嵌 VM 已移除：guest 以 <code>nim c</code> 編譯為本機行程，相同程式重複使用內容定址的二進位快取（<code>var/fabric-cache</code>），結構化的 <code>fabricguest</code> SDK 取代被 lint 禁止的 VM 介面，<code>fabric_help</code> 按需提供參考文件；任意 Nim ≥ 2.2.12 發行版均可使用",
      "status.l69": "基準 full30 報告——deepseek-v4.1-flash 在 thinking=low 與 high 檔雙通道全綠；syn-large 全綠，niffler 30/30（pi 覆蓋扇出題層）；在編譯型 fabric 建置上的 niffler 單通道 high 重跑，在加固後的 t30 驗證器下保持 30/30，並附單次執行的變異數說明（<code>bench/reports/full30-*.md</code>）",
      "status.l70": "Web UI 斜線命令註冊表——一份註冊表驅動分派、<code>/help</code> 與 Tab 補全，並配有針對分派表的漂移測試；<code>/info</code> 顯示對話統計（含補全權杖）",
      "status.l71": "合併後的 <code>read</code>，<code>grep</code> 進入直接工具集——<code>read</code> 接受單一 <code>path</code> 或規範的 <code>reads</code> 陣列（1–12 個 <code>{path, offset?, limit?}</code> 項，逐項回報錯誤，相同項去重，合計 512KB 上限），直接工具集因此少一個 schema，批次形態在讀的時候一目瞭然；<code>grep</code> 輸出上限 32KB，寬泛模式不再讓對話脈絡翻倍",
      "status.l72": "語言伺服器接縫——一個 <code>lsp</code> 工具（diagnostics/定義/引用/實作/hover）可對接任意已設定的 stdio 伺服器，登錄檔即資料（7 個內建伺服器）、唯讀 <code>lsp_servers</code>、需核准的 <code>lsp_registry add</code>，以及 niffler-tui 的 <code>/lsp</code> 選擇器；<code>make install-lsp</code> 安裝預設伺服器，core 在開啟工作區時預熱",
      "status.l73": "plugins 斜線命令 + 更新語義——<code>/plugins</code>/<code>/plugins-search</code>/<code>/plugins-install</code>/<code>/plugins-update</code>/<code>/plugins-remove</code> 依組件名加前綴；倉庫沒有 release 時標籤解析回退到 tags，分支釘選的安裝沿分支更新，不會被改指到 release 標籤",
      "status.l74": "edit 變更預覽——編輯成功後回傳刪除與新增的行及上下文，過大時截斷（僅工具結果歷史；凍結提示詞不變）",
      "status.l75": "UI 登錄檔 + 外部工作區——互動用戶端註冊並續租（\"Niffler 1\"、\"Niffler 2\"…），對話所有權由登錄檔協調，第二個 UI 會被告知目前持有者；對話的 cwd 可以是任意已存在的目錄，不再侷限於 harness 根目錄",
      "status.l76": "串流節奏——附著 token 串流時 dispatch 以 5 ms 輪詢（其餘 100 ms），token 增量按生產速度呈現，不再在 reply-wait 邊界被批次合併",
      "status.l77": "背景行程——<code>processes</code> 組件接管長時間執行的命令：bash 的 <code>run_in_background</code> 轉送到 <code>process_start</code>，<code>process_poll</code> 增量讀取輸出，<code>process_kill</code> 停止行程群組，<code>registry.json</code> 驅動啟動時的孤兒掃描",
      "status.l78": "SQLite 預設儲存 + 遷移——SQLite（<code>var/store.db</code>，文件與 rev 原子寫入）成為預設引擎；<code>list</code> 是帶 <code>after</code>/<code>hasMore</code>/<code>nextAfter</code> 游標的分頁，core 的全量讀取自動分頁；未遷移的 <code>var/barrel-db</code> 會拒絕啟動，<code>niffler-store-migrate</code>（<code>--root</code>/<code>--scan</code>/<code>--all</code>/<code>--dry-run</code>）可離線在任意引擎對之間遷移根目錄",
      "status.l79": "匯流排安全——回退到 PATH 的 nats-server 經設定檔取得 8 MiB 承載上限（core 回退時警告一次），core 啟動時檢查所連匯流排的最大承載，身分回收先驗證被重複使用的 pid 確實是 nats-server 再發訊號",
      "status.l80": "基準——SWE-bench Multilingual 試點（10 題、7 種語言）在配套的 <code>swebench</code> 5.0.2 虛擬環境中執行，用於內嵌評測規範的 dataset，首次執行三條通道均為官方評分 6/10；claudecode 通道加入 harness 基準（full30：30/30 對 30/30，niffler 每回合更精簡）；在 DeepSeek V4.1 Flash（Synthetic，thinking=high）上 niffler 以 10/10 對 claudecode 8/10 拿下 Sym10 試點；優化棧上的 niffler 單通道 full30 重跑保持 30/30，提示詞量減少 47%",
      "status.l81": "上下文壓縮——每次 provider 請求前先做准入，搭配確定性階梯（無損修剪 → 摘要壓縮 → 整回合裁剪 → 明確的 <code>context-recovery-required</code>）、可替換的 contract-v1 壓縮器（<code>NIF_COMPACTION_TOOL</code>）、不可變的 canonical 訊息與 <code>context_recall</code> 參照、可歸因的 <code>reset:*</code> 前綴重建，以及能證明任意 contract-v1 實作的 <code>make test-conformance</code> 執行器",
      "status.l82": "subagent 續聊 + fork——<code>agent_run</code>/<code>agent_spawn {session}</code> 讓既有子對話再跑一回合（僅附加歷史、基於持久血緣關係的授權、busy 與排隊兩種語義、激活帳本、<code>close: true</code> 退役）；<code>fork</code> 用呼叫方的已完成回合播種全新子對話——從 0 起連續、均衡的裁剪點，失敗即拒絕，出生時快取為冷；未明確指定 <code>model</code> 的新子對話繼承父對話的生效模型",
      "status.l83": "<code>/doctor</code> 自檢扇出——組件透過隱藏的 <code>selftest</code> 工具（SDK：<code>selfTest()</code>）自檢自身；<code>deep: true</code> 會用一次性夾具啟動每個已設定的語言伺服器，並對 store 做完整的 put/get/rev/list/del 往返，報告附帶渲染好的 Markdown 表格與 <code>ask: true</code> 解讀交接；報告還會說明覆蓋面——沒有自檢的組件列入 <code>selftestMissing</code>（並作為一行 <code>selftest (not implementing)</code> Markdown）而不是被靜默省略，兩個 Go store 引擎同樣註冊了隱藏自檢",
      "status.l84": "lsp 七個查詢操作——<code>documentSymbol</code>（檔案大綱）與 <code>workspaceSymbol</code>（全倉庫模糊符號搜尋）加入接縫；內建登錄檔預設改為 gopls、nimtortoise（Nim）、typescript-language-server、pyright、rust-analyzer、clangd、bash-language-server、jdtls（Java）與 csharp-ls（C#），<code>make install-lsp</code> 提供對應的依語言安裝",
      "status.l85": "委派深度上限 + 鍵控巢狀租約——<code>NIF_AGENT_MAX_DEPTH</code>（預設 1；0 完全禁止委派）在分派時沿 <code>sessionmeta.parent</code> 鏈行走，血緣無法驗證時失敗即拒絕，被拒絕的派生仍能看到工具並得到說明上限與呼叫方深度的錯誤；巢狀呼叫按 id 鍵控租約校驗並帶獨立期限，子對話的同步 <code>agent_run</code> 以可重入方式服務，深度大於 1 也不會循環等待",
      "status.l86": "子代理模型層級——<code>agent_run</code>/<code>agent_spawn</code> 接受 <code>modelTier: weak | medium | strong</code> 為新子對話選型，經 <code>NIF_AGENT_MODEL_WEAK/MEDIUM/STRONG</code> 解析並鉗制到父對話的生效層級（<code>NIF_AGENT_DEFAULT_TIER</code>，預設 strong）；與精確 <code>model</code> 互斥，<code>agent_status</code> 回報解析後的層級",
      "status.l87": "子代理通知、名冊、持久 steer 與 <code>agent_ask</code>——背景子對話結束時以結算通知送達父對話（是指向 <code>agent_status</code> 完整回覆的指標），回合中即時送達或在下一回合頂部統一排空；<code>agent_list {scope}</code> 是派生的子對話名冊；對閒置或已退役子對話的 steer 會排入持久的父郵件而不是被靜默丟棄；<code>agent_ask {session, question}</code> 從閒置子對話直接取回答案，對回合中的子對話則排隊為郵件；<code>session_info</code> 攜帶血緣資訊（fork、激活、closed、子對話計數）",
      "status.l88": "<code>session {export: true}</code>——匯出下一回合將要發送的確切 provider 請求（訊息、經允許清單過濾的工具 schema、模型、provider、<code>reasoning_effort</code>），不產生使用者訊息、LLM 呼叫或 store 寫入；與回合自身的請求組裝刻意保持同步，便於重現或偵錯 provider 請求",
      "status.l89": "確定性提示詞槽位 + 懶載入指令——組件與外掛透過隱藏的 <code>prompt_hint</code> 工具登記片段（命名槽位、聚合或單例、穩定的貢獻鍵），僅對新對話按確定性順序渲染進 <code>&lt;prompt_slot&gt;</code> 區塊；<code>AGENTS.local.md</code> 加入指令遮蔽鏈，讀取進入 harness 根目錄之下的子樹時以 <code>&lt;lazy_project_instructions&gt;</code> 區塊在工具結果中注入該子樹的指令（每個工作階段一次）",
      "status.l90": "fetch 出站守衛——阻擋私有目的地並校驗重定向：回環、私有、鏈路本地、CGNAT、群播與未指定位址一律拒絕（IPv4 對映 IPv6 正規化），<code>localhost</code>/<code>.local</code>/<code>.internal</code> 主機名與內嵌憑證的 URL 拒絕，DNS 解析失敗即錯誤，每個重定向跳都重新校驗（≤5 跳、僅 http(s)）；<code>NIF_FETCH_ALLOW_PRIVATE=1</code> 恢復本地存取",
      "status.l91": "重試預算按故障類型拆分——帶提示的 429 遵循伺服器的 <code>Retry-After</code>（由 <code>NIF_LLM_RETRY_AFTER_CAP_MS</code> 封頂、不限嘗試次數），未提示的 429、串流逾時與連線拒絕各有獨立的有界預算（<code>NIF_LLM_MAX_STREAM_RETRIES</code>/<code>NIF_LLM_MAX_CONNECT_RETRIES</code>，預設 2），永久性錯誤快速失敗，<code>retry</code> 事件攜帶 <code>budget</code>/<code>retryAfterMs</code>",
      "status.l92": "部分工具輸出隨錯誤一起回傳——組件在分派逾時或取消時交回已擷取的位元組，現在以 <code>ERROR:</code> 原因開頭、在 <code>toolcall</code> 事件上標記 <code>error</code> 欄位，絕不會被記成普通成功",
      "status.l93": "MCP 直連工具集門檻——設定為 <code>expose: direct</code> 且發布工具數超過 <code>NIF_MCP_DIRECT_THRESHOLD</code>（預設 10）的伺服器改為按需標記，避免淹沒工具提示詞；較小的直連伺服器仍前置發布全部工具",
      "status.l94": "壓縮實機冒煙——可選的 §8 門檻（<code>SYNTHETIC_API_KEY=... make live-smoke</code>）用真實組件對接真實 provider，度量跨重啟的連續性、召回與延遲；報告完成十個稽核批次、兩次壓縮、無損裁剪為零且跨重啟連續，一致性夾具還涵蓋純檢查點替換實作（<code>NIF_FIXTURE_CHECKPOINT_ONLY=1</code>）",
      "status.l95": "排序倉庫地圖（repomap 組件）——aider 風格的工作區地圖，由 tree-sitter + 原生 Nim 的 tags 圖經個人化 PageRank 排序得出；<code>repo_map</code> 是 onDemand 且唯讀（模型主動詢問），工作區開啟時的自動附加需明確開啟（<code>NIF_REPOMAP_AUTOAPPEND=1</code>）且設有準入門檻（普查下限與位元組/符號/檔案骨架門檻；<code>bench/reports/repomap-gates-full30.md</code> 驗證強制開啟時 30/30 個工作區被攔截、0 次發布——A/B 中 +41% 的 token 代價因建構而消失，<code>bench/reports/repomap-ab-*.md</code>）",
      "status.l96": "對話控制——<code>/approvals</code>（本對話的把關模式：<code>ask</code> 或 <code>auto</code>，auto 明確地自動放行）與 <code>/limit rounds|tokens|seconds</code>（軟性預算：觸及時透過核准通道詢問「是否繼續」，回答是則延長一步，拒絕或無應答則以明確的 <code>limit-&lt;dimension&gt;</code> 記錄結束回合）；兩者都屬於人類，經 <code>session</code> 呼叫設定並隨對話持久化，而任務級預算與 <code>NIF_MAX_TURN_ROUNDS</code> 保持硬性、絕不協商（無介面自動化用 <code>NIF_AUTO_CONTINUE=1</code>）；回合中抵達的 session 呼叫會立即以 <code>busy</code> 拒絕，不再懸掛到客戶端逾時",
      "status.l97": "背景行程回報退出——由 <code>run_in_background</code> 啟動的子行程結束時發布退出通知（<code>kind: \"process-exited\"</code>，走結算通知通道），被折入所屬對話的僅附加歷史並指向 spool（輸出留在 spool，命令文字不隨行）；收割改為週期性進行，依託三個 SDK 新增的 <code>onIdle</code> 閒置接縫（Nim 泵迴圈、TS promise 鏈、Go ticker goroutine），<code>process_list</code> 不再把已結束的子行程顯示為 <code>running</code>，條目還攜帶 <code>started_at</code>",
      "status.l98": "按 provider 尺度核算上下文——準入計價改用 provider 的 token 尺度而非本地估算；持久化裁剪記錄水位線，重放跨重啟安全；正規化後的 provider 溢位 400 在轉為終態前會獲得一次帶回執的復原嘗試",
      "status.l99": "SDK 初始連線有界重試——Nim SDK（所有生產組件）現在會在匯流排綁定期間重試初始 NATS 連線至多 60 秒（感知關停），之後明確地失敗並交給 supervisor 退避；啟動/重啟時的匯流排競態只留在崩潰日誌裡，不再導致組件崩潰（TS 與 Go 本就自動重連）",
      "status.l100": "桌面 UI 變為外掛——<code>ui/</code> 原始碼已遷至 <code>gokr/niffler-ui</code> 倉庫；<code>make install-ui</code> 會啟動一個隔離的自動核准 harness，並經外掛管理器安裝 UI（依最新 release 標籤複製、針對本 harness 建置、發布為 <code>var/bin/niffler-ui</code>），<code>make build</code> 只建置 core + 組件，前端測試也遷入 UI 自己的倉庫——<code>make test</code> 重新成為純粹的匯流排契約套件",
      "status.l101": "manifest v2 套件建置——套件可宣告 <code>{manifestVersion: 2, components: [{name, lang, project, build: {steps, artifact}}]}</code> 並自帶相依清單與鎖檔（<code>package.json</code>/鎖檔、<code>go.mod</code>/<code>go.sum</code>、Nimble）；builder 的 <code>build_package</code> 暫存專案、只展開受控的 SDK/輸出佔位符、執行有界 argv 配方（工具鏈可以組合——例如 <code>npm ci</code> 後接 <code>wails build</code>——但不允許 shell 包裝），並在發布前驗證宣告的產物",
      "status.l102": "小組件的自願自檢——<code>grep</code>、<code>logfile</code>、<code>observe</code> 與 <code>hooks</code> 註冊了 WIRE.md 描述的隱藏 <code>selftest</code>：快速接線檢查，外加 deep 探針——真實的有界 rg 搜尋、寫入真實日誌匯、演練 hooks 去重環、經 stdin 管道送入暫存檔",
      "status.l37": "訂閱制 OAuth——ChatGPT Plus/Pro 與 Claude Pro/Max 登入，權杖自動更新",
      "status.l38": "持久化 agent 任務——以 store 記錄為基礎的 <code>agent_spawn</code>/<code>status</code>/<code>wait</code>/<code>stop</code>/<code>steer</code>；真正的中止取消、惰性預算、陳舊任務復原",
      "status.l39": "fabric 型別化模式——目錄釘選的型別化包裝、命名程式庫、帶摘要鍵自動核准的核准清單、有界 batch 呼叫",
      "status.l40": "batch 效應宣告——<code>x-harness.effect</code>：讀並行執行，寫獨占執行",
      "status.l41": "生命週期事件 + 活動列——匯流排上關聯的 <code>ev.fabric.*</code>/<code>ev.agent.*</code>，console 與桌面 UI 即時呈現；產物保留清理",
      "status.l42": "SWE-bench Verified 試點——10 個 sympy 實例經官方 Docker 環境評分，niffler/pi/opencode 對比；每個任務少用 2.3–2.9 倍 token",
      "status.l43": "bash 加固——回合取消時終止整個行程樹；超大輸出溢寫到暫存檔並以 <code>read</code> 分頁讀取",
      "status.l44": "subagent 預算——每個任務的 <code>maxCalls</code>/<code>maxTokens</code> 上限凍結進子對話",
      "status.l45": "提示詞快取經濟——每個 session 狀態事件攜帶巢狀的 <code>cache {prompt, read, hitRate}</code>（對話標頭持久化 <code>cachePrompt</code>/<code>cacheRead</code>/<code>cacheHitRate</code>，由 <code>session_info</code> 上報），低的前綴命中率因此可見、可歸因",
      "status.l46": "LLM 自動重試——暫時性故障（429/5xx/逾時）依指數退避重試，每次重試都有事件播報",
      "status.l47": "並行工具波 + 行程副本——相互獨立的呼叫並行分發；無狀態組件可設 <code>replicas: N</code>（grep 預設 ×4）",
      "status.l48": "即時模型 id——<code>provider_models</code> 探測 provider 自己的 <code>/models</code> 端點，以 <code>x-models-source</code> 修補合併進目錄",
      "status.l49": "提示詞瘦身——精簡 baseprompt 與工具描述，只給 LLM 純 JSON Schema（首請求 −31%，快取讀 −35%）",
      "status.l50": "hooks + 維運工具——<code>hooks</code> 在匯流排事件上執行 shell 指令（可選啟用）；<code>prompt_preview</code>、<code>doctor</code>、<code>review_receipt</code>、<code>skill_audit</code> 用於檢查與交接",
      "status.l51": "dialog——純 bash 組件：<code>dialog_show</code>/<code>dialog_ask</code> 經 zenity/notify-send 彈出桌面對話框",
      "status.l52": "store 引擎——SQLite（預設）、barrel 與 TiDB/MySQL 由 NIF_STORE_BACKEND 選擇；同一匯流排契約、相同的工具",
      "status.l53": "內建匯流排伺服器——<code>make build</code> 將官方 nats-server 編譯進 <code>var/bin/nats-server</code>；core 優先使用它而非 PATH 安裝",
      "status.l54": "內建技能 niffler-tools + niffler-harness——該用哪個工具，以及如何操作執行中的 harness",
      "status.l55": "權威的 cli 安裝——<code>cli install</code> 以 core 已接受的目錄確認註冊，而非原始註冊廣播",
      "status.l56": "一個克隆 = 一個實例——主匯流排只為本根目錄認領（catalog 攜帶 <code>root</code> + <code>gitHash</code>），遇到陌生 core 明確讓位；<code>NIF_NATS_SPAWN=1</code> 強制隔離匯流排；父程序死亡連鎖清理，任何子程序都不會比所屬 harness 活得更久",
      "status.l57": "<code>make install</code> / <code>make uninstall</code>——將 niffler、niffler-cli、niffler-console 放入 PATH（視需求加裝 niffler-tui 包裝器，<code>WITH_TUI=1</code>）；只安裝 niffler 前綴的命令，絕不安裝組件二進位，因此 PATH 不會遮蔽 Unix 工具",
      "status.l1": "wire 規範、envelope、Nim + Go + TypeScript SDK",
      "status.l2": "supervisor、catalog、dispatch",
      "status.l3": "bash + builder + store + llm（串流配接器）",
      "status.l4": "agent 端到端為自己新增工具（已使用 DeepSeek 實測）",
      "status.l5": "能力形態跨重啟持久化",
      "status.l6": "session 服務 + Wails SPA 外殼",
      "status.l7": "session runner——一個對話 = 一個行程",
      "status.l8": "核准——終端機 y/N、帶 ack 的定向 UI 請求與廣播回退；無介面執行時預設拒絕，並透過 resolved 事件清理狀態",
      "status.l9": "復原模式——<code>make recover</code>",
      "status.l10": "外掛——組件生態（發現、安裝、更新、移除）",
      "status.l11": "skills——Agent Skills 的漸進發現與載入",
      "status.l12": "fetch——具有逾時與大小限制的網頁內容擷取，優先使用 Trafilatura 擷取正文",
      "status.l13": "edit——read/edit/write/undo 檔案工具（hashline-edit 已提取為 niffler-hashline 外掛）",
      "status.l14": "grep + git——倉庫搜尋與唯讀 Git 檢查",
      "status.l15": "console + cli——在終端機中觀察並驅動匯流排",
      "status.l16": "串流輸出——UI 裡即時 <code>ev.session.&lt;id&gt;.token</code> 增量",
      "status.l17": "UI：組件面板、工具執行檢視、明暗主題、About 對話框",
      "status.l18": "匯流排契約測試套件——<code>make test</code>，每個測試隔離 NATS + 暫存根目錄",
      "status.l19": "tty 管理 shell——help/status/catalog/tools/sessions，REPL 裡沒有聊天",
      "status.l20": "observe + logfile——即時觀測匯流排、持久化輪替 JSONL 日誌",
      "status.l21": "models——匯流排上的 models.dev 目錄、目錄驅動的上下文視窗",
      "status.l22": "provider——以 store 為基礎的 LLM provider 登錄檔、執行期間切換",
      "status.l23": "由 UI 管理 harness 生命週期——桌面圖示即整個系統：建置一次，任何 UI 都會自動啟動 core，最後一個 UI 結束時停止 core",
      "status.l24": "最小啟動設定——<code>--minimal</code> 只啟動 store、bash 和 llm，同時保留被跳過的記錄",
      "status.l25": "provider/model 控制——已儲存的 provider、模型選擇、上下文用量指示器與即時 session 狀態",
      "status.l26": "漸進式工具探索——每個 session 的直接工具集保持不變，透過 discover/invoke 存取其他工具，並顯示 Live Components 可見性狀態",
      "status.l27": "fabric——可程式化工具呼叫：LLM 撰寫 Nim 程式，由編譯為本機 guest 行程的執行器執行並從程式內部呼叫匯流排工具",
      "status.l28": "subagent session——將任務委派給擁有全新脈絡的子 runner，並把結果摘要回傳給呼叫方",
      "status.l29": "斜線命令——透過 <code>niffler.json</code> 為 UI 宣告命令，並將命令註冊資訊持久化到 store",
      "status.l30": "thinking effort——每個對話可設定 <code>reasoning_effort</code>（ctrl+g），TUI 支援串流顯示推理過程",
      "status.l31": "取消——按呼叫取消 LLM 請求與 TUI 兩段式停止（ESC、ESC）",
      "status.t1": "Level 1 UI 動態化（x-ui schema 提示）",
      "status.t3": "store 的 FTS + 向量記憶（TiDB 引擎已落地，檢索後續提供）",
      "footer.text": "niffler — 可自我擴展的 agent harness · <a href=\"https://github.com/gokr/niffler\" target=\"_blank\" rel=\"noopener\">github.com/gokr/niffler</a> · <a href=\"https://discord.gg/ThJFEAJUAk\" target=\"_blank\" rel=\"noopener\">discord.gg/ThJFEAJUAk</a>"
    }
  };

  var STORAGE_KEY = "niffler-lang";
  var defaults;

  function captureDefaults() {
    if (defaults) return;
    var description = document.querySelector('meta[name="description"]');
    var localeGroup = document.querySelector(".locales");
    defaults = {
      title: document.title,
      description: description ? description.content : "",
      localeLabel: localeGroup ? localeGroup.getAttribute("aria-label") : "Language",
      text: [],
      html: [],
      titles: []
    };
    document.querySelectorAll("[data-i18n]").forEach(function (el) {
      defaults.text.push({ el: el, value: el.textContent });
    });
    document.querySelectorAll("[data-i18n-html]").forEach(function (el) {
      defaults.html.push({ el: el, value: el.innerHTML });
    });
    document.querySelectorAll("[data-i18n-title]").forEach(function (el) {
      defaults.titles.push({ el: el, value: el.title });
    });
  }

  function detect() {
    try {
      var saved = localStorage.getItem(STORAGE_KEY);
      if (saved === "zh" || saved === "zh-TW" || saved === "en") return saved;
    } catch (e) {}
    var nav = (navigator.language || "en").toLowerCase();
    if (nav.indexOf("zh") === 0) {
      return nav.indexOf("tw") >= 0 || nav.indexOf("hant") >= 0 || nav.indexOf("hk") >= 0
        ? "zh-TW" : "zh";
    }
    return "en";
  }

  function apply(locale) {
    captureDefaults();
    var cat = CATALOGS[locale];
    if (!cat) {
      defaults.text.forEach(function (entry) { entry.el.textContent = entry.value; });
      defaults.html.forEach(function (entry) { entry.el.innerHTML = entry.value; });
      defaults.titles.forEach(function (entry) { entry.el.title = entry.value; });
      document.documentElement.lang = "en";
      document.title = defaults.title;
      var englishDescription = document.querySelector('meta[name="description"]');
      if (englishDescription) englishDescription.content = defaults.description;
      var englishLocaleGroup = document.querySelector(".locales");
      if (englishLocaleGroup) englishLocaleGroup.setAttribute("aria-label", defaults.localeLabel);
      return;
    }
    var titleKey = document.body.getAttribute("data-title-key") || "meta.title";
    var descKey = document.body.getAttribute("data-desc-key") || "meta.description";
    document.documentElement.lang = locale === "zh" ? "zh-CN" : "zh-TW";
    document.querySelectorAll("[data-i18n]").forEach(function (el) {
      var v = cat[el.getAttribute("data-i18n")];
      if (v !== undefined) el.textContent = v;
    });
    document.querySelectorAll("[data-i18n-html]").forEach(function (el) {
      var v = cat[el.getAttribute("data-i18n-html")];
      if (v !== undefined) el.innerHTML = v;
    });
    document.querySelectorAll("[data-i18n-title]").forEach(function (el) {
      var v = cat[el.getAttribute("data-i18n-title")];
      if (v !== undefined) el.title = v;
    });
    document.title = cat[titleKey] || defaults.title;
    var description = document.querySelector('meta[name="description"]');
    if (description) description.content = cat[descKey] || defaults.description;
    var localeGroup = document.querySelector(".locales");
    if (localeGroup) localeGroup.setAttribute("aria-label", cat["locale.label"] || defaults.localeLabel);
  }

  function activate(locale) {
    apply(locale);
    try { localStorage.setItem(STORAGE_KEY, locale); } catch (e) {}
    document.querySelectorAll("[data-locale-btn]").forEach(function (btn) {
      var active = btn.getAttribute("data-locale-btn") === locale;
      btn.classList.toggle("active", active);
      btn.setAttribute("aria-pressed", String(active));
    });
  }

  function onReady() {
    var locale = detect();
    activate(locale);
    document.querySelectorAll("[data-locale-btn]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        activate(btn.getAttribute("data-locale-btn"));
      });
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", onReady);
  } else {
    onReady();
  }

  window.NIFFLER_I18N = {
    text: function (key, fallback) {
      var cat = CATALOGS[detect()];
      return (cat && cat[key] !== undefined) ? cat[key] : fallback;
    }
  };
})();
