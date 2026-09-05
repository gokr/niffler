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
      "hero.badgeAny": "任意语言",
      "hero.ctaMake": "make && ui/build/bin/niffler-ui",
      "hero.ctaGithub": "github →",
      "hero.ctaDiscord": "discord →",
      "term.build": "构建 core + 组件 + 桌面 UI · UI 会自动启动 harness",
      "term.l1": "→ 在 127.0.0.1:4222 启动 nats-server",
      "term.l2": "→ core 正在监听 svc.core.call",
      "term.typed": "niffler — 等待输入…",
      "term.note": "那个终端是管理 shell（不含聊天）——对话在 niffler-ui 与 niffler-tui 中进行",
      "why.title": "为什么",
      "why.1h": "<span class=\"num\">01</span> 进程，而非插件",
      "why.1p": "无需 <code>dlopen</code>，也不受 ABI 兼容和进程内状态残留困扰。每个组件都是独立进程；停止组件只需结束进程，操作系统会回收相关资源。单个组件崩溃不会直接带崩 core 或其他组件。",
      "why.2h": "<span class=\"num\">02</span> 一种协议",
      "why.2p": "Core 只使用一种通信格式：通过 NATS 传输的 JSON envelope。编解码器约 200 行，仅依赖 <code>std/json</code>。目前提供 Nim、Go 和 TypeScript SDK，也可以移植到其他语言。",
      "why.3h": "<span class=\"num\">03</span> 自我扩展",
      "why.3p": "agent 写源码 → 调用 <code>builder.build</code> → 调用 <code>core.spawn</code> → 新工具立即可用。新增能力本身就是一次工具调用，LLM 可以在对话过程中自行完成整套流程。社区组件也以相同方式安装：<code>plugin_install</code> 会克隆源码、编译并启动；执行前需人工批准，并始终从发布的源码构建。<code>fabric</code> 更进一步：LLM 可以在内嵌的 Nim VM 中编写程序，控制整个回合内的工具调用流程。",
      "why.4h": "<span class=\"num\">04</span> 能力形态持久化",
      "why.4p": "能力可以跨重启保留：已启动的组件记录在 store 中，并在下次启动时自动恢复。仓库保存可复现的源码；<code>var/bin/</code> 可以重新构建，<code>var/barrel-db</code> 则保存持久化状态。",
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
      "qs.make": "# 首次构建 core、组件和桌面 UI",
      "qs.run": "# 桌面 UI——自动启动 harness",
      "qs.uiinstall": "# 可选：安装启动器 + 应用图标，并将 niffler-ui 放入 PATH（Linux）",
      "qs.test": "# 总线契约测试——30 项契约测试 + 冒烟测试 + Go 测试",
      "qs.see": "└─ make run / recover / down / dev · 见 docs/MANUAL.md",
      "qs.requirements": "环境要求",
      "qs.req.nim": "Nim 2.x",
      "qs.req.go": "Go",
      "qs.req.nats": "nats-server（从源码构建）",
      "qs.req.node": "Node.js / npm",
      "qs.req.wails": "Wails CLI <span class=\"dim\">（仅 UI）</span>",
      "qs.req.trafilatura": "Trafilatura <span class=\"dim\">（可选，提供更完整的 HTML 正文提取）</span>",
      "qs.note": "所有 Nim 依赖都来自 nimble——yaml、htmlparser、natswrapper、bitbarrel——首次构建时自动安装。",
      "comp.title": "自带组件",
      "comp.th.component": "组件",
      "comp.th.language": "语言",
      "comp.th.purpose": "用途",
      "comp.core.p": "对话循环、进程管理（supervisor）、组件目录（catalog）和调用分发（dispatch）",
      "comp.session.p": "一个对话 = 一个进程——临时按会话启动的 runner，从 store 恢复；杀掉一个只会丢失进行中的回合",
      "comp.bash.p": "以工具形式提供 shell 访问；执行前需人工批准；支持进程树取消与超大输出分页读取",
      "comp.builder.p": "将 agent 编写的源码编译为可执行程序",
      "comp.store.p": "基于 BitBarrel 的总线文档存储，使用版本号（rev）进行并发控制",
      "comp.plugins.p": "组件生态：按 topic 搜索，通过 <code>niffler.json</code> 描述包，支持安装/更新/移除；始终从源码构建",
      "comp.skills.p": "Agent Skills 的发现、渐进式加载、资源访问，以及受管的安装/移除；skill_audit 盘点未合并的磁盘清单",
      "comp.systemprompt.p": "对话宪法组件化——session runner 每个对话只调用一次 <code>svc.systemprompt.call</code> 获取系统提示词；替换组件即可替换宪法",
      "comp.fetch.p": "带超时和大小限制的 HTTP(S) 内容获取，支持 method/header/body；优先使用 Trafilatura 提取 HTML，并提供纯 Nim 备用方案和超大结果落盘",
      "comp.edit.p": "文件工具：可分页 <code>read</code>、带守卫回退级联的精确匹配 <code>edit</code>、原子 <code>write</code>、单层撤销；修改操作需人工批准",
      "comp.grep.p": "基于 ripgrep 的内容搜索和有序仓库文件列表，提供明确的截断标记",
      "comp.git.p": "只读仓库检查：<code>status</code>/<code>diff</code>/<code>log</code>/<code>show</code>/<code>blame</code>；无需审批，固定 argv，路径限定在 harness 根目录；另有 <code>review_receipt</code> 做推送前的 diff 指纹交接",
      "comp.hooks.p": "操作员 shell 命令，挂在选定的总线事件上（<code>ev.session.turn</code>、<code>ev.log.&gt;</code>）——stdin 接收 JSON 载荷，只观察不干预，由环境变量配置，默认关闭",
      "comp.observe.p": "实时查看总线——subject 发现、监听、请求/响应追踪和监控",
      "comp.logfile.p": "将 <code>ev.log.*</code> 持久化到 JSONL——支持日志轮转、范围受限的搜索和保留策略",
      "comp.models.p": "通过总线提供 models.dev 的 provider/model 目录——内置离线数据、缓存刷新和 <code>x-models-source</code> 插件补丁",
      "comp.provider.p": "基于 store 的 LLM provider 注册表——add/list/switch/active/remove/export/import，运行时切换后端，订阅制 OAuth 登录并自动轮换令牌；provider_models 探测 provider 自己的 /models 端点获取实时模型 id",
      "comp.llm.p": "流式 OpenAI 兼容 adapter（默认 DeepSeek）——实时 <code>ev.llm.token</code> token 流、推理 token，以及单次调用取消",
      "comp.fabric.p": "可编程工具调用——LLM 编写 Nim 程序掌控回合内控制流；带目录钉选的类型化包装、命名程序库、宿主并发的 <code>batch</code> 调用、审批清单，以及按 runId 关联的 <code>ev.fabric.*</code> 生命周期事件",
      "comp.agent.p": "subagent 会话——同步 <code>agent_run</code> 把任务委派给拥有全新上下文的子 runner；持久化后台任务（<code>agent_spawn</code>/<code>status</code>/<code>wait</code>/<code>stop</code>/<code>steer</code>）跨重启存续；空闲 runner 自动退役",
      "comp.expert.p": "咨询同伴——一对一跟随一个工作中的会话，由 LLM 判定有界观察，只把高置信度的 steer 作为标记消息投递；默认沉默、失败即静默",
      "comp.dialog.p": "纯 bash 组件——<code>dialog_show</code>/<code>dialog_ask</code> 桌面对话框（zenity → notify-send → 日志回退），只用 nats CLI + jq 说 envelope，无 SDK、无需编译",
      "comp.cli.p": "通过脚本驱动 harness：<code>catalog</code>/<code>wait</code>/<code>call</code>/<code>install</code>——插件仓库的标准 CI 入口",
      "comp.console.p": "总线查看器——将每个 envelope 输出到 stdout，可在第二个终端中实时查看",
      "comp.ui.p": "桌面聊天 UI——会话、流式 token、工具运行、审批、模型控制；由 Wails 承载的 SPA，架构上是 NATS client",
      "comp.your.p": "移植 SDK；envelope 是跨语言契约（约 200 行）",
      "comp.your.name": "你的工具",
      "comp.your.lang": "任意",
      "screens.ui.name": "niffler-ui",
      "screens.ui.desc": "桌面聊天 UI：会话、流式 token、工具运行、审批、模型控制",
      "screens.tui.name": "niffler-tui",
      "screens.tui.desc": "终端聊天客户端（一个插件——连接到已在运行的 harness）",
      "screens.note": "<code>./var/bin/niffler</code> 在终端里是管理 shell——help/status/catalog/tools/sessions，不含聊天。对话在 <code>niffler-ui</code> 和 <code>niffler-tui</code> 中进行；脚本走 <code>./var/bin/cli</code>。",
      "wire.title": "一种协议，统领一切",
      "wire.note1": "core → <code>svc.core.call</code>，组件 → <code>svc.&lt;name&gt;.call</code>，<br>事件走 <code>ev.*</code>。这就是全部总线契约。",
      "wire.note2": "规范：<a href=\"https://github.com/gokr/niffler/blob/main/docs/WIRE.md\" target=\"_blank\" rel=\"noopener\">docs/WIRE.md</a> · 理由：<a href=\"https://github.com/gokr/niffler/blob/main/docs/research/REBOOT.md\" target=\"_blank\" rel=\"noopener\">docs/research/REBOOT.md</a>",
      "bench.title": "实测，而非声称",
      "bench.1h": "<span class=\"num\">01</span> SWE-bench Verified 试点",
      "bench.1p": "10 个 sympy 实例、单轮提交，由官方 <code>swebench</code> 4.1.0 Docker 环境评分——niffler、pi、opencode 在两个模型上同场对比。Niffler 解题数量相当，但每个任务少用 2.3–2.9 倍 token。完整报告：<code>bench/reports/swe-sympy10-pilot-report.md</code>。",
      "bench.2h": "<span class=\"num\">02</span> harness 基准",
      "bench.2p": "harness 对比基准框架：五个基础版本即失败的题目，参考实现验证通过；逐轮反馈循环、受保护文件防篡改、按 provider 统计 token——niffler / pi / opencode × 两个模型，另有配对的 niffler-expert 变体用于度量咨询同伴。",
      "status.title": "状态",
      "status.i18n": "UI + TUI 界面本地化——en/zh/zh-TW 语言环境、CJK 安全的截断与编辑",
      "status.l32": "session_info——LLM 可自省当前对话：模型、effort、上下文占用、消息计数",
      "status.l33": "systemprompt 组件化——对话宪法可通过总线替换",
      "status.l34": "内置 skills——仓库的 skills/ 树随 harness 发布，可被项目/用户目录遮蔽且不可移除",
      "status.l35": "回合内 steer——向运行中的回合注入消息（<code>svc.session.&lt;id&gt;.steer</code>）",
      "status.l36": "expert 咨询同伴——每个会话一个 LLM 判定式顾问：有界观察、回合内 steer、失败即静默",
      "status.l37": "订阅制 OAuth——ChatGPT Plus/Pro 与 Claude Pro/Max 登录，令牌自动刷新",
      "status.l38": "持久化 agent 任务——基于 store 记录的 <code>agent_spawn</code>/<code>status</code>/<code>wait</code>/<code>stop</code>/<code>steer</code>；真正的中止取消、惰性预算、陈旧任务恢复",
      "status.l39": "fabric 类型化模式——目录钉选的类型化包装、命名程序库、带摘要键自动批准的审批清单、有界 batch 调用",
      "status.l40": "batch 效应声明——<code>x-harness.effect</code>：读并发执行，写独占执行",
      "status.l41": "生命周期事件 + 活动条——总线上关联的 <code>ev.fabric.*</code>/<code>ev.agent.*</code>，console 与桌面 UI 实时渲染；产物保留清理",
      "status.l42": "SWE-bench Verified 试点——10 个 sympy 实例经官方 Docker 环境评分，niffler/pi/opencode 对比；每个任务少用 2.3–2.9 倍 token",
      "status.l43": "bash 加固——回合取消时终止整个进程树；超大输出溢出到临时文件并用 <code>read</code> 分页读取",
      "status.l44": "subagent 预算——每个任务的 <code>maxCalls</code>/<code>maxTokens</code> 上限冻结进子对话",
      "status.l45": "提示词缓存经济——每个 session 状态事件携带 <code>cacheHitTokens</code>/<code>cacheHitRatio</code>，UI 每条消息显示 <code>⚡ NN% cached</code>",
      "status.l46": "LLM 自动重试——瞬时故障（429/5xx/超时）按指数退避重试，每次重试都有事件播报",
      "status.l47": "并行工具波 + 进程副本——相互独立的调用并行分发；无状态组件可设 <code>replicas: N</code>（grep 默认 ×4）",
      "status.l48": "实时模型 id——<code>provider_models</code> 探测 provider 自己的 <code>/models</code> 端点，以 <code>x-models-source</code> 补丁合并进目录",
      "status.l49": "提示词瘦身——精简 baseprompt 与工具描述，只给 LLM 纯 JSON Schema（首请求 −31%，缓存读 −35%）",
      "status.l50": "hooks + 运维工具——<code>hooks</code> 在总线事件上运行 shell 命令（可选启用）；<code>prompt_preview</code>、<code>doctor</code>、<code>review_receipt</code>、<code>skill_audit</code> 用于检查与交接",
      "status.l51": "dialog——纯 bash 组件：<code>dialog_show</code>/<code>dialog_ask</code> 经 zenity/notify-send 弹出桌面对话框",
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
      "status.l16": "流式输出——UI 里实时 <code>ev.session.token</code> 增量",
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
      "status.l27": "fabric——可编程工具调用：LLM 编写 Nim 程序，由内嵌 VM 执行并从程序内部调用总线工具",
      "status.l28": "subagent session——将任务委派给拥有全新上下文的子 runner，并把结果摘要返回给调用方",
      "status.l29": "斜杠命令——通过 <code>niffler.json</code> 为 UI 声明命令，并将命令注册信息持久化到 store",
      "status.l30": "thinking effort——每个对话可设置 <code>reasoning_effort</code>（ctrl+g），TUI 支持流式显示推理过程",
      "status.l31": "取消——按调用取消 LLM 请求与 TUI 两段式停止（ESC、ESC）",
      "status.t1": "Level 1 UI 动态化（x-ui schema 提示）",
      "status.t3": "带 FTS + 向量记忆的 store-tidb",
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
      "hero.badgeAny": "任意語言",
      "hero.ctaMake": "make && ui/build/bin/niffler-ui",
      "hero.ctaGithub": "github →",
      "hero.ctaDiscord": "discord →",
      "term.build": "建置 core + 組件 + 桌面 UI · UI 會自動啟動 harness",
      "term.l1": "→ 在 127.0.0.1:4222 啟動 nats-server",
      "term.l2": "→ core 正在監聽 svc.core.call",
      "term.typed": "niffler — 等待輸入…",
      "term.note": "那個終端機是管理 shell（不含聊天）——對話在 niffler-ui 與 niffler-tui 中進行",
      "why.title": "為什麼",
      "why.1h": "<span class=\"num\">01</span> 行程，而非外掛",
      "why.1p": "不需要 <code>dlopen</code>，也不受 ABI 相容性與行程內狀態殘留困擾。每個組件都是獨立行程；停止組件只需結束行程，作業系統會回收相關資源。單一組件當機不會直接拖垮 core 或其他組件。",
      "why.2h": "<span class=\"num\">02</span> 一種協定",
      "why.2p": "Core 只使用一種通訊格式：透過 NATS 傳輸的 JSON envelope。編解碼器約 200 行，僅依賴 <code>std/json</code>。目前提供 Nim、Go 與 TypeScript SDK，也可以移植到其他語言。",
      "why.3h": "<span class=\"num\">03</span> 自我擴展",
      "why.3p": "agent 寫原始碼 → 呼叫 <code>builder.build</code> → 呼叫 <code>core.spawn</code> → 新工具立即可用。新增能力本身就是一次工具呼叫，LLM 可以在對話過程中自行完成整套流程。社群組件也以相同方式安裝：<code>plugin_install</code> 會複製原始碼、編譯並啟動；執行前需經人工確認，且一律從發布的原始碼建置。<code>fabric</code> 更進一步：LLM 可以在內嵌的 Nim VM 中撰寫程式，控制整個回合內的工具呼叫流程。",
      "why.4h": "<span class=\"num\">04</span> 能力形態持久化",
      "why.4p": "能力可以跨重啟保留：已啟動的組件記錄在 store 中，並在下次啟動時自動復原。倉庫保存可重現的原始碼；<code>var/bin/</code> 可以重新建置，<code>var/barrel-db</code> 則保存持久化狀態。",
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
      "qs.make": "# 首次建置 core、組件與桌面 UI",
      "qs.run": "# 桌面 UI——自動啟動 harness",
      "qs.uiinstall": "# 可選：安裝啟動器 + 應用程式圖示，並將 niffler-ui 放入 PATH（Linux）",
      "qs.test": "# 匯流排契約測試——30 項契約測試 + 冒煙測試 + Go 測試",
      "qs.see": "└─ make run / recover / down / dev · 見 docs/MANUAL.md",
      "qs.requirements": "環境需求",
      "qs.req.nim": "Nim 2.x",
      "qs.req.go": "Go",
      "qs.req.nats": "nats-server（從原始碼建置）",
      "qs.req.node": "Node.js / npm",
      "qs.req.wails": "Wails CLI <span class=\"dim\">（僅 UI）</span>",
      "qs.req.trafilatura": "Trafilatura <span class=\"dim\">（選用，提供更完整的 HTML 內容擷取）</span>",
      "qs.note": "所有 Nim 依賴都來自 nimble——yaml、htmlparser、natswrapper、bitbarrel——首次建置時自動安裝。",
      "comp.title": "內建組件",
      "comp.th.component": "組件",
      "comp.th.language": "語言",
      "comp.th.purpose": "用途",
      "comp.core.p": "對話迴圈、行程管理（supervisor）、組件目錄（catalog）與呼叫分派（dispatch）",
      "comp.session.p": "一個對話 = 一個行程——臨時按對話啟動的 runner，從 store 復原；終止一個只會遺失進行中的回合",
      "comp.bash.p": "以工具形式提供 shell 存取；執行前需經人工確認；支援行程樹取消與超大輸出分頁讀取",
      "comp.builder.p": "將 agent 撰寫的原始碼編譯為執行檔",
      "comp.store.p": "以 BitBarrel 為基礎的匯流排文件儲存，使用版本號（rev）進行並行控制",
      "comp.plugins.p": "組件生態：依 topic 搜尋，透過 <code>niffler.json</code> 描述套件，支援安裝/更新/移除；一律從原始碼建置",
      "comp.skills.p": "Agent Skills 的探索、漸進式載入、資源存取，以及受管理的安裝/移除；skill_audit 盤點未合併的磁碟清單",
      "comp.systemprompt.p": "對話憲法組件化——session runner 每個對話只呼叫一次 <code>svc.systemprompt.call</code> 取得系統提示詞；替換組件即可替換憲法",
      "comp.fetch.p": "具有逾時與大小限制的 HTTP(S) 內容擷取，支援 method/header/body；優先使用 Trafilatura 擷取 HTML，並提供純 Nim 備援方案與大型結果寫入檔案",
      "comp.edit.p": "檔案工具：可分頁 <code>read</code>、帶守衛回退級聯的精確匹配 <code>edit</code>、原子 <code>write</code>、單層復原；修改操作需經人工確認",
      "comp.grep.p": "以 ripgrep 為基礎的內容搜尋與排序後的倉庫檔案清單，提供明確的截斷標記",
      "comp.git.p": "唯讀倉庫檢查：<code>status</code>/<code>diff</code>/<code>log</code>/<code>show</code>/<code>blame</code>；無需核准，固定 argv，路徑限定在 harness 根目錄；另有 <code>review_receipt</code> 做推送前的 diff 指紋交接",
      "comp.hooks.p": "操作員 shell 指令，掛在選定的匯流排事件上（<code>ev.session.turn</code>、<code>ev.log.&gt;</code>）——stdin 接收 JSON 承載，只觀察不干預，由環境變數設定，預設關閉",
      "comp.observe.p": "即時檢視匯流排——subject 探索、監聽、請求/回應追蹤與監控",
      "comp.logfile.p": "將 <code>ev.log.*</code> 持久化為 JSONL——支援日誌輪替、範圍受限的搜尋與保留策略",
      "comp.models.p": "透過匯流排提供 models.dev 的 provider/model 目錄——內建離線資料、快取更新與 <code>x-models-source</code> 外掛修補",
      "comp.provider.p": "以 store 為基礎的 LLM provider 登錄檔——add/list/switch/active/remove/export/import，執行期間切換後端，訂閱制 OAuth 登入並自動輪換權杖；provider_models 探測 provider 自己的 /models 端點取得即時模型 id",
      "comp.llm.p": "串流 OpenAI 相容 adapter（預設 DeepSeek）——即時 <code>ev.llm.token</code> token 串流、推理 token，以及單次呼叫取消",
      "comp.fabric.p": "可程式化工具呼叫——LLM 撰寫 Nim 程式掌控回合內控制流程；帶目錄釘選的型別化包裝、命名程式庫、宿主並行的 <code>batch</code> 呼叫、核准清單，以及依 runId 關聯的 <code>ev.fabric.*</code> 生命週期事件",
      "comp.agent.p": "subagent 對話——同步 <code>agent_run</code> 把任務委派給擁有全新脈絡的子 runner；持久化背景任務（<code>agent_spawn</code>/<code>status</code>/<code>wait</code>/<code>stop</code>/<code>steer</code>）跨重啟存續；閒置 runner 自動退役",
      "comp.expert.p": "諮詢同伴——一對一跟隨一個工作中的對話，由 LLM 判定有界觀察，只把高置信度的 steer 作為標記訊息投遞；預設沉默、失敗即靜默",
      "comp.dialog.p": "純 bash 組件——<code>dialog_show</code>/<code>dialog_ask</code> 桌面對話框（zenity → notify-send → 日誌回退），只用 nats CLI + jq 說 envelope，無 SDK、無需編譯",
      "comp.cli.p": "透過腳本驅動 harness：<code>catalog</code>/<code>wait</code>/<code>call</code>/<code>install</code>——外掛倉庫的標準 CI 入口",
      "comp.console.p": "匯流排檢視器——將每個 envelope 輸出到 stdout，可在第二個終端機中即時查看",
      "comp.ui.p": "桌面聊天 UI——對話、串流 token、工具執行、核准、模型控制；由 Wails 承載的 SPA，架構上是 NATS client",
      "comp.your.p": "移植 SDK；envelope 是跨語言契約（約 200 行）",
      "comp.your.name": "你的工具",
      "comp.your.lang": "任意",
      "screens.ui.name": "niffler-ui",
      "screens.ui.desc": "桌面聊天 UI：對話、串流 token、工具執行、核准、模型控制",
      "screens.tui.name": "niffler-tui",
      "screens.tui.desc": "終端機聊天客戶端（一個外掛——連接到已在執行的 harness）",
      "screens.note": "<code>./var/bin/niffler</code> 在終端機裡是管理 shell——help/status/catalog/tools/sessions，不含聊天。對話在 <code>niffler-ui</code> 和 <code>niffler-tui</code> 中進行；腳本走 <code>./var/bin/cli</code>。",
      "wire.title": "一種協定，統領一切",
      "wire.note1": "core → <code>svc.core.call</code>，組件 → <code>svc.&lt;name&gt;.call</code>，<br>事件走 <code>ev.*</code>。這就是全部匯流排契約。",
      "wire.note2": "規範：<a href=\"https://github.com/gokr/niffler/blob/main/docs/WIRE.md\" target=\"_blank\" rel=\"noopener\">docs/WIRE.md</a> · 理由：<a href=\"https://github.com/gokr/niffler/blob/main/docs/research/REBOOT.md\" target=\"_blank\" rel=\"noopener\">docs/research/REBOOT.md</a>",
      "bench.title": "實測，而非聲稱",
      "bench.1h": "<span class=\"num\">01</span> SWE-bench Verified 試點",
      "bench.1p": "10 個 sympy 實例、單輪提交，由官方 <code>swebench</code> 4.1.0 Docker 環境評分——niffler、pi、opencode 在兩個模型上同場對比。Niffler 解題數量相當，但每個任務少用 2.3–2.9 倍 token。完整報告：<code>bench/reports/swe-sympy10-pilot-report.md</code>。",
      "bench.2h": "<span class=\"num\">02</span> harness 基準",
      "bench.2p": "harness 對比基準框架：五個基礎版本即失敗的題目，參考實作驗證通過；逐輪回饋迴圈、受保護檔案防竄改、依 provider 統計 token——niffler / pi / opencode × 兩個模型，另有配對的 niffler-expert 變體用於度量諮詢同伴。",
      "status.title": "狀態",
      "status.i18n": "UI + TUI 介面在地化——en/zh/zh-TW 語言環境、CJK 安全的截斷與編輯",
      "status.l32": "session_info——LLM 可自省當前對話：模型、effort、脈絡占用、訊息計數",
      "status.l33": "systemprompt 組件化——對話憲法可透過匯流排替換",
      "status.l34": "內建 skills——倉庫的 skills/ 樹隨 harness 發布，可被專案/使用者目錄遮蔽且不可移除",
      "status.l35": "回合內 steer——向執行中的回合注入訊息（<code>svc.session.&lt;id&gt;.steer</code>）",
      "status.l36": "expert 諮詢同伴——每個對話一個 LLM 判定式顧問：有界觀察、回合內 steer、失敗即靜默",
      "status.l37": "訂閱制 OAuth——ChatGPT Plus/Pro 與 Claude Pro/Max 登入，權杖自動更新",
      "status.l38": "持久化 agent 任務——以 store 記錄為基礎的 <code>agent_spawn</code>/<code>status</code>/<code>wait</code>/<code>stop</code>/<code>steer</code>；真正的中止取消、惰性預算、陳舊任務復原",
      "status.l39": "fabric 型別化模式——目錄釘選的型別化包裝、命名程式庫、帶摘要鍵自動核准的核准清單、有界 batch 呼叫",
      "status.l40": "batch 效應宣告——<code>x-harness.effect</code>：讀並行執行，寫獨占執行",
      "status.l41": "生命週期事件 + 活動列——匯流排上關聯的 <code>ev.fabric.*</code>/<code>ev.agent.*</code>，console 與桌面 UI 即時呈現；產物保留清理",
      "status.l42": "SWE-bench Verified 試點——10 個 sympy 實例經官方 Docker 環境評分，niffler/pi/opencode 對比；每個任務少用 2.3–2.9 倍 token",
      "status.l43": "bash 加固——回合取消時終止整個行程樹；超大輸出溢寫到暫存檔並以 <code>read</code> 分頁讀取",
      "status.l44": "subagent 預算——每個任務的 <code>maxCalls</code>/<code>maxTokens</code> 上限凍結進子對話",
      "status.l45": "提示詞快取經濟——每個 session 狀態事件攜帶 <code>cacheHitTokens</code>/<code>cacheHitRatio</code>，UI 每則訊息顯示 <code>⚡ NN% cached</code>",
      "status.l46": "LLM 自動重試——暫時性故障（429/5xx/逾時）依指數退避重試，每次重試都有事件播報",
      "status.l47": "並行工具波 + 行程副本——相互獨立的呼叫並行分發；無狀態組件可設 <code>replicas: N</code>（grep 預設 ×4）",
      "status.l48": "即時模型 id——<code>provider_models</code> 探測 provider 自己的 <code>/models</code> 端點，以 <code>x-models-source</code> 修補合併進目錄",
      "status.l49": "提示詞瘦身——精簡 baseprompt 與工具描述，只給 LLM 純 JSON Schema（首請求 −31%，快取讀 −35%）",
      "status.l50": "hooks + 維運工具——<code>hooks</code> 在匯流排事件上執行 shell 指令（可選啟用）；<code>prompt_preview</code>、<code>doctor</code>、<code>review_receipt</code>、<code>skill_audit</code> 用於檢查與交接",
      "status.l51": "dialog——純 bash 組件：<code>dialog_show</code>/<code>dialog_ask</code> 經 zenity/notify-send 彈出桌面對話框",
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
      "status.l16": "串流輸出——UI 裡即時 <code>ev.session.token</code> 增量",
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
      "status.l27": "fabric——可程式化工具呼叫：LLM 撰寫 Nim 程式，由內嵌 VM 執行並從程式內部呼叫匯流排工具",
      "status.l28": "subagent session——將任務委派給擁有全新脈絡的子 runner，並把結果摘要回傳給呼叫方",
      "status.l29": "斜線命令——透過 <code>niffler.json</code> 為 UI 宣告命令，並將命令註冊資訊持久化到 store",
      "status.l30": "thinking effort——每個對話可設定 <code>reasoning_effort</code>（ctrl+g），TUI 支援串流顯示推理過程",
      "status.l31": "取消——按呼叫取消 LLM 請求與 TUI 兩段式停止（ESC、ESC）",
      "status.t1": "Level 1 UI 動態化（x-ui schema 提示）",
      "status.t3": "帶 FTS + 向量記憶的 store-tidb",
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
