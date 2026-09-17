// Slash-command registry and dispatch contract, run on plain node (type
// stripping): no dependencies, no bundler, no NATS.
//
// The web client has three places that must agree: the declarations in
// slash.ts, the handler table in slashDispatch.ts, and the behavior a user
// gets. These tests pin the first two against each other and exercise the
// third through a fake SlashContext.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  builtinSlashCommands,
  commandUsage,
  subcommandNames,
  subcommandOf,
  subcommandTokens,
  slashCompletion,
  canonicalCommand,
} from '../src/lib/slash.ts';
import { declaredHandlerKeys, isBuiltinCommand, runBuiltinCommand, slashHandlers } from '../src/lib/slashDispatch.ts';

/** A SlashContext that records every effect a handler performs. */
function fakeCtx(overrides = {}) {
  const seen = { meta: [], error: [], commands: [], sends: [], adopted: [], submitted: [] };
  const ctx = {
    arg: '',
    meta: (text, sid) => seen.meta.push([text, sid]),
    error: (text) => seen.error.push(text),
    send: async (component, tool, args, timeoutMs) => {
      seen.sends.push({ component, tool, args, timeoutMs });
      return {};
    },
    command: (action) => seen.commands.push(action),
    submit: async (text) => seen.submitted.push(text),
    busy: () => false,
    session: () => 'conv-1',
    adoptSession: (id) => seen.adopted.push(id),
    newSessionId: () => 'generated-id',
    locale: () => 'en',
    setLocale: (l) => seen.commands.push('locale:' + l),
    thinkLevel: () => 'full',
    setThinkLevel: (l) => seen.commands.push('think:' + l),
    toolLevel: () => 'brief',
    setToolLevel: (l) => seen.commands.push('tools:' + l),
    isValidEffort: (l) => ['auto', 'low', 'medium', 'high'].includes(l),
    profile: () => '',
    setProfile: async (n) => seen.commands.push('profile:' + n),
    componentsText: async (filter) => 'components(' + filter + ')',
    statusText: async () => 'status text',
    infoText: async (sid) => 'info for ' + sid,
    helpText: () => 'help text',
    t: (key, vars) => key + (vars ? ' ' + JSON.stringify(vars) : ''),
    ...overrides,
  };
  return { ctx, seen };
}

test('every declared built-in has a handler, and every handler is declared', () => {
  const declared = declaredHandlerKeys().sort();
  const handled = Object.keys(slashHandlers).sort();
  const missing = declared.filter((k) => !handled.includes(k));
  const extra = handled.filter((k) => !declared.includes(k));
  assert.deepEqual(missing, [], 'declared but not handled: ' + missing.join(', '));
  assert.deepEqual(extra, [], 'handled but not declared: ' + extra.join(', '));
});

test('alias entries point at a canonical command and are not listed', () => {
  const all = builtinSlashCommands();
  for (const cmd of all.filter((c) => c.aliasOf)) {
    const target = all.find((c) => c.name === cmd.aliasOf);
    assert.ok(target, `/${cmd.name} aliases undisclosed /${cmd.aliasOf}`);
    assert.ok(!target.aliasOf, `/${cmd.name} aliases an alias (/${cmd.aliasOf})`);
    // An alias resolves to its target's entry, so no handler of its own.
    assert.equal(canonicalCommand(cmd.name)?.name, cmd.aliasOf);
  }
  // /help hides aliases; declaredHandlerKeys() has one key per canonical name.
  for (const cmd of all.filter((c) => c.aliasOf)) {
    assert.ok(!declaredHandlerKeys().includes(cmd.name), `alias /${cmd.name} got a handler key`);
  }
});

test('subcommands are declared, resolvable by alias, and completed', () => {
  const provider = builtinSlashCommands().find((c) => c.name === 'provider');
  assert.deepEqual(subcommandNames(provider), ['environment', 'strip']);
  assert.equal(subcommandOf(provider, 'strip')?.name, 'strip');
  assert.equal(subcommandOf(provider, 'environment')?.name, 'environment');
  assert.equal(subcommandOf(provider, 'env')?.name, 'environment', 'the env alias resolves');
  assert.equal(subcommandOf(provider, 'bogus'), undefined);
  // Completion offers the subcommands (aliases included) for the shared slot.
  assert.deepEqual(subcommandTokens(provider), ['environment', 'env', 'strip']);
  const completion = slashCompletion('/provider ', builtinSlashCommands());
  assert.equal(completion?.source?.tool, 'provider.provider_list');
  assert.deepEqual(completion?.values, ['environment', 'env', 'strip']);
});

