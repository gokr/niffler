# Vendored C sources and tag queries

All third-party code in this directory is unmodified except where noted.

## tree-sitter runtime (`tree_sitter/`, `go/`, `python/`, `typescript/`)

- `tree_sitter/` — headers (`api.h`, `parser.h`, `array.h`, `alloc.h`) plus
  `lib/src/` from [tree-sitter v0.25.10](https://github.com/tree-sitter/tree-sitter)
  (MIT). `lib.c` and the wasm runtime are not compiled; `wasm_store.c` is
  compiled only for its no-op stubs.
- `go/parser.c` — [tree-sitter-go v0.23.4](https://github.com/tree-sitter/tree-sitter-go) (MIT)
- `python/parser.c`, `python/scanner.c` — [tree-sitter-python v0.23.6](https://github.com/tree-sitter/tree-sitter-python) (MIT)
- `typescript/parser.c`, `typescript/scanner.c` —
  [tree-sitter-typescript v0.23.2](https://github.com/tree-sitter/tree-sitter-typescript) (MIT).
  Modification: the scanner's `../../common/scanner.h` include was re-written
  to `../common/scanner.h`; the shared header itself is vendored in `common/`.

## Tag queries (`queries/`)

- `go-tags.scm`, `python-tags.scm` — from
  [Aider](https://github.com/Aider-AI/aider) `aider/queries/tree-sitter-language-pack/`
  (Apache-2.0), which vendor them from the tree-sitter grammars.
- `typescript-tags.scm` — from tree-sitter-typescript's own `queries/tags.scm`
  (MIT), extended with concrete-implementation patterns (`function_declaration`,
  `class_declaration`, `method_definition`, `variable_declarator`, call
  references) because the upstream file only covers declaration forms.

Both capture-name conventions (`@name.definition.*`/`@name.reference.*` and
`@name` + `@definition.*`) are classified by `tags.nim`.
