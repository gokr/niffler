import test from "node:test";
import assert from "node:assert/strict";
import { TodoStore } from "../lib/todos.mjs";

test("add assigns sequential ids and defaults done=false", () => {
  const s = new TodoStore();
  const a = s.add("buy milk");
  const b = s.add("walk dog");
  assert.deepEqual(a, { id: 1, text: "buy milk", done: false });
  assert.deepEqual(b, { id: 2, text: "walk dog", done: false });
});

test("complete marks done and returns the todo", () => {
  const s = new TodoStore();
  s.add("buy milk");
  const t = s.complete(1);
  assert.equal(t.done, true);
  assert.equal(t.text, "buy milk");
});

test("complete unknown id returns null", () => {
  const s = new TodoStore();
  assert.equal(s.complete(42), null);
});

test("list filters by done", () => {
  const s = new TodoStore();
  s.add("a");
  s.add("b");
  s.add("c");
  s.complete(2);
  assert.equal(s.list().length, 3);
  assert.deepEqual(s.list({ done: true }).map((t) => t.id), [2]);
  assert.deepEqual(s.list({ done: false }).map((t) => t.id), [1, 3]);
  assert.deepEqual(s.list().map((t) => t.text), ["a", "b", "c"]);
});

test("remove deletes and reports existence", () => {
  const s = new TodoStore();
  s.add("a");
  s.add("b");
  assert.equal(s.remove(1), true);
  assert.equal(s.remove(1), false);
  assert.deepEqual(s.list().map((t) => t.id), [2]);
});

test("stores are independent", () => {
  const s1 = new TodoStore();
  const s2 = new TodoStore();
  s1.add("only in s1");
  assert.equal(s2.list().length, 0);
});
