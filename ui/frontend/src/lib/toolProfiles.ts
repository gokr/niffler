import { send } from '../nats';

export function currentProfile(): string {
  return localStorage.getItem('niffler-current-tool-profile') ?? '';
}

export async function selectProfile(name: string): Promise<void> {
  if (name !== 'default') await send('core', 'profile', { op: 'get', name });
  localStorage.setItem('niffler-current-tool-profile', name === 'default' ? '' : name);
}

export async function componentsText(sessionId: string | null, filter = 'all'): Promise<string> {
  if (!['all', 'direct', 'discovered', 'undiscovered'].includes(filter)) {
    throw new Error('Expected all, direct, discovered or undiscovered');
  }
  const status = await send('core', 'status', {});
  const stored = sessionId ? await send('store', 'get', {kind: 'session', id: `${sessionId}:tools`}) : null;
  const exposure = stored?.value;
  const key = (c: string, n: string) => `${c}\0${n}`;
  const direct = new Set<string>((exposure?.direct ?? []).map((t: any) => key(t.component, t.name)));
  const seen = new Set<string>((exposure?.discovered ?? []).map((t: any) => key(t.component, t.name)));
  const lines = [exposure ? 'Tools in this conversation:' : 'No conversation tool snapshot yet; exposure unknown.'];
  for (const c of status.components ?? []) {
    if (!c.running) continue;
    const tools = (c.tools ?? []).map((t: any) => {
      const k = key(c.name, t.name);
      const state = t.schema?.['x-harness']?.hidden ? 'hidden' : !exposure ? 'unknown' : direct.has(k) ? 'direct' : seen.has(k) ? 'discovered' : 'undiscovered';
      return { name: t.name, state };
    });
    const visible = tools.filter((t: any) => filter === 'all' || t.state === filter);
    if (filter !== 'all' && !visible.length) continue;
    lines.push(`${c.name} (${visible.length}/${tools.length} tools)`, ...visible.map((t: any) => `  ${t.name} [${t.state}]`));
  }
  return lines.join('\n');
}