test('usage lines come from the registry (params plus declared subcommands)', () => {
  const byName = new Map(builtinSlashCommands().map((c) => [c.name, c]));
  assert.equal(commandUsage(byName.get('provider')), ' [nickname|environment|strip]');
  assert.equal(commandUsage(byName.get('effort')), ' [auto|low|medium|high]');
  assert.equal(commandUsage(byName.get('discover')), ' [target]');
  assert.equal(commandUsage(byName.get('help')), '');
});

test('/provider dispatches nicknames and its declared subcommands', async () => {
  const nick = fakeCtx();
  await runBuiltinCommand('provider', 'deepseek', nick.ctx);
  assert.deepEqual(nick.seen.commands, ['provider-switch:deepseek']);

  const none = fakeCtx();
  await runBuiltinCommand('provider', '', none.ctx);
  assert.deepEqual(none.seen.commands, ['providers']);

  for (const name of ['environment', 'env']) {
    const env = fakeCtx();
    await runBuiltinCommand('provider', name, env.ctx);
    assert.deepEqual(env.seen.commands, ['provider-env'], `/${'provider ' + name}`);
  }
  const off = fakeCtx();
  await runBuiltinCommand('provider', 'strip off', off.ctx);
  assert.deepEqual(off.seen.commands, ['provider-strip:false']);
  const on = fakeCtx();
  await runBuiltinCommand('provider', 'strip', on.ctx);
  assert.deepEqual(on.seen.commands, ['provider-strip:true']);
});

test('aliases run their canonical handler', async () => {
  const models = fakeCtx();
  await runBuiltinCommand('models', 'default', models.ctx);
  assert.deepEqual(models.seen.commands, ['model-set:']);

  const newsession = fakeCtx();
  await runBuiltinCommand('newsession', 'conv-9', newsession.ctx);
  assert.deepEqual(newsession.seen.commands, ['new-session:conv-9']);

  const question = fakeCtx();
  await runBuiltinCommand('?', '', question.ctx);
  assert.deepEqual(question.seen.meta, [['help text', undefined]]);
});

test('/locale rejects an unknown language and accepts the declared enum', async () => {
  const bad = fakeCtx();
  await runBuiltinCommand('locale', 'klingon', bad.ctx);
  assert.equal(bad.seen.error.length, 1);
  assert.match(bad.seen.error[0], /unknown locale/);
  const good = fakeCtx();
  await runBuiltinCommand('locale', 'zh-TW', good.ctx);
  assert.deepEqual(good.seen.commands, ['locale:zh-TW']);
});

test('/discover declares its two argument forms and adopts a session', async () => {
  const byComponent = fakeCtx();
  await runBuiltinCommand('discover', 'weather', byComponent.ctx);
  assert.deepEqual(byComponent.seen.sends, [{
    component: 'core',
    tool: 'session',
    args: { sessionId: 'conv-1', profile: '', discovery: { component: 'weather' } },
    timeoutMs: 60000,
  }]);

  const byTool = fakeCtx();
  await runBuiltinCommand('discover', 'tool=weather_now', byTool.ctx);
  assert.deepEqual(byTool.seen.sends[0].args.discovery, { tools: ['weather_now'] });

  // No session yet: one is generated and adopted before the call.
  const fresh = fakeCtx({ session: () => undefined });
  await runBuiltinCommand('discover', 'weather', fresh.ctx);
  assert.deepEqual(fresh.seen.adopted, ['generated-id']);
  assert.equal(fresh.seen.sends[0].args.sessionId, 'generated-id');

  await assert.rejects(() => runBuiltinCommand('discover', '', fakeCtx().ctx), /Usage: \/discover/);
  await assert.rejects(
    () => runBuiltinCommand('discover', 'weather', fakeCtx({ busy: () => true }).ctx),
    /Wait for the current turn/,
  );
});

/** A fake ctx whose send replies with `reply` (an object, or a function of the
 * call), still recording every call — the controls read core's status
 * readback and surface its `error` field, so replies must be injectable. */
function fakeCtxReplying(reply) {
  const { ctx, seen } = fakeCtx();
  ctx.send = async (component, tool, args, timeoutMs) => {
    seen.sends.push({ component, tool, args, timeoutMs });
    return typeof reply === 'function' ? reply(component, tool, args) : reply;
  };
  return { ctx, seen };
}

