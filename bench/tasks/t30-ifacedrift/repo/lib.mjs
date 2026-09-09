// lib.mjs - the shared text toolkit (current API). DO NOT EDIT.
//
// parse(input, opts) -> object
//   input: entries "key=value" joined by ';'
//   opts.mode is REQUIRED: "strict" or "lenient"
//   - strict: keys and values must not carry surrounding whitespace and
//     must not repeat; any violation throws Error("strict parse: ...")
//   - lenient: whitespace around keys and values is trimmed; segments that
//     are empty after trimming are skipped; an entry without '=' throws
//     Error("lenient parse: ..."); duplicates throw
// formatV2(obj, width) -> string
//   keys sorted ascending; each line is key.padEnd(width, '.') + value;
//   lines joined with "\n". width must be >= the longest key length.

export function parse(input, opts) {
  if (!opts || (opts.mode !== "strict" && opts.mode !== "lenient")) {
    throw new Error('parse: opts.mode must be "strict" or "lenient"');
  }
  const out = {};
  for (const seg of input.split(";")) {
    if (opts.mode === "lenient" && seg.trim() === "") continue;
    const eq = seg.indexOf("=");
    if (eq < 0) throw new Error(opts.mode + " parse: no '=' in " + JSON.stringify(seg));
    let k = seg.slice(0, eq);
    let v = seg.slice(eq + 1);
    if (opts.mode === "lenient") {
      k = k.trim();
      v = v.trim();
    } else if (k !== k.trim() || v !== v.trim()) {
      throw new Error("strict parse: whitespace around key or value: " + JSON.stringify(seg));
    }
    if (Object.prototype.hasOwnProperty.call(out, k)) {
      throw new Error(opts.mode + " parse: duplicate key " + k);
    }
    out[k] = v;
  }
  return out;
}

export function formatV2(obj, width) {
  return Object.keys(obj).sort().map((k) => k.padEnd(width, ".") + obj[k]).join("\n");
}
