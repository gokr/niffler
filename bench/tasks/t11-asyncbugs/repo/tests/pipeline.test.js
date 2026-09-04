const test = require('node:test');
const assert = require('node:assert');
const { fetchAll, retry, sequential } = require('../src/pipeline.js');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('fetchAll preserves input order', async () => {
  const urls = ['a', 'b', 'c'];
  const fetchOne = async (u) => {
    if (u === 'a') await sleep(40);
    if (u === 'c') await sleep(10);
    return u.toUpperCase();
  };
  const res = await fetchAll(urls, fetchOne);
  assert.deepStrictEqual(res, ['A', 'B', 'C']);
});

test('fetchAll with identical timings still ordered', async () => {
  const res = await fetchAll(['x', 'y'], async (u) => u + '!');
  assert.deepStrictEqual(res, ['x!', 'y!']);
});

test('retry resolves when a later attempt succeeds', async () => {
  let calls = 0;
  const fn = async () => {
    calls += 1;
    if (calls < 3) throw new Error('boom');
    return 'ok';
  };
  assert.strictEqual(await retry(fn, 3), 'ok');
  assert.strictEqual(calls, 3);
});

test('retry rejects with the last error after attempts', async () => {
  let calls = 0;
  const fn = async () => {
    calls += 1;
    throw new Error('fail-' + calls);
  };
  await assert.rejects(retry(fn, 2), /fail-3/);
  assert.strictEqual(calls, 3);
});

test('retry resolves immediately on first success', async () => {
  let calls = 0;
  const fn = async () => {
    calls += 1;
    return 'first';
  };
  assert.strictEqual(await retry(fn, 2), 'first');
  assert.strictEqual(calls, 1);
});

test('sequential awaits each fn and preserves order', async () => {
  const fns = [
    async () => { await sleep(20); return 'one'; },
    async () => { await sleep(5); return 'two'; },
  ];
  const res = await sequential(fns);
  assert.deepStrictEqual(res, ['one', 'two']);
  assert.strictEqual(res[1], 'two');
});
