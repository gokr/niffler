import test from "node:test";
import assert from "node:assert/strict";
import { editOps, cost, applyOps } from "../lib/editops.mjs";

test("identical strings are all keeps", () => {
  const ops = editOps("abc", "abc");
  assert.deepEqual(ops, [
    { op: "keep", a: 0 },
    { op: "keep", a: 1 },
    { op: "keep", a: 2 },
  ]);
  assert.equal(cost(ops), 0);
});

test("single substitution", () => {
  const ops = editOps("abc", "axc");
  assert.deepEqual(ops, [
    { op: "keep", a: 0 },
    { op: "sub", a: 1, b: 1, ch: "x" },
    { op: "keep", a: 2 },
  ]);
});

test("single insertion in the middle", () => {
  const ops = editOps("abc", "abxc");
  assert.deepEqual(ops, [
    { op: "keep", a: 0 },
    { op: "keep", a: 1 },
    { op: "ins", b: 2, ch: "x" },
    { op: "keep", a: 2 },
  ]);
});

test("single deletion at the front", () => {
  const ops = editOps("abc", "bc");
  assert.deepEqual(ops, [
    { op: "del", a: 0 },
    { op: "keep", a: 1 },
    { op: "keep", a: 2 },
  ]);
});

test("empty to string is all inserts", () => {
  assert.deepEqual(editOps("", "abc"), [
    { op: "ins", b: 0, ch: "a" },
    { op: "ins", b: 1, ch: "b" },
    { op: "ins", b: 2, ch: "c" },
  ]);
});

test("string to empty is all deletes", () => {
  assert.deepEqual(editOps("abc", ""), [
    { op: "del", a: 0 },
    { op: "del", a: 1 },
    { op: "del", a: 2 },
  ]);
});

test("kitten -> sitting is the classic distance 3", () => {
  const ops = editOps("kitten", "sitting");
  assert.equal(cost(ops), 3);
  assert.deepEqual(ops, [
    { op: "sub", a: 0, b: 0, ch: "s" }, // k -> s
    { op: "keep", a: 1 },               // i
    { op: "keep", a: 2 },               // t
    { op: "keep", a: 3 },               // t
    { op: "sub", a: 4, b: 4, ch: "i" }, // e -> i
    { op: "keep", a: 5 },               // n
    { op: "ins", b: 6, ch: "g" },       // g
  ]);
});

test("tie-break: equal-cost paths prefer sub over ins/del", () => {
  // ab -> ba has three 2-op paths; the rule must pick sub, sub.
  const ops = editOps("ab", "ba");
  assert.deepEqual(ops, [
    { op: "sub", a: 0, b: 0, ch: "b" },
    { op: "sub", a: 1, b: 1, ch: "a" },
  ]);
});

test("applyOps reconstructs b", () => {
  for (const [a, b] of [
    ["", ""], ["", "abc"], ["abc", ""], ["abc", "abc"], ["abc", "axc"],
    ["abcdef", "af"], ["flaw", "lawn"], ["gumbo", "gambol"],
    ["aaaa", "aa"], ["xyxxxy", "yxyxxx"],
  ]) {
    assert.equal(applyOps(a, editOps(a, b)), b, `${a} -> ${b}`);
  }
});

test("applyOps throws on inconsistent ops", () => {
  assert.throws(() => applyOps("abc", [{ op: "keep", a: 5 }]), Error);
  assert.throws(() => applyOps("abc", [{ op: "del", a: 5 }]), Error);
  assert.throws(() => applyOps("abc", [{ op: "ins", b: 9 }]), Error);
  assert.throws(() => applyOps("abc", [{ op: "bogus", a: 0 }]), Error);
});
