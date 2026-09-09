# ifacedrift

`lib.mjs` is the shared toolkit every `svcNN.mjs` module builds on. It was
migrated to a new API and **every module still calls the old one**:

- `parse(raw)` — the `mode` option is now REQUIRED:
  `parse(raw, { mode: "<profile>" })`. The mode is not free choice: each
  module's own `// profile:` header directive says which mode it must pass
  (`strict` or `lenient`). Strict mode throws on whitespace-padded entries;
  lenient mode trims them.
- `format(obj, w)` — renamed with new semantics: `formatV2(obj, width)`.
  The width is per module: use the module's own `// width:` directive.

Fix **every** `svcNN.mjs` so that it:

1. passes its own `profile` directive as `parse`'s mode;
2. passes its own `width` directive to `formatV2`;
3. keeps exporting `transform(raw)` returning the formatted string, and
   keeps its header directives (`// profile:`, `// width:`) unchanged.

`lib.mjs` and `test.mjs` are fixed. `./test.sh` runs the verifier, which
checks each module against an independent reference implementation (clean
input, whitespace-padded input, duplicate-key input) and must exit 0.
