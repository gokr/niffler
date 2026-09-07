// Minimal RFC 6902-style JSON Patch: diff + apply.
// See README.md for the exact op-order and array-diff rules.

export function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

export function deepEqual(a, b) {
  // JSON-value equality: objects order-insensitive, arrays order-sensitive.
  // TODO
  return JSON.stringify(a) === JSON.stringify(b);
}

// diff(a, b) -> array of ops {op: "add"|"remove"|"replace", path, value?}
// Canonical order per README.md. TODO.
export function diff(a, b) {
  return [];
}

// apply(ops, doc) -> new document (input must not be mutated).
// Invalid pointers must throw Error. TODO.
export function apply(ops, doc) {
  return doc;
}

// escapeToken / unescapeToken: RFC 6901 (~ -> ~0, / -> ~1). TODO.
export function escapeToken(t) {
  return t;
}
export function unescapeToken(t) {
  return t;
}
