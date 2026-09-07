import test from "node:test";
import assert from "node:assert/strict";
import { diff, apply, deepEqual, escapeToken, unescapeToken } from "../lib/jsonpatch.mjs";

const roundtrip = (a, b) => assert.deepEqual(apply(diff(a, b), a), b);

test("deepEqual", () => {
  assert.ok(deepEqual({ a: 1, b: [1, 2] }, { b: [1, 2], a: 1 }));
  assert.ok(!deepEqual([1, 2], [2, 1]));
});

test("scalars: replace at root", () => {
  const ops = diff(1, 2);
  assert.deepEqual(ops, [{ op: "replace", path: "", value: 2 }]);
  roundtrip(1, 2);
});

test("no-op returns empty patch", () => {
  assert.deepEqual(diff({ a: 1, b: [1, 2] }, { a: 1, b: [1, 2] }), []);
});

test("object ops sorted by key", () => {
  const ops = diff({ a: 1, c: 3, d: 4 }, { b: 10, c: 9, e: 5 });
  // a removed, b added, c replaced, d removed, e added -> sorted key order
  assert.deepEqual(ops, [
    { op: "remove", path: "/a" },
    { op: "add", path: "/b", value: 10 },
    { op: "replace", path: "/c", value: 9 },
    { op: "remove", path: "/d" },
    { op: "add", path: "/e", value: 5 },
  ]);
  roundtrip({ a: 1, c: 3, d: 4 }, { b: 10, c: 9, e: 5 });
});

test("nested objects recurse instead of replace", () => {
  const ops = diff({ o: { x: 1, y: 2 } }, { o: { x: 1, y: 3 } });
  assert.deepEqual(ops, [{ op: "replace", path: "/o/y", value: 3 }]);
  roundtrip({ o: { x: 1, y: 2 } }, { o: { x: 1, y: 3 } });
});

test("type change is a replace", () => {
  const ops = diff({ a: [1] }, { a: { "0": 1 } });
  assert.deepEqual(ops, [{ op: "replace", path: "/a", value: { "0": 1 } }]);
  roundtrip({ a: [1] }, { a: { "0": 1 } });
});

test("array: remove then add (LCS keeps shared tail)", () => {
  const ops = diff([1, 2, 3], [2, 3, 4]);
  assert.deepEqual(ops, [
    { op: "remove", path: "/0" },
    { op: "add", path: "/2", value: 4 },
  ]);
  roundtrip([1, 2, 3], [2, 3, 4]);
});

test("array: multiple removes are emitted highest-index-first", () => {
  const ops = diff([1, 2, 3, 4], [2]);
  assert.deepEqual(ops, [
    { op: "remove", path: "/3" },
    { op: "remove", path: "/2" },
    { op: "remove", path: "/0" },
  ]);
  roundtrip([1, 2, 3, 4], [2]);
});

test("array: insertion in the middle", () => {
  const ops = diff(["a", "c"], ["a", "b", "c"]);
  assert.deepEqual(ops, [{ op: "add", path: "/1", value: "b" }]);
  roundtrip(["a", "c"], ["a", "b", "c"]);
});

test("array reorder round-trips", () => {
  roundtrip([1, 2, 3], [3, 2, 1]);
  roundtrip([1, 2, 3, 4, 5], [5, 1, 2, 3, 4]);
});

test("empty containers", () => {
  roundtrip([], [1, 2]);
  roundtrip([1, 2], []);
  roundtrip({}, { a: {} });
  roundtrip({ a: { b: 1 } }, {});
});

test("pointer escaping", () => {
  const doc = { "a/b": 1, "c~d": 2 };
  const ops = diff(doc, { "a/b": 2, "c~d": 3 });
  assert.deepEqual(ops, [
    { op: "replace", path: "/a~1b", value: 2 },
    { op: "replace", path: "/c~0d", value: 3 },
  ]);
  assert.equal(escapeToken("a/b~c"), "a~1b~0c");
  assert.equal(unescapeToken("a~1b~0c"), "a/b~c");
  roundtrip(doc, { "a/b": 2, "c~d": 3, e: { "x/y": [1] } });
});

test("apply: add appends at array length", () => {
  assert.deepEqual(apply([{ op: "add", path: "/2", value: 3 }], [1, 2]), [1, 2, 3]);
  assert.throws(() => apply([{ op: "add", path: "/5", value: 3 }], [1, 2]), Error);
});

test("apply: existence rules", () => {
  assert.throws(() => apply([{ op: "remove", path: "/x" }], {}), Error);
  assert.throws(() => apply([{ op: "replace", path: "/x", value: 1 }], {}), Error);
  assert.throws(() => apply([{ op: "add", path: "/x", value: 1 }], { x: 1 }), Error);
});

test("apply: bad pointer throws", () => {
  assert.throws(() => apply([{ op: "add", path: "x", value: 1 }], {}), Error);
});

test("apply: returns a NEW document, input untouched", () => {
  const doc = { a: 1 };
  const out = apply([{ op: "add", path: "/b", value: 2 }], doc);
  assert.deepEqual(out, { a: 1, b: 2 });
  assert.deepEqual(doc, { a: 1 });
});
