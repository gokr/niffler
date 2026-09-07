import { test } from 'node:test';
import assert from 'node:assert/strict';
import { editForm, formArguments, parseKv } from '../src/lib/mcpForm.ts';
import { slashUserMessage } from '../src/lib/slashResult.ts';

test('unrelated edits preserve serial/read and all non-secret settings', () => {
  const server = { name: 'fixture', enabled: true, toolCount: 1, effect: 'read', concurrency: 'serial', cwd: '/tmp/a', idleMs: 555, timeoutMs: 777, args: ['', ' leading ', 'a\nb'] };
  const form = editForm(server);
  form.approval = 'always';
  const args = formArguments(form);
  for (const field of ['effect', 'concurrency', 'cwd', 'idleMs', 'timeoutMs', 'args']) assert.deepEqual(args[field], server[field]);
  assert.equal(args.approval, 'always');
  assert.ok(!Object.hasOwn(args, 'env'));
});
test('empty arguments, cwd, zero timeouts and explicit secret clearing reach edit', () => {
  const form = editForm({ name: 'fixture', enabled: true, toolCount: 1, args: ['old'], cwd: '/old', timeoutMs: 555 });
  form.args = '[]'; form.cwd = ''; form.timeoutMs = '0'; form.env = '{}';
  const args = formArguments(form);
  assert.deepEqual(args.args, []); assert.equal(args.cwd, ''); assert.equal(args.timeoutMs, 0); assert.deepEqual(args.env, {});
});
test('invalid secret entries and durations are not silently discarded', () => {
  assert.throws(() => parseKv('missing-separator'));
  assert.throws(() => parseKv('KEY=a\nKEY=b'));
  assert.throws(() => parseKv('{"KEY":3}'));
  assert.equal(parseKv(''), undefined);
  assert.equal(parseKv('KEY= secret ')["KEY"], ' secret ');
  for (const value of ['-1', '10garbage', '1.5', '86400001']) {
    const form = editForm(); form.timeoutMs = value;
    assert.throws(() => formArguments(form));
  }
});
test('only explicit nonempty userMessage results enter user history', () => {
  assert.equal(slashUserMessage({ userMessage: '[user]\nGreet Ada', text: 'preview' }), '[user]\nGreet Ada');
  for (const value of [{ text: 'ordinary result' }, { userMessage: '' }, { userMessage: 1 }, null]) assert.equal(slashUserMessage(value), undefined);
});
