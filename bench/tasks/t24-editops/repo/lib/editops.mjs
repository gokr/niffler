// Levenshtein alignment with deterministic tie-breaking.
// See README.md for the op encoding and the tie-break rule.

export function editOps(a, b) {
  // Returns an array of ops, left to right:
  //   { op: "keep", a }         a[a] kept
  //   { op: "sub", a, b, ch }   a[a] replaced by ch (= b[b])
  //   { op: "ins", b, ch }      ch inserted (ch = b[b])
  //   { op: "del", a }          a[a] deleted
  // TODO
  return [];
}

export function cost(ops) {
  // Number of non-keep ops. TODO
  return 0;
}

export function applyOps(a, ops) {
  // Reconstruct b from a and ops. Throws on inconsistent ops. TODO
  return a;
}
