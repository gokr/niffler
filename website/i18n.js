// i18n.js — English / 简体中文 / 繁體中文 for the Niffler website.
//
// English is the source text (also baked into index.html so the page reads
// without JavaScript). Translations are AI autotranslations of the English
// source, same policy as README.zh.md / MANUAL.zh.md — the English text wins
// on any disagreement. Technical names (Niffler, NATS, MCP, LSP, fabric,
// discover/invoke, tool and component names) stay in English everywhere.
//
// Usage in markup:
//   <p data-i18n="key">English fallback</p>
//   <p data-i18n-html="key">English with <em>markup</em></p>
(function () {
  "use strict";

  var CATALOGS = {
    en: {
      "skip": "Skip to content",
      "scroll.hint": "Scroll sideways to explore →",

      "nav.efficient": "Efficient",
      "nav.features": "Features",
      "nav.basics": "Basics",
      "nav.clients": "Clients",
      "nav.arch": "Architecture",
      "nav.credits": "Credits",
      "nav.install": "Install",

      "hero.kicker": "A self-extending agent harness",
      "hero.h1": "Simple and fast harness.<br><em>Batteries included.</em>",
      "hero.lede1": "Niffler is built from small Unix-style processes — every capability is a component on one NATS wire — so the agent can write, compile and spawn <strong>its own tools mid-conversation</strong>.",
      "hero.lede2": "As cheap to drive as the leanest coding agents — and sub-agents, background jobs, a permission gate, MCP and LSP come in the box.",
      "hero.release": "Settings domains, recoverable workspaces, no wasted turns",
      "hero.shotCap": "niffler-tui — one client of a shared, local instance. Cache hit rate reported on every turn.",

      "fast.kicker": "Fast &amp; cache-effective",
      "fast.h2": "Strict cache regime,<br><em>token efficient.</em>",
      "fast.body": "A tiny base prompt and a deliberately small frozen toolset stay byte-stable for the conversation's lifetime, so provider caches stay hot turn after turn. Everything else is one <code>discover</code>/<code>invoke</code> away — entering as history, not prompt bloat.",
      "fast.legend1": "cache hit · 250.3k",
      "fast.legend2": "new this turn · 1.8k",
      "fast.legend3": "99.3% — printed in the UI, every turn",

      "cmp.row.base": "base prompt",
      "cmp.row.first": "base prompt + tools",
      "cmp.pi.note": "3 more built in — grep · find · ls — off by default (<code>+grep</code> to enable)",
      "cmp.nif.note": "the whole catalog (~25 components) sits behind discover / invoke",
      "cmp.dsh.note": "out of the box — every base-backed profile (tui · web · headless)",
      "cmp.oc.note": "captured from the v1.18.32 wire — v2's docs list a slightly different set (adds apply_patch · question · websearch)",
      "cmp.method.h": "How to read this",
      "cmp.method.p": "≈ k tokens (chars/4) from the exact first-request bytes each harness sends into an empty workspace — captured from live wire requests, Oct 2026 (Niffler's row re-captured at 0.6.0, Nov 2026: ≈3.2k). User content excluded (Pi lists your installed skills in its prompt by default, Niffler adds the repo's AGENTS.md chain, Claude Code the CLAUDE.md) — all five captured the same way.",
      "cmp.more": "How to read the numbers",
      "cmp.more2": "About this table",
      "cmp.more3": "How these were captured",

      "feat.kicker": "Interesting features, relatively rare",
      "feat.h2": "Not one of a kind —<br><em>rarely all together.</em>",
      "feat.body": "Nothing here is unique to Niffler. Having all of it in one small box is.",
      "f.sub.h": "Sub-agents",
      "f.sub.p": "Delegate and walk away. It <em>wakes your conversation</em> when it settles — and you can steer, continue or fork it later.",
      "f.fleet.h": "Fleet — remote workers",
      "f.fleet.p": "Hand a goal to a worker on another machine — an Incus container, Lima VM or SSH host — under the budget ceiling its operator set, with a human inbox for settled work.",
      "f.worktree.h": "Isolated Git worktrees",
      "f.worktree.p": "Risky or parallel work gets its own checkout: <code>/worktree add</code> makes a branch beside the primary, and <code>/worktree merge</code> lands it without touching your working tree until it is clean.",
      "f.writes.h": "Write arbitration",
      "f.writes.p": "Two conversations share a checkout without overwriting each other: overlapping writes refuse and name the holder, disjoint files stay parallel. Coordinated, not fenced.",
      "f.bg.h": "Background processes",
      "f.bg.p": "Servers, watchers and builds run under the harness: start, poll, kill. No second terminal, no tmux discipline.",
      "f.gate.h": "Permission gate",
      "f.gate.p": "A tool can ask first, and sub-agents' gated calls route to <em>you</em>. No human reachable means denied — never silently allowed.",
      "f.self.h": "Self-extension",
      "f.self.p": "It writes a source file, compiles it, spawns it and calls the new tool — <em>mid-conversation</em>, in any language.",
      "f.fab.h": "Programmable tool calling",
      "f.fab.p": "<code>fabric</code> compiles a guest program: a dozen tool calls become one native loop, with budgets and approvals intact.",
      "f.proj.h": "Compaction as a projection",
      "f.proj.p": "Context pressure walks a visible ladder: prune, then a replaceable compactor, then elision, then a last-resort trim. Nothing degrades silently — and everything dropped stays <em>recallable</em>.",
      "f.conv.h": "One conversation = one process",
      "f.conv.p": "Each conversation is its own process: they run truly in parallel, and a dead runner loses only its in-flight turn.",
      "f.lang.h": "Any language",
      "f.lang.p": "Components are plain processes: Nim, Go, TypeScript — or a shell script with no SDK at all. The language is a preference.",

      "ed.kicker": "Everything you take for granted",
      "ed.h2": "The table stakes,<br><em>all of them.</em>",
      "ed.body": "Not exotic — but the lean harnesses make you give most of it up. Niffler ships all of it.",
      "ed.prov.h": "Providers, no JSON",
      "ed.prov.p": "Add a backend with one call and hop with <code>/model</code> and <code>/effort</code> — no config files to hand-edit. OpenAI-compatible, Anthropic and Codex lanes, or log in with your ChatGPT/Claude <em>subscription</em> over OAuth. Pins are per-conversation. A provider can name a separate <code>embedModel</code>, so chat and embeddings can live on different backends.",
      "ed.mcp.h": "MCP in, tools out",
      "ed.mcp.p": "Register any MCP server once (stdio, http or sse): a supervised bridge process per server announces its tools and prompts as <em>ordinary catalog tools</em> — same discovery, same approval gate, same call path.",
      "ed.lsp.h": "LSP for your language",
      "ed.lsp.p": "Diagnostics, definitions, references, hover over real language servers: Go, Nim, TypeScript/JavaScript, Python, Rust, C/C++, Bash, Java, PHP, Ruby, C# ship configured. Yours missing? One entry in <code>servers.json</code> — the agent can add it itself.",

      "ed.lab1": "Code, files &amp; the web",
      "ed.filetools.h": "File tools",
      "ed.filetools.p": "batched windowed reads, locate-and-fetch select reads, exact-match edit with a guarded fallback, literal bulk replace across a file set, atomic write, persistent undo",
      "ed.search.h": "Search",
      "ed.search.p": "gitignore-aware grep and file finding — stateless replicas so parallel calls really run in parallel",
      "ed.git.h": "Git",
      "ed.git.p": "status, diff, log, show, blame — read-only and approval-free",
      "ed.web.h": "Web fetch",
      "ed.web.p": "real HTML extraction, SSRF-validated, oversized bodies spill to disk",
      "ed.images.h": "Images",
      "ed.images.p": "screenshot in, multimodal turn out — MIME checks, caps and pixel budgets included",
      "ed.rmap.h": "Repo map",
      "ed.rmap.p": "ranked symbols auto-appended where a repo earns it",

      "ed.lab2": "Conversations &amp; context",
      "ed.steer.h": "Steering",
      "ed.steer.p": "course-correct mid-turn without cancelling the work in flight",
      "ed.recall.h": "Full recall",
      "ed.recall.p": "trimmed or compacted-away messages stay searchable through <code>context_recall</code>",
      "ed.resume.h": "Durable resume",
      "ed.resume.p": "canonical append-only history in the store — restart mid-task and continue, attachments included",
      "ed.controls.h": "Per-conversation controls",
      "ed.controls.p": "tool allowlists, budgets, workspace pin plus human-granted extra roots, provider/model/effort pins",
      "ed.introspect.h": "Introspection",
      "ed.introspect.p": "<code>/export</code> the exact provider request, <code>prompt_preview</code>, <code>context_status</code> for context health and loss attribution, per-role counts, <code>/compact</code> now — <code>--log=debug</code> logs per-model-call timing to <code>var/logs</code>",
      "ed.slash.h": "Slash commands",
      "ed.slash.p": "built in — plus ones contributed by installed plugins and MCP servers",

      "ed.lab3": "Trust &amp; safety",
      "ed.approvals.h": "Approvals everywhere",
      "ed.approvals.p": "any gated caller, sub-agents included — routed to the human driving the turn; denied when none is reachable, with an opt-in per-conversation default for unattended instances",
      "ed.limits.h": "Sub-agent limits",
      "ed.limits.p": "hard budgets that cannot be talked around; soft limits negotiate over the approval channel",
      "ed.grants.h": "Remembered grants",
      "ed.grants.p": "per-tool “don't ask again”, digest-keyed for program-shaped calls",
      "ed.writes.h": "Concurrent-write conflicts",
      "ed.writes.p": "overlapping writes refuse and name the holder; cancellation releases a confirmed-stopped writer's claim, leases bound crash recovery, and disjoint paths stay parallel — coordination, not filesystem fencing",
      "ed.failclosed.h": "Fail closed",
      "ed.failclosed.p": "timeouts deny, unknown limits refuse, a missing component degrades explicitly — never silently",
      "ed.leastpriv.h": "Least privilege",
      "ed.leastpriv.p": "MCP environment allowlists and guard processes, no bus access or secrets in fabric's executor, redacted listings",
      "ed.hometrust.h": "First-open trust",
      "ed.hometrust.p": "opening a cloned harness home runs only the core bootstrap set — <code>store</code>, <code>bash</code>, <code>builder</code>, <code>llm</code>, <code>systemprompt</code> — until <code>NIF_TRUST</code> or a recorded <code>var/home-trust</code> answer trusts it; an already-run home keeps working, and the boot log names each skipped component",
      "ed.shellguard.h": "Opt-in shell guard",
      "ed.shellguard.p": "Linux only and off by default: one bash command gets a read-only host view, private /tmp, no network and no bus — and read masks hide operator-named paths from reads and writes whether or not the guard is on. A mask is not a confidentiality boundary.",

      "ed.lab4": "Ecosystem &amp; extension",
      "ed.skills.h": "Agent Skills",
      "ed.skills.p": "SKILL.md skills: list, search, install and audit — interop with the wider skills ecosystem",
      "ed.plugins.h": "Plugins",
      "ed.plugins.p": "GitHub packages cloned and built from source, approval-gated, manifest v1 or v2 recipes",
      "ed.sdks.h": "Three SDKs",
      "ed.sdks.p": "Nim, Go and TypeScript around one tiny portable codec — or no SDK at all, a shell script speaks the wire",
      "ed.profiles.h": "Tool profiles",
      "ed.profiles.p": "named toolset selectors resolved once per conversation, or sticky tools promoted on demand",
      "ed.config.h": "One settings surface",
      "ed.config.p": "every component publishes a discoverable config domain: list, inspect and patch with schema validation, compare-and-set revisions and approval — secrets redacted, human-only keys writable only by a person",
      "ed.store.h": "A store that answers",
      "ed.store.p": "server-side full-text search, plus nearest-neighbour search over embeddings on SQLite — one contract; TiDB reports vectors unsupported",

      "cl.kicker": "Clients, not containers",
      "cl.h2": "The harness<br><em>isn't a UI.</em>",
      "cl.body": "The agent, its tools, jobs and history live in a shared local <em>instance</em> — not in a window. Clients are thin attachers over the bus, and several can share one instance. Close your terminal mid-task and nothing is lost: jobs keep running, then wake the conversation when they settle.",
      "cl.tui.p": "the terminal chat client — a plugin that boots the harness on demand",
      "cl.cli.p": "the headless driver: call tools, install packages, run whole turns from a script or CI",
      "cl.console.p": "subscribes the bus and renders every envelope live — better than <code>nats sub</code>",
      "cl.desktop.p": "an experimental spin-off package (<code>gokr/niffler-ui</code>) — same wire, its own repo",
      "cl.fine": "Service mode runs with no terminal at all (<code>niffler &lt; /dev/null</code>) — and <code>niffler</code> in a terminal is an admin shell (status, catalog, sessions), not a chat.",

      "un.kicker": "Unix-style architecture",
      "un.h2": "Small programs,<br><em>one wire.</em>",
      "un.body": "Every capability is a separate process that does one thing — its own lifecycle, its own failures, isolated from the agent's mind. One wire connects them all: JSON envelopes over NATS. So the agent can write, compile and spawn a new tool <em>mid-conversation</em>, and teardown is just <code>exit()</code>. The OS is the disposer.",
      "un.loop": "the agent extends itself, in any language, while you talk to it",
      "un.inv1": "minimal profile · 6 processes",
      "un.inv2": "stock boot · +23 above minimal",
      "un.inv3": "+10 more ship in the box",
      "un.wire1": "Calls land on <code>svc.&lt;component&gt;.call</code> (core serves <code>svc.core.call</code>), events fan out on <code>ev.*</code> — four kinds: <code>call</code> · <code>result</code> · <code>event</code> · <code>error</code>. That is the whole bus contract.",
      "un.wire2": "The codec is ~77 lines of pure <code>std/json</code>, mirrored 1:1 by the Nim, Go and TypeScript SDKs — spec: <a href=\"https://github.com/gokr/niffler/blob/main/docs/WIRE.md\" target=\"_blank\" rel=\"noopener\">docs/WIRE.md</a> · rationale: <a href=\"https://github.com/gokr/niffler/blob/main/docs/research/REBOOT.md\" target=\"_blank\" rel=\"noopener\">research/REBOOT.md</a>",

      "cr.kicker": "Sources of inspiration",
      "cr.h2": "Credit where<br><em>credit is due.</em>",
      "cr.body": "Niffler is meant to be easily extended — a trait it shares with Pi, its biggest influence. It wears its sources on its sleeve. What we took, and from where:",
      "cr.pi": "Token efficiency, a small initial toolset and self-aware extendability — a harness meant to be easily extended. Niffler is built the same way and pushes a variant architecture: loosely coupled components, <em>replaceable at runtime</em>.",
      "cr.dsh": "The more advanced component model, and the serious techniques most harnesses never attempt: <em>projection-based compaction</em> and the sub-agent model.",
      "cr.oc": "Simplicity of use — the standing reminder that a powerful harness can still be obvious to drive.",
      "cr.rx": "The strict cache regime, working especially well for models with cheap cached tokens like DeepSeek — where cache hits are the economics of the turn.",

      "ins.kicker": "Install",
      "ins.h2": "Two minutes in.",
      "ins.node": "<span class=\"check\">✓</span> node / npm <span class=\"dim\">— optional: npx skills, npm MCP servers, TypeScript components (the core, clients and the TUI are Nim/Go — the installer asks)</span>",
      "ins.trf": "<span class=\"check\">✓</span> trafilatura <span class=\"dim\">— optional, richer HTML extraction</span>",
      "ins.fine": "Niffler is built from source and distributed that way — there are no prebuilt binaries. The one-line installer brings in everything missing (git, make, curl, Go, then the Nim toolchain, nimble packages and ripgrep via <code>make setup</code>); Node.js and npm are optional and it asks first; at the end it offers the optional extras one by one — language servers (<code>make install-lsp</code>), the agent CLI toolkit for bash (<code>make install-tools</code>) and jev (<code>make install-jev</code>) — each defaulting to no. Building by hand, <code>make doctor</code> reports what is missing. The bus is bundled and built from this repo — core spawns its own nats-server, never an external install. The desktop UI is an experimental spin-off — install it like any package: <code>cli install gokr/niffler-ui</code>. Full story in the <a href=\"https://github.com/gokr/niffler/blob/main/docs/MANUAL.md\">manual ↗</a>.",

      "foot.line": "Small by default. It builds the rest."
    },

    zh: {
      "skip": "跳到正文",
      "scroll.hint": "左右滑动查看更多 →",

      "nav.efficient": "高效",
      "nav.features": "特性",
      "nav.basics": "基础",
      "nav.clients": "客户端",
      "nav.arch": "架构",
      "nav.credits": "致谢",
      "nav.install": "安装",

      "hero.kicker": "可自我扩展的智能体框架",
      "hero.h1": "简单快速的框架。<br><em>功能一应俱全。</em>",
      "hero.lede1": "Niffler 由一个个小型 Unix 风格进程构成——每项能力都是挂在同一条 NATS 总线上的组件——因此智能体可以在<strong>对话中途编写、编译并启动自己的新工具</strong>。",
      "hero.lede2": "像最精简的编码代理一样便宜好用——而子代理、后台作业、权限门、MCP 与 LSP 都随盒提供。",
      "hero.release": "声明式设置域、可恢复工作区、不浪费回合",
      "hero.shotCap": "niffler-tui——共享本地实例的其中一个客户端。每一轮都会显示缓存命中率。",

      "fast.kicker": "快速且节省缓存",
      "fast.h2": "严格的缓存机制，<br><em>token 高效。</em>",
      "fast.body": "极小的基础提示和刻意精简的冻结工具集在整个对话生命周期内保持字节稳定，因此提供方缓存一轮接一轮保持命中。其余一切只需一次 <code>discover</code>/<code>invoke</code>——以历史形式进入，而不是撑大提示。",
      "fast.legend1": "缓存命中 · 250.3k",
      "fast.legend2": "本轮新增 · 1.8k",
      "fast.legend3": "99.3% —— 每一轮都显示在界面上",

      "cmp.row.base": "基础提示词",
      "cmp.row.first": "基础提示词 + 工具",
      "cmp.pi.note": "另有 3 个内置工具——grep · find · ls——默认关闭（<code>+grep</code> 可启用）",
      "cmp.nif.note": "整个目录（约 25 个组件）都在 discover / invoke 背后",
      "cmp.dsh.note": "开箱即用——所有基于 base 的配置（tui · web · headless）",
      "cmp.oc.note": "从 v1.18.32 的线上请求实测——v2 的文档列出的工具略有不同（多了 apply_patch · question · websearch）",
      "cmp.method.h": "如何理解这张表",
      "cmp.method.p": "≈ k tokens（字符数/4），来自各框架向空工作区发出的首个请求的确切字节——2026 年 10 月从真实线上请求捕获。用户内容不计入（Pi 默认把已安装的 skills 列进提示词，Niffler 会加上仓库的 AGENTS.md 链，Claude Code 会带上 CLAUDE.md）——五者采用完全相同的测量方式。",
      "cmp.more": "如何解读这些数字",
      "cmp.more2": "关于这张表",
      "cmp.more3": "这些数字如何采集",

      "feat.kicker": "有意思、却少见的特性",
      "feat.h2": "样样不算独一份——<br><em>齐聚一堂却很罕见。</em>",
      "feat.body": "这些并非 Niffler 独有。重要的是把它们全都装进一个小盒子里。",
      "f.sub.h": "子智能体",
      "f.sub.p": "交办后走开。它完成时会<em>唤醒你的对话</em>——之后还可以引导、继续或分叉。",
      "f.fleet.h": "Fleet——远程工作者",
      "f.fleet.p": "把目标交给另一台机器上的 worker——Incus 容器、Lima 虚拟机或 SSH 主机——受其运维者设定的预算上限约束，完成的工作进入人类收件箱。",
      "f.worktree.h": "隔离的 worktrees",
      "f.worktree.p": "有风险或并行的工作可以独占一个检出：<code>/worktree add</code> 在主检出旁开分支，<code>/worktree merge</code> 在其干净之前不触碰你的工作区即可合入。",
      "f.writes.h": "写入仲裁",
      "f.writes.p": "两个对话共享同一检出而不互相覆盖：重叠写入会被拒绝并指出持有者，不相交的文件仍然并行。是协调，不是围栏。",
      "f.bg.h": "后台进程",
      "f.bg.p": "服务器、监视器和构建都在框架下运行：启动、轮询、终止。不需要第二个终端，也不需要 tmux 纪律。",
      "f.gate.h": "权限审批",
      "f.gate.p": "工具可以先询问，子代理的受限调用也会转给<em>你</em>。无人可达即为拒绝——绝不会悄悄放行。",
      "f.self.h": "自我扩展",
      "f.self.p": "它写出源文件、编译、启动并调用新工具——<em>就在对话进行中</em>，任何语言皆可。",
      "f.fab.h": "可编程的工具调用",
      "f.fab.p": "<code>fabric</code> 编译一段来宾程序：十几次工具调用变成一次原生循环，预算与审批依然生效。",
      "f.proj.h": "作为投影的压缩",
      "f.proj.p": "上下文压力会走一条可见的阶梯：修剪，然后是可替换的压缩器，然后是省略，最后才是不迫已的裁剪。没有静默降级——被丢弃的一切仍然<em>可召回</em>。",
      "f.conv.h": "一个对话 = 一个进程",
      "f.conv.p": "每个对话都是独立进程：真正并行，一个 runner 死亡只会丢掉它正在处理的那一轮。",
      "f.lang.h": "任何语言",
      "f.lang.p": "组件就是普通进程：Nim、Go、TypeScript——或者一段完全不用 SDK 的 shell 脚本。语言只是偏好。",

      "ed.kicker": "所有你觉得理所当然的东西",
      "ed.h2": "基础门槛，<br><em>一项不少。</em>",
      "ed.body": "并不稀奇——但精简的 harness 会让你放弃其中大部分。Niffler 全部提供。",
      "ed.prov.h": "供应商，无需 JSON",
      "ed.prov.p": "一次调用即可添加后端，用 <code>/model</code> 和 <code>/effort</code> 随时切换——不用手工编辑配置文件。OpenAI 兼容、Anthropic 与 Codex 通道，或者用你的 ChatGPT/Claude <em>订阅</em>通过 OAuth 登录。固定选择按对话保存。一个提供方可以指定单独的 <code>embedModel</code>，让对话与嵌入由不同后端提供。",
      "ed.mcp.h": "MCP 进，工具出",
      "ed.mcp.p": "注册任意 MCP 服务器一次（stdio、http 或 sse）：每个服务器由一个受监管的桥接进程代言，其工具与提示词以<em>普通目录工具</em>的面貌出现——同样的发现方式、同样的审批门、同样的调用路径。",
      "ed.lsp.h": "属于你语言的 LSP",
      "ed.lsp.p": "诊断、定义、引用、悬停，全都来自真正的语言服务器：Go、Nim、TypeScript/JavaScript、Python、Rust、C/C++、Bash、Java、PHP、Ruby、C# 开箱即配。缺你的语言？往 <code>servers.json</code> 加一条——智能体自己也能加。",

      "ed.lab1": "代码、文件与网络",
      "ed.filetools.h": "文件工具",
      "ed.filetools.p": "批量分窗读取、定位即取的选择式读取、唯一匹配编辑并带回退保护、跨文件的字面量批量替换、原子写入、持久撤销",
      "ed.search.h": "搜索",
      "ed.search.p": "遵循 gitignore 的 grep 与文件查找——无状态副本让并行调用真正并行",
      "ed.git.h": "Git",
      "ed.git.p": "status、diff、log、show、blame——只读且免审批",
      "ed.web.h": "网页抓取",
      "ed.web.p": "真实的 HTML 正文提取、SSRF 校验、超大内容自动落盘",
      "ed.images.h": "图片",
      "ed.images.p": "截图进、多模态轮次出——含 MIME 校验、数量与像素预算",
      "ed.rmap.h": "仓库地图",
      "ed.rmap.p": "按价值排序的符号自动附加给够格的仓库",

      "ed.lab2": "对话与上下文",
      "ed.steer.h": "转向",
      "ed.steer.p": "在轮次进行中修正方向，无需取消正在进行的工作",
      "ed.recall.h": "完整找回",
      "ed.recall.p": "被裁剪或被压缩掉的消息仍可通过 <code>context_recall</code> 搜索",
      "ed.resume.h": "持久恢复",
      "ed.resume.p": "存储中的规范只追加历史——任务中途重启也能继续，附件一并保留",
      "ed.controls.h": "按对话控制",
      "ed.controls.p": "工具白名单、预算、工作区固定以及由人授予的额外根目录、供应商/模型/思考力度固定",
      "ed.introspect.h": "自我观察",
      "ed.introspect.p": "<code>/export</code> 导出发送给供应商的确切请求、<code>prompt_preview</code>、用 <code>context_status</code> 查看上下文健康状况与丢失归因、按角色统计、随时 <code>/compact</code>——<code>--log=debug</code> 将每次模型调用的耗时写入 <code>var/logs</code>",
      "ed.slash.h": "斜杠命令",
      "ed.slash.p": "内置一批——已安装的插件与 MCP 服务器还可以贡献更多",

      "ed.lab3": "信任与安全",
      "ed.approvals.h": "处处有审批",
      "ed.approvals.p": "任何受限调用方、包括子智能体——转给驱动本轮的人类；没有人可应答时默认拒绝，无人值守的常驻实例可选择按对话启用默认值",
      "ed.limits.h": "子智能体限额",
      "ed.limits.p": "无法被说服绕过的硬预算；软限额通过审批通道协商",
      "ed.grants.h": "记住的授权",
      "ed.grants.p": "按工具记住“不再询问”，程序形状的调用按内容摘要识别",
      "ed.writes.h": "并发写入冲突",
      "ed.writes.p": "重叠写入拒绝并指出持有者；取消操作释放已确认停止的写入者的占用，租约限定崩溃恢复期限，不相交路径仍可并行——这是协调，不是文件系统隔离",
      "ed.failclosed.h": "安全失败",
      "ed.failclosed.p": "超时即拒绝、未知限额即回绝、缺失组件明确降级——绝不悄悄进行",
      "ed.leastpriv.h": "最小权限",
      "ed.leastpriv.p": "MCP 环境变量白名单与守护进程，fabric 的执行器没有总线访问权也不带密钥，列表一律脱敏",
      "ed.hometrust.h": "首次打开需信任",
      "ed.hometrust.p": "打开克隆来的 harness home 时，只运行核心 bootstrap 集合——<code>store</code>、<code>bash</code>、<code>builder</code>、<code>llm</code>、<code>systemprompt</code>——直到 <code>NIF_TRUST</code> 或已记录的 <code>var/home-trust</code> 答复将其信任；已运行过的 home 继续可用，启动日志会逐一列出被跳过的组件",
      "ed.shellguard.h": "可选的 Shell 护栏",
      "ed.shellguard.p": "仅限 Linux 且默认关闭：单条 bash 命令得到只读的主机视图、私有 /tmp、没有网络也没有总线——而读取掩码无论护栏是否开启都会对读取与写入隐藏操作员指定的路径。掩码不是保密边界。",

      "ed.lab4": "生态与扩展",
      "ed.skills.h": "Agent Skills",
      "ed.skills.p": "SKILL.md 技能：列出、搜索、安装、审计——与更广泛的技术能生态互通",
      "ed.plugins.h": "插件",
      "ed.plugins.p": "GitHub 包克隆后从源码构建、经审批门安装，manifest v1 或 v2 配方",
      "ed.sdks.h": "三套 SDK",
      "ed.sdks.p": "Nim、Go、TypeScript 共享同一个极小的可移植编解码器——或者完全不用 SDK，shell 脚本直接讲协议",
      "ed.profiles.h": "工具配置档",
      "ed.profiles.p": "每个对话解析一次的具名工具集选择器，也可按需粘性提升工具",
      "ed.config.h": "统一设置面板",
      "ed.config.p": "每个组件都发布可发现的配置域：列出、查看与修补，带 schema 校验、比较并交换的修订号与审批——密钥脱敏，仅人类可写的键只有人能修改",
      "ed.store.h": "会回答问题的存储",
      "ed.store.p": "服务端全文搜索，以及在 SQLite 上对嵌入向量做最近邻搜索——同一份契约；TiDB 会明确报告不支持向量查询",

      "cl.kicker": "客户端，不是容器",
      "cl.h2": "框架<br><em>不是界面。</em>",
      "cl.body": "智能体、它的工具、作业与历史都存在于共享的本地<em>实例</em>中——而不是某个窗口里。客户端只是总线上的薄附着层，多个客户端可以共享同一实例。中途关掉终端什么也不会丢：作业继续运行，完成后再唤醒对话。",
      "cl.tui.p": "终端聊天客户端——按需启动框架的插件",
      "cl.cli.p": "无头驱动：从脚本或 CI 调用工具、安装包、跑完整轮次",
      "cl.console.p": "订阅总线并实时渲染每个 envelope——比 <code>nats sub</code> 好读",
      "cl.desktop.p": "实验性衍生包（<code>gokr/niffler-ui</code>）——同一根线，独立的仓库",
      "cl.fine": "服务模式完全不需要终端（<code>niffler &lt; /dev/null</code>）——而在终端里的 <code>niffler</code> 是管理壳（状态、目录、会话），不是聊天。",

      "un.kicker": "Unix 式架构",
      "un.h2": "小程序，<br><em>一根线。</em>",
      "un.body": "每项能力都是只做一件事的独立进程——自己的生命周期、自己的失败，与智能体的“大脑”隔离。一根线连接它们全部：NATS 上的 JSON envelope。所以智能体可以在<em>对话进行当中</em>编写、编译并启动新工具，而拆除只是 <code>exit()</code>。操作系统就是清理者。",
      "un.loop": "智能体在你和它交谈的同时，用任何语言扩展自己",
      "un.inv1": "最小配置 · 6 个进程",
      "un.inv2": "标准启动 · +23 个扩展组件",
      "un.inv3": "还附带 +10 个可选程序",
      "un.wire1": "调用落在 <code>svc.&lt;component&gt;.call</code>（core 提供 <code>svc.core.call</code>），事件在 <code>ev.*</code> 上广播——共四种：<code>call</code> · <code>result</code> · <code>event</code> · <code>error</code>。这就是总线契约的全部。",
      "un.wire2": "编解码器只是约 77 行纯 <code>std/json</code>，由 Nim、Go、TypeScript SDK 一比一复刻——规范：<a href=\"https://github.com/gokr/niffler/blob/main/docs/WIRE.md\" target=\"_blank\" rel=\"noopener\">docs/WIRE.md</a> · 设计缘由：<a href=\"https://github.com/gokr/niffler/blob/main/docs/research/REBOOT.md\" target=\"_blank\" rel=\"noopener\">research/REBOOT.md</a>",

      "cr.kicker": "灵感来源",
      "cr.h2": "该致谢的，<br><em>都要致谢。</em>",
      "cr.body": "Niffler 的目标是让人容易扩展——这一点与它最大的影响来源 Pi 一脉相承。它把自己的来路摆在明处。我们取了什么、取自哪里：",
      "cr.pi": "token 效率、极小的初始工具集、有自知之明的可扩展性——一个生来就为扩展而造的框架。Niffler 以同样的方式构建，并走向一种变体架构：松耦合的组件，<em>可在运行时替换</em>。",
      "cr.dsh": "更先进的组件模型，以及多数框架不敢尝试的硬技术：<em>基于投影的压缩</em>与子智能体模型。",
      "cr.oc": "易用性——时刻提醒我们：强大的框架依然可以一目了然。",
      "cr.rx": "严格的缓存机制，尤其适合 DeepSeek 这类缓存 token 便宜的模型——缓存命中就是每一轮的经济学。",

      "ins.kicker": "安装",
      "ins.h2": "两分钟，装好了。",
      "ins.node": "<span class=\"check\">✓</span> node / npm <span class=\"dim\">——可选：npx skills、npm MCP 服务器、TypeScript 组件（核心、客户端和 TUI 都是 Nim/Go——安装器会询问）</span>",
      "ins.trf": "<span class=\"check\">✓</span> trafilatura <span class=\"dim\">——可选，HTML 正文提取更佳</span>",
      "ins.fine": "Niffler 从源码构建、也以源码分发——没有预编译二进制。一行安装器补齐所有缺失的依赖（git、make、curl、Go，随后通过 <code>make setup</code> 装好 Nim 工具链、nimble 包和 ripgrep）；Node.js 和 npm 是可选项，安装前会先询问；最后还会逐一询问可选的附加项——语言服务器（<code>make install-lsp</code>）、面向 bash 的智能体 CLI 工具集（<code>make install-tools</code>）和 jev（<code>make install-jev</code>）——默认都不安装。手动构建则用 <code>make doctor</code> 查看缺什么。总线随包自带并从本仓库构建——core 会启动自己的 nats-server，绝不依赖外部安装。桌面 UI 是实验性衍生品——像普通包一样安装：<code>cli install gokr/niffler-ui</code>。完整故事见<a href=\"https://github.com/gokr/niffler/blob/main/docs/MANUAL.md\">手册 ↗</a>。",

      "foot.line": "默认够小。其余的，它自己造。"
    },

    "zh-TW": {
      "skip": "跳至主要內容",
      "scroll.hint": "左右滑動查看更多 →",

      "nav.efficient": "高效",
      "nav.features": "特性",
      "nav.basics": "基礎",
      "nav.clients": "用戶端",
      "nav.arch": "架構",
      "nav.credits": "致謝",
      "nav.install": "安裝",

      "hero.kicker": "可自我擴充的代理框架",
      "hero.h1": "簡單快速的框架。<br><em>功能一應俱全。</em>",
      "hero.lede1": "Niffler 由一個個小型 Unix 風格行程組成——每項能力都是掛在同一條 NATS 匯流排上的元件——因此代理可以在<strong>對話中途編寫、編譯並啟動自己的新工具</strong>。",
      "hero.lede2": "像最精簡的編碼代理一樣便宜好用——而子代理、背景作業、權限門、MCP 與 LSP 都隨盒提供。",
      "hero.release": "宣告式設定域、可復原工作區、不浪費回合",
      "hero.shotCap": "niffler-tui——共享本機實例的其中一個用戶端。每一輪都會顯示快取命中率。",

      "fast.kicker": "快速且節省快取",
      "fast.h2": "嚴格的快取機制，<br><em>token 高效。</em>",
      "fast.body": "極小的基礎提示和刻意精簡的凍結工具集在整個對話生命週期內保持位元組穩定，因此提供方快取一輪接一輪保持命中。其餘一切只需一次 <code>discover</code>/<code>invoke</code>——以歷史形式進入，而不是撐大提示。",
      "fast.legend1": "快取命中 · 250.3k",
      "fast.legend2": "本輪新增 · 1.8k",
      "fast.legend3": "99.3% —— 每一輪都顯示在介面上",

      "cmp.row.base": "基礎提示詞",
      "cmp.row.first": "基礎提示詞 + 工具",
      "cmp.pi.note": "另有 3 個內建工具——grep · find · ls——預設關閉（<code>+grep</code> 可啟用）",
      "cmp.nif.note": "整個目錄（約 25 個元件）都在 discover / invoke 背後",
      "cmp.dsh.note": "開箱即用——所有基於 base 的設定（tui · web · headless）",
      "cmp.oc.note": "從 v1.18.32 的線上請求實測——v2 的文件列出的工具略有不同（多了 apply_patch · question · websearch）",
      "cmp.method.h": "如何理解這張表",
      "cmp.method.p": "≈ k tokens（位元組數/4），來自各框架向空工作區發出的首個請求的確切位元組——2026 年 10 月從真實線上請求擷取。使用者內容不計入（Pi 預設把已安裝的 skills 列進提示詞，Niffler 會加上儲存庫的 AGENTS.md 鏈，Claude Code 會帶上 CLAUDE.md）——五者採用完全相同的量測方式。",
      "cmp.more": "如何解讀這些數字",
      "cmp.more2": "關於這張表",
      "cmp.more3": "這些數字如何擷取",

      "feat.kicker": "有意思、卻少見的特性",
      "feat.h2": "樣樣不算獨一份——<br><em>齊聚一堂卻很罕見。</em>",
      "feat.body": "這些並非 Niffler 獨有。重要的是把它們全都裝進一個小盒子裡。",
      "f.sub.h": "子代理",
      "f.sub.p": "交辦後走開。它完成時會<em>喚醒你的對話</em>——之後還可以引導、繼續或分叉。",
      "f.fleet.h": "Fleet——遠端工作者",
      "f.fleet.p": "把目標交給另一台機器上的 worker——Incus 容器、Lima 虛擬機或 SSH 主機——受其維運者設定的預算上限約束，完成的工作進入人類收件匣。",
      "f.worktree.h": "隔離的 worktrees",
      "f.worktree.p": "有風險或並行的工作可以獨占一個檢出：<code>/worktree add</code> 在主檢出旁開分支，<code>/worktree merge</code> 在其乾淨之前不觸碰你的工作區即可合入。",
      "f.writes.h": "寫入仲裁",
      "f.writes.p": "兩個對話共享同一檢出而不互相覆蓋：重疊寫入會被拒絕並指出持有者，不相交的檔案仍然並行。是協調，不是圍欄。",
      "f.bg.h": "背景行程",
      "f.bg.p": "伺服器、監控器和建置都在框架下執行：啟動、輪詢、終止。不需要第二個終端，也不需要 tmux 紀律。",
      "f.gate.h": "權限審批",
      "f.gate.p": "工具可以先詢問，子代理的受限呼叫也會轉給<em>你</em>。無人可達即為拒絕——絕不會悄悄放行。",
      "f.self.h": "自我擴充",
      "f.self.p": "它寫出源檔案、編譯、啟動並呼叫新工具——<em>就在對話進行中</em>，任何語言皆可。",
      "f.fab.h": "可程式的工具呼叫",
      "f.fab.p": "<code>fabric</code> 編譯一段來賓程式：十幾次工具呼叫變成一次原生迴圈，預算與審批依然生效。",
      "f.proj.h": "作為投影的壓縮",
      "f.proj.p": "上下文壓力會走一條可見的階梯：修剪，然後是可替換的壓縮器，然後是省略，最後才是不迫已的裁剪。沒有靜默降級——被丟棄的一切仍然<em>可召回</em>。",
      "f.conv.h": "一個對話 = 一個行程",
      "f.conv.p": "每個對話都是獨立行程：真正並行，一個 runner 死亡只會丟掉它正在處理的那一輪。",
      "f.lang.h": "任何語言",
      "f.lang.p": "元件就是普通行程：Nim、Go、TypeScript——或者一段完全不用 SDK 的 shell 指令稿。語言只是偏好。",

      "ed.kicker": "所有你覺得理所當然的東西",
      "ed.h2": "基礎門檻，<br><em>一項不少。</em>",
      "ed.body": "並不稀奇——但精簡的 harness 會讓你放棄其中大部分。Niffler 全部提供。",
      "ed.prov.h": "供應商，無需 JSON",
      "ed.prov.p": "一次呼叫即可新增後端，用 <code>/model</code> 和 <code>/effort</code> 隨時切換——不用手動編輯設定檔。OpenAI 相容、Anthropic 與 Codex 通道，或者用你的 ChatGPT/Claude<em>訂閱</em>透過 OAuth 登入。固定選擇按對話保存。一個提供者可以指定單獨的 <code>embedModel</code>，讓對話與嵌入由不同後端提供。",
      "ed.mcp.h": "MCP 進，工具出",
      "ed.mcp.p": "註冊任一 MCP 伺服器一次（stdio、http 或 sse）：每個伺服器由一個受監管的橋接行程代言，其工具與提示詞以<em>普通目錄工具</em>的面貌出現——同樣的發現方式、同樣的審批門、同樣的呼叫路徑。",
      "ed.lsp.h": "屬於你語言的 LSP",
      "ed.lsp.p": "診斷、定義、引用、懸停，全都來自真正的語言伺服器：Go、Nim、TypeScript/JavaScript、Python、Rust、C/C++、Bash、Java、PHP、Ruby、C# 開箱即配。缺你的語言？往 <code>servers.json</code> 加一條——代理自己也能加。",

      "ed.lab1": "程式碼、檔案與網路",
      "ed.filetools.h": "檔案工具",
      "ed.filetools.p": "批次分窗讀取、定位即取的選擇式讀取、唯一匹配編輯並帶回退保護、跨檔案的字面量批次取代、原子寫入、持久復原",
      "ed.search.h": "搜尋",
      "ed.search.p": "遵循 gitignore 的 grep 與檔案尋找——無狀態副本讓平行呼叫真正平行",
      "ed.git.h": "Git",
      "ed.git.p": "status、diff、log、show、blame——唯讀且免審批",
      "ed.web.h": "網頁抓取",
      "ed.web.p": "真實的 HTML 內文提取、SSRF 驗證、超大內容自動落盤",
      "ed.images.h": "圖片",
      "ed.images.p": "截圖進、多模態輪次出——含 MIME 檢查、數量與像素預算",
      "ed.rmap.h": "儲存庫地圖",
      "ed.rmap.p": "按價值排序的符號自動附加給夠格的儲存庫",

      "ed.lab2": "對話與上下文",
      "ed.steer.h": "轉向",
      "ed.steer.p": "在輪次進行中修正方向，無需取消正在進行的工作",
      "ed.recall.h": "完整找回",
      "ed.recall.p": "被裁剪或被壓縮掉的訊息仍可透過 <code>context_recall</code> 搜尋",
      "ed.resume.h": "持久還原",
      "ed.resume.p": "儲存中的規範只附加歷史——任務中斷重啟也能繼續，附件一併保留",
      "ed.controls.h": "按對話控制",
      "ed.controls.p": "工具白名單、預算、工作區固定以及由人授予的額外根目錄、供應商/模型/思考力度固定",
      "ed.introspect.h": "自我觀察",
      "ed.introspect.p": "<code>/export</code> 匯出發送給供應商的確切請求、<code>prompt_preview</code>、用 <code>context_status</code> 檢視上下文健康狀況與遺失歸因、按角色統計、隨時 <code>/compact</code>——<code>--log=debug</code> 將每次模型呼叫的耗時寫入 <code>var/logs</code>",
      "ed.slash.h": "斜線指令",
      "ed.slash.p": "內建一批——已安裝的外掛與 MCP 伺服器還可以貢獻更多",

      "ed.lab3": "信任與安全",
      "ed.approvals.h": "處處有審批",
      "ed.approvals.p": "任何受限呼叫方、包括子代理——轉給驅動本輪的人類；沒有人可應答時預設拒絕，無人值守的常駐實例可選擇按對話啟用預設值",
      "ed.limits.h": "子代理限額",
      "ed.limits.p": "無法被說服繞過的硬預算；軟限額透過審批通道協商",
      "ed.grants.h": "記住的授權",
      "ed.grants.p": "按工具記住「不再詢問」，程式形狀的呼叫按內容摘要識別",
      "ed.writes.h": "並發寫入衝突",
      "ed.writes.p": "重疊寫入拒絕並指出持有者；取消操作釋放已確認停止的寫入者的占用，租約限定崩潰復原期限，不相交路徑仍可平行——這是協調，不是檔案系統隔離",
      "ed.failclosed.h": "安全失敗",
      "ed.failclosed.p": "逾時即拒絕、未知限額即回絕、缺失元件明確降級——絕不悄悄進行",
      "ed.leastpriv.h": "最小權限",
      "ed.leastpriv.p": "MCP 環境變數白名單與守護行程，fabric 的執行器沒有匯流排存取權也不帶金鑰，列表一律去識別化",
      "ed.hometrust.h": "首次開啟需信任",
      "ed.hometrust.p": "開啟複製而來的 harness home 時，只執行核心 bootstrap 集合——<code>store</code>、<code>bash</code>、<code>builder</code>、<code>llm</code>、<code>systemprompt</code>——直到 <code>NIF_TRUST</code> 或已記錄的 <code>var/home-trust</code> 答覆將其信任；已執行過的 home 繼續可用，啟動日誌會逐一列出被跳過的元件",
      "ed.shellguard.h": "可選的 Shell 護欄",
      "ed.shellguard.p": "僅限 Linux 且預設關閉：單條 bash 命令得到唯讀的主機檢視、私有 /tmp、沒有網路也沒有匯流排——而讀取遮罩無論護欄是否開啟都會對讀取與寫入隱藏操作員指定的路徑。遮罩不是保密邊界。",

      "ed.lab4": "生態與擴充",
      "ed.skills.h": "Agent Skills",
      "ed.skills.p": "SKILL.md 技能：列出、搜尋、安裝、稽核——與更廣泛的技能生態互通",
      "ed.plugins.h": "外掛",
      "ed.plugins.p": "GitHub 套件複製後從原始碼建置、經審批門安裝，manifest v1 或 v2 配方",
      "ed.sdks.h": "三套 SDK",
      "ed.sdks.p": "Nim、Go、TypeScript 共享同一個極小的可攜編解碼器——或者完全不用 SDK，shell 指令稿直接講協定",
      "ed.profiles.h": "工具設定檔",
      "ed.profiles.p": "每個對話解析一次的具名工具集選擇器，也可按需黏性提升工具",
      "ed.config.h": "統一設定面板",
      "ed.config.p": "每個元件都發布可發現的設定域：列出、檢視與修補，帶 schema 驗證、比較並交換的修訂號與審批——密鑰去識別化，僅人類可寫的鍵只有人能修改",
      "ed.store.h": "會回答問題的儲存",
      "ed.store.p": "伺服器端全文搜尋，以及在 SQLite 上對嵌入向量做最近鄰搜尋——同一份契約；TiDB 會明確回報不支援向量查詢",

      "cl.kicker": "用戶端，不是容器",
      "cl.h2": "框架<br><em>不是介面。</em>",
      "cl.body": "智能體、它的工具、作業與歷史都存在於共享的本地<em>實例</em>中——而不是某個視窗裡。用戶端只是匯流排上的薄附著層，多個用戶端可以共享同一實例。中途關掉終端什麼也不會丟：作業繼續執行，完成後再喚醒對話。",
      "cl.tui.p": "終端聊天用戶端——按需啟動框架的外掛",
      "cl.cli.p": "無頭驅動：從指令稿或 CI 呼叫工具、安裝套件、跑完整輪次",
      "cl.console.p": "訂閱匯流排並即時渲染每個 envelope——比 <code>nats sub</code> 好讀",
      "cl.desktop.p": "實驗性衍生套件（<code>gokr/niffler-ui</code>）——同一根線，獨立的儲存庫",
      "cl.fine": "服務模式完全不需要終端（<code>niffler &lt; /dev/null</code>）——而在終端裡的 <code>niffler</code> 是管理殼（狀態、目錄、工作階段），不是聊天。",

      "un.kicker": "Unix 式架構",
      "un.h2": "小程式，<br><em>一根線。</em>",
      "un.body": "每項能力都是只做一件事的獨立行程——自己的生命週期、自己的失敗，與代理的「大腦」隔離。一根線連接它們全部：NATS 上的 JSON envelope。所以代理可以在<em>對話進行當中</em>編寫、編譯並啟動新工具，而拆除只是 <code>exit()</code>。作業系統就是清理者。",
      "un.loop": "代理在你和它交談的同時，用任何語言擴充自己",
      "un.inv1": "最小設定 · 6 個行程",
      "un.inv2": "標準啟動 · +23 個擴充元件",
      "un.inv3": "還附帶 +10 個選配程式",
      "un.wire1": "呼叫落在 <code>svc.&lt;component&gt;.call</code>（core 提供 <code>svc.core.call</code>），事件在 <code>ev.*</code> 上廣播——共四種：<code>call</code> · <code>result</code> · <code>event</code> · <code>error</code>。這就是匯流排契約的全部。",
      "un.wire2": "編解碼器只是約 77 行純 <code>std/json</code>，由 Nim、Go、TypeScript SDK 一比一複刻——規範：<a href=\"https://github.com/gokr/niffler/blob/main/docs/WIRE.md\" target=\"_blank\" rel=\"noopener\">docs/WIRE.md</a> · 設計緣由：<a href=\"https://github.com/gokr/niffler/blob/main/docs/research/REBOOT.md\" target=\"_blank\" rel=\"noopener\">research/REBOOT.md</a>",

      "cr.kicker": "靈感來源",
      "cr.h2": "該致謝的，<br><em>都要致謝。</em>",
      "cr.body": "Niffler 的目標是讓人容易擴充——這一點與它最大的影響來源 Pi 一脈相承。它把自己的來路擺在明處。我們取了什麼、取自哪裡：",
      "cr.pi": "token 效率、極小的初始工具集、有自知之明的可擴充性——一個生來就為擴充而造的框架。Niffler 以同樣的方式構建，並走向一種變體架構：鬆耦合的元件，<em>可在執行時替換</em>。",
      "cr.dsh": "更先進的元件模型，以及多數框架不敢嘗試的硬技術：<em>基於投影的壓縮</em>與子代理模型。",
      "cr.oc": "易用性——時刻提醒我們：強大的框架依然可以一目了然。",
      "cr.rx": "嚴格的快取機制，尤其適合 DeepSeek 這類快取 token 便宜的模型——快取命中就是每一輪的經濟學。",

      "ins.kicker": "安裝",
      "ins.h2": "兩分鐘，裝好了。",
      "ins.node": "<span class=\"check\">✓</span> node / npm <span class=\"dim\">——選配：npx skills、npm MCP 伺服器、TypeScript 元件（核心、用戶端和 TUI 都是 Nim/Go——安裝器會詢問）</span>",
      "ins.trf": "<span class=\"check\">✓</span> trafilatura <span class=\"dim\">——選配，HTML 內文提取更佳</span>",
      "ins.fine": "Niffler 從原始碼建置、也以原始碼發佈——沒有預先編譯的二進位。一行安裝器補齊所有缺失的依賴（git、make、curl、Go，隨後透過 <code>make setup</code> 裝好 Nim 工具鏈、nimble 套件和 ripgrep）；Node.js 和 npm 是選配，安裝前會先詢問；最後還會逐一詢問可選的附加項目——語言伺服器（<code>make install-lsp</code>）、面向 bash 的代理 CLI 工具組（<code>make install-tools</code>）和 jev（<code>make install-jev</code>）——預設都不安裝。手動建置則用 <code>make doctor</code> 查看缺什麼。匯流排隨包自帶並從本儲存庫建置——core 會啟動自己的 nats-server，絕不依賴外部安裝。桌面 UI 是實驗性衍生品——像一般套件一樣安裝：<code>cli install gokr/niffler-ui</code>。完整故事見<a href=\"https://github.com/gokr/niffler/blob/main/docs/MANUAL.md\">手冊 ↗</a>。",

      "foot.line": "預設夠小。其餘的，它自己造。"
    }
  };

  // Completeness check: every locale must carry exactly the English keys.
  // A missing translation must fail loudly at development time, never ship
  // silently half-localized.
  (function checkCatalogs() {
    var en = Object.keys(CATALOGS.en).sort().join("\u0000");
    ["zh", "zh-TW"].forEach(function (loc) {
      var keys = Object.keys(CATALOGS[loc]).sort().join("\u0000");
      if (keys !== en) {
        var a = Object.keys(CATALOGS.en), b = Object.keys(CATALOGS[loc]);
        var missing = a.filter(function (k) { return b.indexOf(k) < 0; });
        var extra = b.filter(function (k) { return a.indexOf(k) < 0; });
        console.error("i18n: catalog drift in '" + loc + "' — missing:", missing, "extra:", extra);
      }
    });
  })();

  var STORAGE_KEY = "niffler-locale";

  function normalize(lang) {
    lang = String(lang || "").toLowerCase();
    if (lang.indexOf("zh") !== 0) return "en";
    return /(tw|hk|mo|hant)/.test(lang) ? "zh-TW" : "zh";
  }

  function pickLocale() {
    try {
      var saved = window.localStorage.getItem(STORAGE_KEY);
      if (saved && CATALOGS[saved]) return saved;
    } catch (e) { /* private mode etc. */ }
    return normalize(navigator.language);
  }

  function apply(loc) {
    if (!CATALOGS[loc]) loc = "en";
    var cat = CATALOGS[loc];
    document.querySelectorAll("[data-i18n]").forEach(function (el) {
      var v = cat[el.getAttribute("data-i18n")];
      if (v !== undefined) el.textContent = v;
    });
    document.querySelectorAll("[data-i18n-html]").forEach(function (el) {
      var v = cat[el.getAttribute("data-i18n-html")];
      if (v !== undefined) el.innerHTML = v;
    });
    document.documentElement.lang = loc === "zh" ? "zh-CN" : loc === "zh-TW" ? "zh-TW" : "en";
    document.querySelectorAll("[data-locale-btn]").forEach(function (btn) {
      btn.classList.toggle("active", btn.getAttribute("data-locale-btn") === loc);
    });
    try { window.localStorage.setItem(STORAGE_KEY, loc); } catch (e) { /* ignore */ }
  }

  document.querySelectorAll("[data-locale-btn]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      apply(btn.getAttribute("data-locale-btn"));
    });
  });

  apply(pickLocale());
})();
