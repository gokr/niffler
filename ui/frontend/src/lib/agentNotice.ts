// ev.agent.notice → human wording for the activity strip. Pure function on
// plain node (no NATS, no bundler) so the npm test pattern can pin it.
//
// The event payload is deliberately a POINTER (P0.1): {jobId, parent, child,
// status} — the bounded summary and the full reply live in the durable
// agentnotice/agentjob records, which the chat flow receives as folded
// messages. The activity strip names what happened and how to look closer.

export type AgentNoticePayload = {
  jobId?: string;
  parent?: string;
  child?: string;
  status?: string;
};

const cap = (s: unknown, n: number) => String(s ?? "").slice(0, n);

export function describeAgentNotice(p?: AgentNoticePayload | null): string {
  const src = p ?? {};
  const child = cap(src.child, 14) || "?";
  const status = cap(src.status, 12) || "?";
  const jobId = cap(src.jobId, 18);
  return `child ${child} ${status} · details: agent_status {jobId: "${jobId}"}`;
}
