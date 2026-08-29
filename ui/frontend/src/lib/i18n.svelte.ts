// UI chrome localization. Model-facing strings (tool schemas, system
// prompts, tool descriptions) deliberately stay English so model behavior
// is language-stable — only human-visible chrome text lives here.
//
// Catalog discipline: `en` is the source of truth; zh and zh-TW are typed
// as Record<DictKey, string>, so a missing or extra key in either language
// is a compile error (same contract as the desktop UIs we benchmarked).
// {placeholder} tokens are filled by t(key, vars) and must keep the same
// names across languages.
//
// Reactive via Svelte 5 runes (hence the .svelte.ts suffix): t() reads
// `current` during render, so every component calling it re-renders when
// the locale flips. The choice persists to localStorage and falls back to
// navigator.language (zh-Hant/TW/HK → Traditional, other zh → Simplified).

export type Locale = "en" | "zh" | "zh-TW";
export type DictKey = keyof typeof en;

const en = {
  "app.newSession": "+ New session",
  "app.session": "session {id}",
  "app.newSessionLabel": "new session",
  "app.connecting": "connecting…",
  "app.busConnected": "bus connected",
  "app.busUnreachable": "bus unreachable",
  "app.selectModel": "Select model",
  "app.model": "model:",
  "app.tokens": "{used} / {context} tokens",
  "app.switchLight": "Switch to light mode",
  "app.switchDark": "Switch to dark mode",
  "app.switchLanguage": "Switch language",
  "app.browserNotice": "Running in a browser — the bus bridge only exists inside the desktop shell. Launch it with",
  "app.unreachableNotice": "bus unreachable at {url} — start the harness and keep its terminal open:",
  "app.approvalRequired": "Approval required",
  "app.approvalWaiting": "A tool call with x-harness.approval is waiting for your ok:",
  "app.moreWaiting": "+ {n} more waiting",
  "app.autoApproving": "auto-approving this session:",
  "app.enterEsc": "Enter approve · Esc deny",
  "app.deny": "Deny",
  "app.approve": "Approve",
  "app.autoApprove": "Auto approve",
  "app.autoApproveTitle": "Approve and don't ask again for this tool for the rest of this session",
  "sessions.newSession": "New session",
  "sessions.notStarted": "not started yet",
  "sessions.rename": "Rename",
  "sessions.delete": "Delete session",
  "sessions.confirmDelete": "Click again to delete",
  "sessions.sure": "sure?",
  "chat.placeholder": "Ask Niffler to do something…",
  "model.search": "Search models…",
  "model.customId": "custom model id",
  "model.set": "Set",
  "model.useDefault": "Use provider default",
  "model.clearsOverride": "(clears override)",
  "model.searching": "Searching…",
  "model.noneFound": "No models found",
  "model.noneFoundFor": "No models found for \"{catalog}\"",
  "model.reason": "reason",
  "model.tools": "tools",
  "model.showing": "Showing {n} of {total} — narrow your search",
  "pm.title": "Providers",
  "pm.addProvider": "Add provider",
  "pm.editProvider": "Edit provider",
  "pm.save": "Save",
  "pm.saving": "Saving…",
  "pm.edit": "Edit",
  "pm.sure": "Sure?",
  "pm.remove": "Remove",
  "pm.active": "active",
  "pm.noKey": "no key",
  "pc.provider": "Provider",
  "pc.providerDetail": "Provider: {provider} ({source})",
  "components.direct": "direct",
  "components.seen": "seen",
  "components.demand": "demand",
  "components.internal": "internal",
  "components.noneSeen": "none seen yet",
  "components.exposureInit": "tool exposure initializes with the first turn",
  "components.noSession": "start or select a session to see tool exposure",
  "components.tools": "tools",
} as const;

const zh: Record<DictKey, string> = {
  "app.newSession": "+ 新会话",
  "app.session": "会话 {id}",
  "app.newSessionLabel": "新会话",
  "app.connecting": "连接中…",
  "app.busConnected": "总线已连接",
  "app.busUnreachable": "总线不可达",
  "app.selectModel": "选择模型",
  "app.model": "模型:",
  "app.tokens": "{used} / {context} 令牌",
  "app.switchLight": "切换到亮色模式",
  "app.switchDark": "切换到暗色模式",
  "app.switchLanguage": "切换语言",
  "app.browserNotice": "当前在浏览器中运行 — 总线桥接只存在于桌面外壳中。请用以下命令启动",
  "app.unreachableNotice": "无法连接 {url} 上的总线 — 请启动 harness 并保持其终端开启：",
  "app.approvalRequired": "需要批准",
  "app.approvalWaiting": "一个带 x-harness.approval 的工具调用正在等待你的确认：",
  "app.moreWaiting": "还有 {n} 个正在等待",
  "app.autoApproving": "本会话自动批准：",
  "app.enterEsc": "回车批准 · Esc 拒绝",
  "app.deny": "拒绝",
  "app.approve": "批准",
  "app.autoApprove": "自动批准",
  "app.autoApproveTitle": "批准，且本会话内不再询问该工具",
  "sessions.newSession": "新会话",
  "sessions.notStarted": "尚未开始",
  "sessions.rename": "重命名",
  "sessions.delete": "删除会话",
  "sessions.confirmDelete": "再次点击以删除",
  "sessions.sure": "确定?",
  "chat.placeholder": "让 Niffler 做点什么…",
  "model.search": "搜索模型…",
  "model.customId": "自定义模型 ID",
  "model.set": "设置",
  "model.useDefault": "使用提供商默认",
  "model.clearsOverride": "（清除覆盖）",
  "model.searching": "搜索中…",
  "model.noneFound": "未找到模型",
  "model.noneFoundFor": "未找到与 \"{catalog}\" 匹配的模型",
  "model.reason": "推理",
  "model.tools": "工具",
  "model.showing": "显示 {n} / {total} — 请缩小搜索范围",
  "pm.title": "提供商",
  "pm.addProvider": "添加提供商",
  "pm.editProvider": "编辑提供商",
  "pm.save": "保存",
  "pm.saving": "保存中…",
  "pm.edit": "编辑",
  "pm.sure": "确定？",
  "pm.remove": "移除",
  "pm.active": "激活",
  "pm.noKey": "无密钥",
  "pc.provider": "提供商",
  "pc.providerDetail": "提供商：{provider}（{source}）",
  "components.direct": "直接",
  "components.seen": "已见",
  "components.demand": "按需",
  "components.internal": "内部",
  "components.noneSeen": "尚未见过",
  "components.exposureInit": "工具暴露在首个回合后初始化",
  "components.noSession": "开始或选择会话以查看工具暴露",
  "components.tools": "工具",
};

