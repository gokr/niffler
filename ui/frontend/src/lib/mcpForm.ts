export interface McpServer {
  name: string;
  type?: "stdio" | "http" | "sse" | "";
  enabled: boolean;
  toolCount: number;
  command?: string;
  args?: string[];
  envKeys?: string[];
  url?: string;
  headerKeys?: string[];
  component?: string;
  live?: boolean;
  registeredTools?: string[];
  approval?: string;
  expose?: string;
  effect?: string;
  concurrency?: string;
  cwd?: string;
  timeoutMs?: number;
  idleMs?: number;
  bridge?: { lastError?: string; retiring?: boolean; activeCalls?: number };
  error?: string;
}
export interface EditForm {
  name: string;
  type: "stdio" | "http" | "sse";
  command: string;
  args: string;
  env: string;
  cwd: string;
  url: string;
  headers: string;
  approval: "" | "always";
  expose: "ondemand" | "direct";
  effect: "read" | "write";
  concurrency: "parallel" | "serial";
  timeoutMs: string;
  idleMs: string;
  enabled: boolean;
  isEdit: boolean;
}
export function editForm(s?: McpServer): EditForm {
  return {
    name: s?.name ?? "", type: s?.type || "stdio", command: s?.command ?? "",
    args: JSON.stringify(s?.args ?? []), env: "", headers: "", cwd: s?.cwd ?? "",
    url: s?.url ?? "", approval: s?.approval === "always" ? "always" : "",
    expose: s?.expose === "direct" ? "direct" : "ondemand",
    effect: s?.effect === "read" ? "read" : "write",
    concurrency: s?.concurrency === "serial" ? "serial" : "parallel",
    timeoutMs: String(s?.timeoutMs ?? 0), idleMs: String(s?.idleMs ?? 0),
    enabled: s?.enabled ?? true, isEdit: !!s,
  };
}
export function parseKv(text: string): Record<string, string> | undefined {
  if (!text.trim()) return undefined; // keep existing secrets
  if (text.trim().startsWith("{")) {
    const value: unknown = JSON.parse(text);
    if (!value || typeof value !== "object" || Array.isArray(value) || Object.values(value).some(v => typeof v !== "string")) {
      throw new Error("Expected a JSON object with string values");
    }
    return value as Record<string, string>;
  }
  const out: Record<string, string> = Object.create(null);
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    const eq = line.indexOf("=");
    const colon = line.indexOf(":");
    const sep = eq >= 0 && (colon < 0 || eq < colon) ? eq : colon;
    const key = line.slice(0, sep).trim();
    if (sep <= 0 || !key || Object.hasOwn(out, key)) throw new Error("Expected unique KEY=VALUE entries");
    out[key] = line.slice(sep + 1); // secret values may contain whitespace
  }
  return out;
}
function milliseconds(value: string, label: string): number {
  const n = value.trim() ? Number(value) : 0;
  if (!Number.isInteger(n) || n < 0 || n > 86400000) throw new Error(`${label} must be an integer between 0 and 86400000`);
  return n;
}
export function formArguments(form: EditForm): Record<string, unknown> {
  const out: Record<string, unknown> = {
    name: form.name.trim(), type: form.type, approval: form.approval,
    expose: form.expose, effect: form.effect, concurrency: form.concurrency,
    enabled: form.enabled, timeoutMs: milliseconds(form.timeoutMs, "Timeout"),
    idleMs: milliseconds(form.idleMs, "Idle timeout"),
  };
  if (form.type === "stdio") {
    const args: unknown = JSON.parse(form.args.trim() || "[]");
    if (!Array.isArray(args) || args.some(v => typeof v !== "string")) throw new Error("Arguments must be a JSON array of strings");
    out.command = form.command.trim(); out.args = args; out.cwd = form.cwd.trim();
    const env = parseKv(form.env); if (env !== undefined) out.env = env;
  } else {
    out.url = form.url.trim();
    const headers = parseKv(form.headers); if (headers !== undefined) out.headers = headers;
  }
  return out;
}
