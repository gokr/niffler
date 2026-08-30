export interface ProviderSummary {
  nickname: string;
  baseUrl: string;
  model: string;
  catalog: string;
  context: number;
  plugin: string;
  active: boolean;
  hasKey: boolean;
  stripPrefix?: boolean;
}

export interface ResolvedConfig {
  ok: boolean;
  provider: string;
  providerSource: string;
  model: string;
  catalog: string;
  context: number;
  contextSource: string;
  output?: number;
  outputSource?: string;
  hasKey: boolean;
}

export interface SessionStatus {
  sessionId: string;
  provider?: string;
  providerSource?: string;
  model?: string;
  context?: number;
  contextSource?: string;
  promptTokens?: number;
  usedTokens?: number;
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
  };
}

export interface CatalogModel {
  id: string;
  name?: string;
  provider: string;
  reference: string;
  configured?: boolean;
  reasoning?: boolean;
  tool_call?: boolean;
  modalities?: { input?: string[]; output?: string[] };
  limit?: { context?: number; output?: number };
  cost?: { input?: number; output?: number };
}

export function fmtContext(n: number): string {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(n % 1_000_000 === 0 ? 0 : 1) + "M";
  if (n >= 1000) return Math.round(n / 1000) + "K";
  return String(n);
}

export function hostname(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return url;
  }
}

export function contextPct(used: number, ctx: number): number {
  if (ctx <= 0) return 0;
  return Math.round((used / ctx) * 100);
}
