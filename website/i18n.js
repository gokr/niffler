/* niffler website — en/zh/zh-TW chrome localization.
 * English lives in the HTML (no catalog needed); zh and zh-TW translate
 * every data-i18n / data-i18n-html element. The choice persists to
 * localStorage and falls back to navigator.language
 * (zh-Hant/TW/HK -> Traditional, other zh -> Simplified). */

(function () {
  "use strict";

  var CATALOGS = {
    zh: {
      "nav.why": "为什么",
      "nav.architecture": "架构",
      "nav.quickstart": "快速开始",
      "nav.components": "组件",
      "nav.wire": "协议",
      "nav.status": "状态",
      "nav.gitclone": "git clone",
      "hero.h1": "一个在对话中途<br><span class=\"accent\">把自己扩建出来</span>的 harness。",
      "hero.sub": "Niffler 是一个极简、可自我扩展的 agent harness。组件是<strong>进程</strong>，总线是<strong>NATS</strong>，agent 在你和它对话时编写、编译并启动自己的工具。",
      "hero.ctaMake": "make && niffler-ui",
      "hero.ctaGithub": "github →",
      "hero.ctaDiscord": "discord →",
      "term.build": "构建 core + 组件 + 桌面 UI · UI 会自动启动 harness",
      "term.l1": "→ 在 127.0.0.1:4222 启动 nats-server",
      "term.l2": "→ core 正在监听 svc.core.call",
      "term.typed": "niffler — 等待输入…",
      "why.title": "为什么",
      "why.1h": "<span class=\"num\">01</span> 进程，而非插件",
      "why.1p": "没有 dlopen、没有 ABI 边界、没有镜像腐烂。组件就是一个进程——拆除只需 <code>exit()</code>，操作系统就是完美的清理者。崩溃永远不会拖垮 harness。",
      "why.2h": "<span class=\"num\">02</span> 一种协议",
      "why.2p": "Core 只讲一种线上格式：NATS 之上的 JSON envelope。编解码器约 200 行、纯 <code>std/json</code>——SDK 用 Nim、Go、TypeScript，或你接下来移植的任何语言。",
      "why.3h": "<span class=\"num\">03</span> 自我扩展",
      "why.3p": "agent 写源码 → 调用 <code>builder.build</code> → 调用 <code>core.spawn</code> → 工具上线。添加能力就是一次工具调用，而且 LLM 在对话中途对自己完成它。社区包以同样的方式安装：<code>plugin_install</code> clone、从源码编译并启动——经审批门控，始终从发布的代码构建。",
      "why.4h": "<span class=\"num\">04</span> 形态持久化",
      "why.4p": "能力跨重启存续：已启动的组件记录在 store 里，开机时恢复。仓库即快照，<code>var/</code> 是一次性的。",
      "arch.title": "架构",
      "arch.core": "对话循环 · supervisor<br>catalog · dispatch",
      "arch.note1": "一个对话 = 一个进程：系统为每个对话启动一个 <code>var/bin/session &lt;id&gt;</code> runner——杀掉一个 runner，其他会话照常运行。",
      "arch.yourtool": "你的工具",
      "arch.anylang": "任意语言",
      "arch.note2": "每个方框都是一个用自己语言的组件 SDK 编写的小二进制——<br>对等、隔离、可单独杀掉。",
      "loop.title": "自我扩展循环",
      "qs.title": "快速开始",
      "qs.clone": "git clone git@github.com:gokr/niffler.git && cd niffler",
      "qs.setup": "# 环境依赖（Ubuntu / macOS）",
      "qs.make": "# 构建 core + 组件 + 桌面 UI，只需一次",
      "qs.run": "# 或点击桌面图标——自动启动 harness",
      "qs.test": "# 总线契约套件——17 个契约测试 + smoke + go 测试",
      "qs.see": "└─ make run / recover / dev · 见 docs/MANUAL.md",
      "qs.requirements": "环境需求",
      "qs.req.nim": "nim 2.x",
      "qs.req.go": "go",
      "qs.req.nats": "nats-server",
      "qs.req.node": "node / npm",
      "qs.req.wails": "wails cli <span class=\"dim\">（仅 UI）</span>",
      "qs.req.trafilatura": "trafilatura <span class=\"dim\">（可选，更丰富的 HTML 提取）</span>",
      "qs.note": "所有 Nim 依赖都来自 nimble——yaml、htmlparser、natswrapper、bitbarrel——首次构建时自动安装。",
      "comp.title": "自带组件",
      "comp.th.component": "组件",
      "comp.th.language": "语言",
      "comp.th.purpose": "用途",
      "comp.core.p": "对话循环、supervisor、catalog、dispatch",
      "comp.bash.p": "作为工具的 shell 访问——审批门控",
      "comp.builder.p": "把 agent 写的源码编译成二进制",
      "comp.store.p": "总线上的文档存储（bitbarrel 支撑，基于 rev 的并发）",
      "comp.plugins.p": "组件生态：topic 搜索、<code>niffler.json</code> 包、安装/更新/移除——始终从源码构建",
      "comp.skills.p": "Agent Skills 发现、渐进披露加载、资源，以及受管理的安装/移除",
      "comp.fetch.p": "有界 HTTP(S) 抓取，支持方法/头/体，Trafilatura 优先的 HTML 提取，纯 Nim 回退，超大结果落盘",
      "comp.hashline.p": "哈希锚定文件编辑：在稳定行锚点上做 <code>read</code>/<code>replace</code>/<code>undo_last_replace</code>",
      "comp.grep.p": "ripgrep 支撑的内容搜索与排序仓库文件列表，带精确截断标记",
      "comp.write.p": "审批门控的原子整文件写入，保留权限并创建父目录",
      "comp.observe.p": "总线实时检查——主题发现、监听探针、请求/响应追踪、监控",
      "comp.logfile.p": "<code>ev.log.*</code> 的持久 JSONL 汇聚——轮转日志、有界搜索、保留策略",
      "comp.models.p": "总线上的 models.dev 提供商/模型目录——离线种子、缓存刷新、<code>x-models-source</code> 插件补丁",
      "comp.provider.p": "store 支撑的 LLM 提供商注册表——add/list/switch/active/remove/export/import，live 后端切换",
      "comp.llm.p": "流式 OpenAI 兼容适配器（默认 DeepSeek）——实时 <code>ev.llm.token</code> 增量、推理 token、按调用取消",
      "comp.cli.p": "从脚本驱动 harness：<code>catalog</code>/<code>wait</code>/<code>call</code>/<code>install</code>——插件仓库的 CI 正门",
      "comp.console.p": "总线查看器——在 stdout 渲染每个 envelope（在第二个终端里跟随）",
      "comp.ui.p": "Wails SPA——一个 NATS 客户端，而不是 Wails 客户端",
      "comp.your.p": "移植 SDK——envelope 即产物（约 200 行）",
      "comp.your.name": "你的工具",
      "comp.your.lang": "任意",
      "wire.title": "一种协议，统领一切",
      "wire.note1": "core → <code>svc.core.call</code>，组件 → <code>svc.&lt;name&gt;.call</code>，<br>事件走 <code>ev.*</code>。这就是全部总线契约。",
      "wire.note2": "规范：<a href=\"https://github.com/gokr/niffler/blob/main/docs/WIRE.md\" target=\"_blank\" rel=\"noopener\">docs/WIRE.md</a> · 理由：<a href=\"https://github.com/gokr/niffler/blob/main/docs/REBOOT.md\" target=\"_blank\" rel=\"noopener\">docs/REBOOT.md</a>",
      "status.title": "状态",
      "status.i18n": "UI + TUI 界面本地化——en/zh/zh-TW 语言环境、CJK 安全截断",
      "status.l1": "wire 规范、envelope、Nim + Go + TypeScript SDK",
      "status.l2": "supervisor、catalog、dispatch",
      "status.l3": "bash + builder + store + llm（流式适配器）",
      "status.l4": "agent 端到端给自己加工具（用 DeepSeek 实测）",
      "status.l5": "跨重启的形态持久化",
      "status.l6": "session 服务 + Wails SPA 外壳",
      "status.l7": "session runner——一个对话 = 一个进程",
      "status.l8": "审批——终端 y/N、带 ack 的定向 UI 请求 + 广播回退、无头拒绝、resolved 事件清理",
      "status.l9": "恢复模式——<code>make recover</code>",
      "status.l10": "插件——组件生态（发现、安装、更新、移除）",
      "status.l11": "skills——Agent Skills 的渐进发现与加载",
      "status.l12": "fetch——有界网页抓取，Trafilatura 优先的文本提取",
      "status.l13": "hashline-edit——哈希锚定文件编辑",
      "status.l14": "grep + write——仓库搜索与原子整文件编辑",
      "status.l15": "console + cli——从终端跟随并驱动总线",
      "status.l16": "流式输出——UI 里实时 <code>ev.session.token</code> 增量",
      "status.l17": "UI：组件面板、工具运行视图、明暗主题、About 对话框",
      "status.l18": "总线契约测试套件——<code>make test</code>，每个测试隔离 NATS + 临时根目录",
      "status.l19": "tty 管理 shell——help/status/catalog/tools/sessions，REPL 里没有聊天",
      "status.l20": "observe + logfile——总线实时检查、持久轮转 JSONL 日志",
      "status.l21": "models——总线上的 models.dev 目录、目录驱动的上下文窗口",
      "status.l22": "provider——store 支撑的 LLM 提供商注册表、live 切换",
      "status.l23": "UI 自持生命周期——桌面图标即整个系统：构建一次，任何 UI 自动启动 core，最后一个 UI 停掉它",
      "status.l24": "最小启动配置——<code>--minimal</code> 只启动 store、bash 和 llm，同时保留被跳过的记录",
      "status.l25": "提供商/模型控制——已存提供商、模型选择、上下文仪表、live 会话状态",
      "status.l26": "渐进式工具发现——每会话不可变直接工具集、discover/invoke 网关、Live Components 暴露状态",
      "status.t1": "Level 1 UI 动态化（x-ui schema 提示）",
      "status.t2": "终端 harness + UI 的取消",
      "status.t3": "带 FTS + 向量记忆的 store-tidb",
      "footer.text": "niffler — 一个自我扩展的 agent harness · <a href=\"https://github.com/gokr/niffler\" target=\"_blank\" rel=\"noopener\">github.com/gokr/niffler</a> · <a href=\"https://discord.gg/ThJFEAJUAk\" target=\"_blank\" rel=\"noopener\">discord.gg/ThJFEAJUAk</a>"
    },
    "zh-TW": {
      "nav.why": "為什麼",
      "nav.architecture": "架構",
      "nav.quickstart": "快速開始",
      "nav.components": "組件",
      "nav.wire": "協定",
      "nav.status": "狀態",
      "nav.gitclone": "git clone",
      "hero.h1": "一個在對話中途<br><span class=\"accent\">把自己擴建出來</span>的 harness。",
      "hero.sub": "Niffler 是一個極簡、可自我擴展的 agent harness。組件是<strong>行程</strong>，匯流排是<strong>NATS</strong>，agent 在你和它對話時撰寫、編譯並啟動自己的工具。",
      "hero.ctaMake": "make && niffler-ui",
      "hero.ctaGithub": "github →",
      "hero.ctaDiscord": "discord →",
      "term.build": "建置 core + 組件 + 桌面 UI · UI 會自動啟動 harness",
      "term.l1": "→ 在 127.0.0.1:4222 啟動 nats-server",
      "term.l2": "→ core 正在監聽 svc.core.call",
      "term.typed": "niffler — 等待輸入…",
      "why.title": "為什麼",
      "why.1h": "<span class=\"num\">01</span> 行程，而非外掛",
      "why.1p": "沒有 dlopen、沒有 ABI 邊界、沒有映像腐爛。組件就是一個行程——拆除只需 <code>exit()</code>，作業系統就是完美的清理者。當機永遠不會拖垮 harness。",
      "why.2h": "<span class=\"num\">02</span> 一種協定",
      "why.2p": "Core 只講一種線上格式：NATS 之上的 JSON envelope。編解碼器約 200 行、純 <code>std/json</code>——SDK 用 Nim、Go、TypeScript，或你接下來移植的任何語言。",
      "why.3h": "<span class=\"num\">03</span> 自我擴展",
      "why.3p": "agent 寫原始碼 → 呼叫 <code>builder.build</code> → 呼叫 <code>core.spawn</code> → 工具上線。新增能力就是一次工具呼叫，而且 LLM 在對話中途對自己完成它。社群套件以同樣的方式安裝：<code>plugin_install</code> clone、從原始碼編譯並啟動——經核准門控，始終從發布的程式碼建置。",
      "why.4h": "<span class=\"num\">04</span> 形態持久化",
      "why.4p": "能力跨重啟存續：已啟動的組件記錄在 store 裡，開機時復原。倉庫即快照，<code>var/</code> 是一次性的。",
      "arch.title": "架構",
      "arch.core": "對話迴圈 · supervisor<br>catalog · dispatch",
      "arch.note1": "一個對話 = 一個程序：系統為每個對話啟動一個 <code>var/bin/session &lt;id&gt;</code> runner——殺掉一個 runner，其他對話照常執行。",
      "arch.yourtool": "你的工具",
      "arch.anylang": "任意語言",
      "arch.note2": "每個方框都是一個用自己語言的組件 SDK 撰寫的小二進位檔——<br>對等、隔離、可單獨殺掉。",
      "loop.title": "自我擴展迴圈",
      "qs.title": "快速開始",
      "qs.clone": "git clone git@github.com:gokr/niffler.git && cd niffler",
      "qs.setup": "# 環境依賴（Ubuntu / macOS）",
      "qs.make": "# 建置 core + 組件 + 桌面 UI，只需一次",
      "qs.run": "# 或點擊桌面圖示——自動啟動 harness",
      "qs.test": "# 匯流排契約套件——17 個契約測試 + smoke + go 測試",
      "qs.see": "└─ make run / recover / dev · 見 docs/MANUAL.md",
      "qs.requirements": "環境需求",
      "qs.req.nim": "nim 2.x",
      "qs.req.go": "go",
      "qs.req.nats": "nats-server",
      "qs.req.node": "node / npm",
      "qs.req.wails": "wails cli <span class=\"dim\">（僅 UI）</span>",
      "qs.req.trafilatura": "trafilatura <span class=\"dim\">（可選，更豐富的 HTML 擷取）</span>",
      "qs.note": "所有 Nim 依賴都來自 nimble——yaml、htmlparser、natswrapper、bitbarrel——首次建置時自動安裝。",
      "comp.title": "內建組件",
      "comp.th.component": "組件",
      "comp.th.language": "語言",
      "comp.th.purpose": "用途",
      "comp.core.p": "對話迴圈、supervisor、catalog、dispatch",
      "comp.bash.p": "作為工具的 shell 存取——核准門控",
      "comp.builder.p": "把 agent 寫的原始碼編譯成二進位檔",
      "comp.store.p": "匯流排上的文件儲存（bitbarrel 支撐，基於 rev 的並行）",
      "comp.plugins.p": "組件生態：topic 搜尋、<code>niffler.json</code> 套件、安裝/更新/移除——始終從原始碼建置",
      "comp.skills.p": "Agent Skills 發現、漸進揭露載入、資源，以及受管理的安裝/移除",
      "comp.fetch.p": "有界 HTTP(S) 擷取，支援方法/標頭/內文，Trafilatura 優先的 HTML 擷取，純 Nim 回退，超大結果落盤",
      "comp.hashline.p": "雜湊錨定檔案編輯：在穩定行錨點上做 <code>read</code>/<code>replace</code>/<code>undo_last_replace</code>",
      "comp.grep.p": "ripgrep 支撐的內容搜尋與排序倉庫檔案列表，帶精確截斷標記",
      "comp.write.p": "核准門控的原子整檔寫入，保留權限並建立父目錄",
      "comp.observe.p": "匯流排即時檢查——主題發現、監聽探針、請求/回應追蹤、監控",
      "comp.logfile.p": "<code>ev.log.*</code> 的持久 JSONL 匯聚——輪替日誌、有界搜尋、保留策略",
      "comp.models.p": "匯流排上的 models.dev 供應商/模型目錄——離線種子、快取重新整理、<code>x-models-source</code> 外掛修補",
      "comp.provider.p": "store 支撐的 LLM 供應商登錄檔——add/list/switch/active/remove/export/import，live 後端切換",
      "comp.llm.p": "串流 OpenAI 相容配接器（預設 DeepSeek）——即時 <code>ev.llm.token</code> 增量、推理 token、按呼叫取消",
      "comp.cli.p": "從腳本驅動 harness：<code>catalog</code>/<code>wait</code>/<code>call</code>/<code>install</code>——外掛倉庫的 CI 正門",
      "comp.console.p": "匯流排檢視器——在 stdout 渲染每個 envelope（在第二個終端機裡跟隨）",
      "comp.ui.p": "Wails SPA——一個 NATS 客戶端，而不是 Wails 客戶端",
      "comp.your.p": "移植 SDK——envelope 即產物（約 200 行）",
      "comp.your.name": "你的工具",
      "comp.your.lang": "任意",
      "wire.title": "一種協定，統領一切",
      "wire.note1": "core → <code>svc.core.call</code>，組件 → <code>svc.&lt;name&gt;.call</code>，<br>事件走 <code>ev.*</code>。這就是全部匯流排契約。",
      "wire.note2": "規範：<a href=\"https://github.com/gokr/niffler/blob/main/docs/WIRE.md\" target=\"_blank\" rel=\"noopener\">docs/WIRE.md</a> · 理由：<a href=\"https://github.com/gokr/niffler/blob/main/docs/REBOOT.md\" target=\"_blank\" rel=\"noopener\">docs/REBOOT.md</a>",
      "status.title": "狀態",
      "status.i18n": "UI + TUI 介面在地化——en/zh/zh-TW 語言環境、CJK 安全截斷",
      "status.l1": "wire 規範、envelope、Nim + Go + TypeScript SDK",
      "status.l2": "supervisor、catalog、dispatch",
      "status.l3": "bash + builder + store + llm（串流配接器）",
      "status.l4": "agent 端到端給自己加工具（用 DeepSeek 實測）",
      "status.l5": "跨重啟的形態持久化",
      "status.l6": "session 服務 + Wails SPA 外殼",
      "status.l7": "session runner——一個對話 = 一個程序",
      "status.l8": "核准——終端機 y/N、帶 ack 的定向 UI 請求 + 廣播回退、無頭拒絕、resolved 事件清理",
      "status.l9": "復原模式——<code>make recover</code>",
      "status.l10": "外掛——組件生態（發現、安裝、更新、移除）",
      "status.l11": "skills——Agent Skills 的漸進發現與載入",
      "status.l12": "fetch——有界網頁擷取，Trafilatura 優先的文字擷取",
      "status.l13": "hashline-edit——雜湊錨定檔案編輯",
      "status.l14": "grep + write——倉庫搜尋與原子整檔編輯",
      "status.l15": "console + cli——從終端機跟隨並驅動匯流排",
      "status.l16": "串流輸出——UI 裡即時 <code>ev.session.token</code> 增量",
      "status.l17": "UI：組件面板、工具執行檢視、明暗主題、About 對話框",
      "status.l18": "匯流排契約測試套件——<code>make test</code>，每個測試隔離 NATS + 暫存根目錄",
      "status.l19": "tty 管理 shell——help/status/catalog/tools/sessions，REPL 裡沒有聊天",
      "status.l20": "observe + logfile——匯流排即時檢查、持久輪替 JSONL 日誌",
      "status.l21": "models——匯流排上的 models.dev 目錄、目錄驅動的上下文視窗",
      "status.l22": "provider——store 支撐的 LLM 供應商登錄檔、live 切換",
      "status.l23": "UI 自持生命週期——桌面圖示即整個系統：建置一次，任何 UI 自動啟動 core，最後一個 UI 停掉它",
      "status.l24": "最小啟動設定——<code>--minimal</code> 只啟動 store、bash 和 llm，同時保留被跳過的記錄",
      "status.l25": "供應商/模型控制——已存供應商、模型選擇、上下文儀表、live 對話狀態",
      "status.l26": "漸進式工具發現——每對話不可變直接工具集、discover/invoke 閘道、Live Components 暴露狀態",
      "status.t1": "Level 1 UI 動態化（x-ui schema 提示）",
      "status.t2": "終端機 harness + UI 的取消",
      "status.t3": "帶 FTS + 向量記憶的 store-tidb",
      "footer.text": "niffler — 一個自我擴展的 agent harness · <a href=\"https://github.com/gokr/niffler\" target=\"_blank\" rel=\"noopener\">github.com/gokr/niffler</a> · <a href=\"https://discord.gg/ThJFEAJUAk\" target=\"_blank\" rel=\"noopener\">discord.gg/ThJFEAJUAk</a>"
    }
  };

  var STORAGE_KEY = "niffler-lang";

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
    var cat = CATALOGS[locale];
    if (!cat) {
      // English lives in the HTML: nothing to do.
      document.documentElement.lang = "en";
      return;
    }
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