test('/approvals and /limit are declared built-ins with their own completion', () => {
  const cmds = builtinSlashCommands();
  const approvals = cmds.find((c) => c.name === 'approvals');
  const limit = cmds.find((c) => c.name === 'limit');
  assert.ok(approvals?.builtin, '/approvals is a declared built-in');
  assert.ok(limit?.builtin, '/limit is a declared built-in');
  assert.equal(isBuiltinCommand('approvals'), true);
  assert.equal(isBuiltinCommand('limit'), true);
  // Declared params drive completion *and* validation.
  assert.deepEqual(approvals.params.map((p) => [p.name, p.kind, p.values]), [['mode', 'enum', ['ask', 'auto']]]);
  assert.deepEqual(limit.params.map((p) => [p.name, p.kind]), [['rounds', 'int'], ['tokens', 'int'], ['seconds', 'int']]);
  assert.deepEqual(subcommandNames(limit), ['clear']);
  assert.equal(subcommandOf(limit, 'clear')?.name, 'clear');
  assert.equal(subcommandOf(limit, 'reset'), undefined);
  assert.deepEqual(slashCompletion('/approvals ', cmds)?.values, ['ask', 'auto']);
  assert.deepEqual(slashCompletion('/limit ', cmds)?.values, ['clear']);
  assert.equal(commandUsage(approvals), ' [ask|auto]');
  assert.equal(commandUsage(limit), ' [rounds|clear] [tokens] [seconds]');
});

test('/approvals validates its declared enum before it reaches the bus', async () => {
  const bad = fakeCtxReplying({});
  await runBuiltinCommand('approvals', 'sometimes', bad.ctx);
  assert.deepEqual(bad.seen.sends, [], 'an invalid mode never becomes a control call');
  assert.equal(bad.seen.error.length, 1);
  assert.match(bad.seen.error[0], /expected one of ask, auto/);
});

test('/limit validates its declared int params and rejects unknown arguments', async () => {
  const nan = fakeCtxReplying({});
  await runBuiltinCommand('limit', 'rounds=many', nan.ctx);
  assert.deepEqual(nan.seen.sends, [], 'a non-numeric limit never becomes a control call');
  assert.match(nan.seen.error[0], /rounds: expected a number/);

  const unknown = fakeCtxReplying({});
  await runBuiltinCommand('limit', 'depth=3', unknown.ctx);
  assert.deepEqual(unknown.seen.sends, []);
  assert.match(unknown.seen.error[0], /unknown argument "depth"/);

  const extra = fakeCtxReplying({});
  await runBuiltinCommand('limit', 'clear rounds=5', extra.ctx);
  assert.deepEqual(extra.seen.sends, [], 'clear takes no arguments');
  assert.match(extra.seen.error[0], /limits\.clearArgs/);
});

test('/approvals auto issues the session control call and reports what core stored', async () => {
  const { ctx, seen } = fakeCtxReplying({ ok: true, approvals: 'auto', limits: { rounds: 0, tokens: 0, seconds: 0 } });
  await runBuiltinCommand('approvals', 'auto', ctx);
  assert.deepEqual(seen.sends, [{
    component: 'core',
    tool: 'session',
    args: { sessionId: 'conv-1', approvals: 'auto' },
    timeoutMs: 60000,
  }]);
  assert.equal(seen.meta.length, 1);
  assert.match(seen.meta[0][0], /^approvals\.updated/);
  assert.match(seen.meta[0][0], /approvals\.modeAuto/);

  // Core persists "ask" as the empty string; the label follows the readback.
  const ask = fakeCtxReplying({ ok: true, approvals: '', limits: { rounds: 0, tokens: 0, seconds: 0 } });
  await runBuiltinCommand('approvals', 'ASK', ask.ctx);
  assert.deepEqual(ask.seen.sends[0].args, { sessionId: 'conv-1', approvals: 'ask' });
  assert.match(ask.seen.meta[0][0], /approvals\.modeAsk/);
});

test('/limit sends the named dimensions and reports the stored triple', async () => {
  const { ctx, seen } = fakeCtxReplying({ ok: true, limits: { rounds: 10, tokens: 0, seconds: 0 } });
  await runBuiltinCommand('limit', 'rounds=10', ctx);
  assert.deepEqual(seen.sends, [{
    component: 'core',
    tool: 'session',
    args: { sessionId: 'conv-1', limits: { rounds: 10 } },
    timeoutMs: 60000,
  }]);
  assert.match(seen.meta[0][0], /^limits\.updated/);
  assert.match(seen.meta[0][0], /limits\.rounds/);

  // A positional value fills the first declared int param.
  const positional = fakeCtxReplying({ ok: true, limits: { rounds: 5, tokens: 0, seconds: 0 } });
  await runBuiltinCommand('limit', '5', positional.ctx);
  assert.deepEqual(positional.seen.sends[0].args, { sessionId: 'conv-1', limits: { rounds: 5 } });

  // Named triples keep the declaration order.
  const triple = fakeCtxReplying({ ok: true, limits: { rounds: 3, tokens: 4000, seconds: 90 } });
  await runBuiltinCommand('limit', 'rounds=3 tokens=4000 seconds=90', triple.ctx);
  assert.deepEqual(triple.seen.sends[0].args, {
    sessionId: 'conv-1',
    limits: { rounds: 3, tokens: 4000, seconds: 90 },
  });
});

