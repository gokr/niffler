// Web UI participation in core's UI lease registry (core/uireg.nim), run on
// plain node (type stripping): no Wails, no NATS, no bundle. These tests pin
// the ownership rule the web client shares with the TUI (lease_test.go's
// uiStartupDecision) and the exact registry ops the bridge forwards.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  uiAttach,
  uiClaim,
  uiRegister,
  uiRenew,
  uiRelease,
  uiReleaseSession,
  uiStartupDecision,
} from '../src/lib/uiRegistry.ts';

/** A fake `send` that records every call and answers from a handler. */
function fakeBus(handler) {
  const calls = [];
  const send = async (component, tool, args, timeoutMs) => {
    calls.push({ component, tool, args, timeoutMs });
    return handler(args, calls.length);
  };
  return { send, calls };
}

// ---- uiStartupDecision: the shared ownership rule --------------------------

test('a conversation we own (or no coordination) is kept', () => {
  assert.deepEqual(uiStartupDecision({ claimed: true }, 'conv-fresh'), {
    switchTo: '',
    ownerNumber: 0,
  });
  // Registry unreachable: degrade silently, keep the session.
  assert.deepEqual(uiStartupDecision({ claimed: false, error: 'no route' }, 'conv-fresh'), {
    switchTo: '',
    ownerNumber: 0,
  });
});

test('a held conversation starts fresh and names the holder', () => {
  const d = uiStartupDecision({ claimed: false, ownerNumber: 2 }, 'conv-fresh');
  assert.equal(d.switchTo, 'conv-fresh');
  assert.equal(d.ownerNumber, 2);
});

test('a held conversation without a number still starts fresh', () => {
  const d = uiStartupDecision({ claimed: false }, 'conv-fresh');
  assert.equal(d.switchTo, 'conv-fresh');
  assert.equal(d.ownerNumber, 0);
});

// ---- registry ops ----------------------------------------------------------

test('uiRegister calls core ui register and reports the number', async () => {
  const { send, calls } = fakeBus(() => ({ ok: true, number: 3, leaseSecs: 20 }));
  const r = await uiRegister(send, 'ui-abc123');
  assert.deepEqual(r, { ok: true, number: 3 });
  assert.equal(calls[0].component, 'core');
  assert.equal(calls[0].tool, 'ui');
  assert.deepEqual(calls[0].args, { op: 'register', ui: 'ui-abc123' });
});

test('uiRenew reports a lapsed lease so the caller re-registers', async () => {
  // Warm lease: ok, no number change. Lapsed: ok=false (the expiry signal).
  let warm = true;
  const { send, calls } = fakeBus(() =>
    warm ? { ok: true, leaseSecs: 20 } : { ok: false }
  );
  assert.deepEqual(await uiRenew(send, 'ui-abc123'), { ok: true, number: 0 });
  warm = false;
  assert.deepEqual(await uiRenew(send, 'ui-abc123'), { ok: false, number: 0 });
  assert.deepEqual(calls.map((c) => c.args), [
    { op: 'renew', ui: 'ui-abc123' },
    { op: 'renew', ui: 'ui-abc123' },
  ]);
});

test('uiClaim reports the owner number on refusal', async () => {
  const { send, calls } = fakeBus(() => ({ ok: false, owner: 'ui-tui', number: 2 }));
  const r = await uiClaim(send, 'ui-abc123', 'conv-1');
  assert.deepEqual(r, { ok: false, ownerNumber: 2 });
  assert.deepEqual(calls[0].args, { op: 'claim', ui: 'ui-abc123', session: 'conv-1' });
});

test('release ops name the caller only', async () => {
  const { send, calls } = fakeBus(() => ({ ok: true }));
  await uiReleaseSession(send, 'ui-abc123', 'conv-1');
  await uiRelease(send, 'ui-abc123');
  assert.deepEqual(calls[0].args, { op: 'release_session', ui: 'ui-abc123', session: 'conv-1' });
  assert.deepEqual(calls[1].args, { op: 'release', ui: 'ui-abc123' });
});

// ---- uiAttach: register then claim ----------------------------------------

test('attach registers (keeping a warm number) and claims', async () => {
  const { send, calls } = fakeBus((args) =>
    args.op === 'register'
      ? { ok: true, number: 1, leaseSecs: 20 }
      : { ok: true }
  );
  const r = await uiAttach(send, 'ui-abc123', 'conv-1');
  assert.deepEqual(r, { registered: true, number: 1, claimed: true, ownerNumber: 0 });
  assert.deepEqual(
    calls.map((c) => c.args.op),
    ['register', 'claim']
  );
});

test('attach with no conversation claims nothing', async () => {
  const { send, calls } = fakeBus(() => ({ ok: true, number: 1 }));
  const r = await uiAttach(send, 'ui-abc123', null);
  assert.deepEqual(r, { registered: true, number: 1, claimed: true, ownerNumber: 0 });
  assert.deepEqual(
    calls.map((c) => c.args.op),
    ['register']
  );
});

test('attach surfaces a held conversation without throwing', async () => {
  const { send } = fakeBus((args) =>
    args.op === 'register' ? { ok: true, number: 4 } : { ok: false, number: 2 }
  );
  const r = await uiAttach(send, 'ui-abc123', 'conv-1');
  assert.equal(r.registered, true);
  assert.equal(r.number, 4);
  assert.equal(r.claimed, false);
  assert.equal(r.ownerNumber, 2);
  // The shared rule turns that into a fresh conversation.
  const d = uiStartupDecision(r, 'conv-fresh');
  assert.equal(d.switchTo, 'conv-fresh');
  assert.equal(d.ownerNumber, 2);
});

test('attach degrades when the registry is unreachable', async () => {
  const send = async () => {
    throw new Error('bus not connected');
  };
  const r = await uiAttach(send, 'ui-abc123', 'conv-1');
  assert.equal(r.registered, false);
  assert.equal(r.claimed, false);
  assert.match(r.error ?? '', /bus not connected/);
  // Degradation keeps the conversation: no switch.
  assert.deepEqual(uiStartupDecision(r, 'conv-fresh'), { switchTo: '', ownerNumber: 0 });
});

test('an error payload from core throws and degrades', async () => {
  const { send } = fakeBus(() => ({ error: 'ui claim needs ui and session' }));
  const r = await uiAttach(send, 'ui-abc123', 'conv-1');
  // register failed first, so no claim is attempted
  assert.equal(r.registered, false);
  assert.match(r.error ?? '', /needs ui and session/);
});
