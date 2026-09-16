// ev.agent.notice activity wording (P4.13), run on plain node (type
// stripping): the activity strip and this module must agree on what a
// settlement notice says — a pointer to the durable record, never a
// fabricated summary.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { describeAgentNotice } from '../src/lib/agentNotice.ts';

test('names the child, the outcome, and the recourse', () => {
  const s = describeAgentNotice({
    jobId: 'job-1234567890',
    parent: 'conv-1',
    child: 'agent-abcdef1234',
    status: 'done',
  });
  assert.match(s, /child agent-abcdef12 done/); // capped at 14
  assert.match(s, /agent_status \{jobId: "job-1234567890"\}/);
});

test('long ids are capped, not truncated mid-meaning', () => {
  const s = describeAgentNotice({
    jobId: 'job-' + 'x'.repeat(200),
    child: 'agent-' + 'y'.repeat(200),
    status: 'failed',
  });
  assert.ok(s.length < 120, `activity line too long: ${s.length}`);
  assert.match(s, /failed/);
});

test('missing fields degrade to placeholders instead of throwing', () => {
  const s = describeAgentNotice({});
  assert.match(s, /child \? \?/);
  assert.match(s, /agent_status/);
});

test('null payload degrades to placeholders instead of throwing', () => {
  const s = describeAgentNotice(null);
  assert.match(s, /child \? \?/);
});