const zhTW: Record<DictKey, string> = {
  "app.newSession": "+ 新對話",
  "app.session": "對話 {id}",
  "app.newSessionLabel": "新對話",
  "app.connecting": "連線中…",
  "app.busConnected": "匯流排已連線",
  "app.busUnreachable": "匯流排無法連線",
  "app.selectModel": "選擇模型",
  "app.model": "模型:",
  "app.tokens": "{used} / {context} 詞元",
  "app.switchLight": "切換到亮色模式",
  "app.switchDark": "切換到暗色模式",
  "app.switchLanguage": "切換語言",
  "app.browserNotice": "目前於瀏覽器中執行 — 匯流排橋接只存在於桌面外殼中。請用以下指令啟動",
  "app.unreachableNotice": "無法連線到 {url} 的匯流排 — 請啟動 harness 並保持其終端機開啟：",
  "app.approvalRequired": "需要核准",
  "app.approvalWaiting": "一個帶有 x-harness.approval 的工具呼叫正在等待你的確認：",
  "app.moreWaiting": "還有 {n} 個正在等待",
  "app.autoApproving": "本對話自動核准：",
  "app.enterEsc": "Enter 核准 · Esc 拒絕",
  "app.deny": "拒絕",
  "app.approve": "核准",
  "app.autoApprove": "自動核准",
  "app.autoApproveTitle": "核准，且本對話內不再詢問該工具",
  "sessions.newSession": "新對話",
  "sessions.notStarted": "尚未開始",
  "sessions.rename": "重新命名",
  "sessions.delete": "刪除對話",
  "sessions.confirmDelete": "再點一次以刪除",
  "sessions.sure": "確定?",
  "chat.placeholder": "讓 Niffler 做點什麼…",
  "model.search": "搜尋模型…",
  "model.customId": "自訂模型 ID",
  "model.set": "設定",
  "model.useDefault": "使用供應商預設值",
  "model.clearsOverride": "（清除覆寫）",
  "model.searching": "搜尋中…",
  "model.noneFound": "找不到模型",
  "model.noneFoundFor": "找不到符合 \"{catalog}\" 的模型",
  "model.reason": "推理",
  "model.tools": "工具",
  "model.showing": "顯示 {n} / {total} — 請縮小搜尋範圍",
  "pm.title": "供應商",
  "pm.addProvider": "新增供應商",
  "pm.editProvider": "編輯供應商",
  "pm.save": "儲存",
  "pm.saving": "儲存中…",
  "pm.edit": "編輯",
  "pm.sure": "確定？",
  "pm.remove": "移除",
  "pm.active": "啟用",
  "pm.noKey": "無金鑰",
  "pc.provider": "供應商",
  "pc.providerDetail": "供應商：{provider}（{source}）",
  "components.direct": "直接",
  "components.seen": "已見",
  "components.demand": "按需",
  "components.internal": "內部",
  "components.noneSeen": "尚未見過",
  "components.exposureInit": "工具暴露在第一回合後初始化",
  "components.noSession": "開始或選擇對話以查看工具暴露",
  "components.tools": "工具",
};

const DICTS: Record<Locale, Record<DictKey, string>> = { en, zh, "zh-TW": zhTW };
const STORAGE_KEY = "niffler-lang";

function detect(): Locale {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved === "en" || saved === "zh" || saved === "zh-TW") return saved;
  } catch {
    // localStorage unavailable — fall through to navigator.language
  }
  const nav = (navigator.language || "en").toLowerCase();
  if (nav.startsWith("zh")) {
    return nav.includes("tw") || nav.includes("hant") || nav.includes("hk")
      ? "zh-TW"
      : "zh";
  }
  return "en";
}

let current: Locale = $state(detect());

export function locale(): Locale {
  return current;
}

export function t(key: DictKey, vars?: Record<string, string>): string {
  const s = DICTS[current][key];
  if (!vars) return s;
  return s.replace(/\{(\w+)\}/g, (_, k: string) => vars[k] ?? `{${k}}`);
}

export function cycleLocale(): void {
  current = current === "en" ? "zh" : current === "zh" ? "zh-TW" : "en";
  try {
    localStorage.setItem(STORAGE_KEY, current);
  } catch {
    // non-fatal: the choice just won't survive a reload
  }
}