test('/limit clear resets the triple through its declared subcommand', async () => {
  const { ctx, seen } = fakeCtxReplying({ ok: true, limits: { rounds: 0, tokens: 0, seconds: 0 } });
  await runBuiltinCommand('limit', 'clear', ctx);
  assert.deepEqual(seen.sends, [{
    component: 'core',
    tool: 'session',
    args: { sessionId: 'conv-1', limits: {} },
    timeoutMs: 60000,
  }]);
  assert.deepEqual(seen.meta, [['limits.cleared', undefined]]);
});

test('bare /approvals and /limit read the conversation status back', async () => {
  const status = { ok: true, approvals: 'auto', limits: { rounds: 10, tokens: 0, seconds: 90 } };

  const approvals = fakeCtxReplying(status);
  await runBuiltinCommand('approvals', '', approvals.ctx);
  assert.deepEqual(approvals.seen.sends.map((s) => s.args), [{ sessionId: 'conv-1', profile: '' }]);
  assert.match(approvals.seen.meta[0][0], /^approvals\.current/);
  assert.match(approvals.seen.meta[0][0], /approvals\.modeAuto/);

  const limits = fakeCtxReplying(status);
  await runBuiltinCommand('limit', '', limits.ctx);
  assert.deepEqual(limits.seen.sends.map((s) => s.args), [{ sessionId: 'conv-1', profile: '' }]);
  const text = limits.seen.meta[0][0];
  assert.match(text, /^limits\.current/);
  assert.match(text, /limits\.rounds/);
  assert.match(text, /limits\.seconds/);
  assert.doesNotMatch(text, /limits\.tokens/, 'a 0 dimension is not listed');
  assert.match(text, /limits\.hint/);

  // No soft limit at all reads as the localized "none".
  const none = fakeCtxReplying({ ok: true, limits: { rounds: 0, tokens: 0, seconds: 0 } });
  await runBuiltinCommand('limit', '', none.ctx);
  assert.match(none.seen.meta[0][0], /limits\.none/);
});

test('a core control error surfaces as a UI error, with no blind retry', async () => {
  const approvals = fakeCtxReplying({ error: 'approvals must be ask or auto (empty clears)' });
  await runBuiltinCommand('approvals', 'auto', approvals.ctx);
  assert.deepEqual(approvals.seen.error, ['approvals must be ask or auto (empty clears)']);
  assert.deepEqual(approvals.seen.meta, []);
  assert.equal(approvals.seen.sends.length, 1);

  const limits = fakeCtxReplying({ error: 'limit rounds must be between 1 and 200' });
  await runBuiltinCommand('limit', 'rounds=9999', limits.ctx);
  assert.deepEqual(limits.seen.error, ['limit rounds must be between 1 and 200']);
  assert.equal(limits.seen.sends.length, 1);

  const clear = fakeCtxReplying({ error: 'unknown limit rounds (rounds, tokens, seconds)' });
  await runBuiltinCommand('limit', 'clear', clear.ctx);
  assert.deepEqual(clear.seen.error, ['unknown limit rounds (rounds, tokens, seconds)']);
  assert.equal(clear.seen.sends.length, 1);
});

test('the conversation controls need a conversation', async () => {
  for (const [name, arg] of [['approvals', ''], ['approvals', 'auto'], ['limit', ''], ['limit', 'clear'], ['limit', 'rounds=4']]) {
    const { ctx, seen } = fakeCtxReplying({});
    ctx.session = () => undefined;
    await runBuiltinCommand(name, arg, ctx);
    assert.deepEqual(seen.sends, [], `/${name} ${arg} called the bus without a conversation`);
    assert.deepEqual(seen.error, ['controls.noSession']);
  }
});

test('every declared command is routable without throwing', async () => {
  // Commands that require an argument get one; the rest run bare.
  const argFor = { discover: 'weather' };
  for (const cmd of builtinSlashCommands()) {
    const { ctx, seen } = fakeCtx();
    await runBuiltinCommand(cmd.name, argFor[cmd.name] ?? '', ctx);
    assert.equal(seen.error.length, 0, `/${cmd.name} errored: ${seen.error.join('; ')}`);
    assert.equal(isBuiltinCommand(cmd.name), true);
  }
});
