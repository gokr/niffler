# The Aider repo map — verified algorithm and Niffler port study

> Read from `~/git/harnesses/aider` (`5dc9490`, Apache-2.0), `aider/repomap.py`
> (867 lines) + `aider/queries/tree-sitter-language-pack/*-tags.scm` (32
> languages). Every claim below was verified against the source; the sample
> outputs were produced live from the real code. Companion: [AIDER.md](AIDER.md)
> §1 (the original steal note), [REPOMAP-SEAM](../WIRE.md) once the port lands.

## What it is, in one paragraph

A **1 KB attention allocator**: tree-sitter extracts definitions and
references from every source file (disk-cached by mtime), a file→file
reference graph gets a **personalized PageRank** (seeded from files the user
has in chat), and the highest-ranked files' *key definition lines* are
rendered — signature lines from real source, elided with `⋮` — under a hard
token budget found by binary search. The model sees the repo's load-bearing
shape without reading a file.

## Verified live

4 files (`repomap.py`, `base_coder.py`, `models.py`, `commands.py`), budget
700 tokens — the distinctive render (real code lines, `⋮` for elision):

```
aider/models.py:
⋮
│class ModelSettings:
⋮
│class ModelInfoManager:
│    MODEL_INFO_URL = (
│        "https://raw.githubusercontent.com/BerriAI/litellm/main/"
⋮
│    def get_model_info(self, model):
⋮
```

Whole aider repo (81 .py files, budget 1024): **cold 4.5 s, warm re-rank
0.1 s, 4.2 KB map**. The warm number is the one that matters in an agent
loop: the mtime-keyed tags cache means a re-map costs only graph + PageRank
+ render, no re-parsing.

## The algorithm, stage by stage

**1. Tags per file** (`get_tags_raw`). One tree-sitter parse per file, then
a per-language tags query (`<lang>-tags.scm`) whose captures use a naming
convention: `@name.definition.function` → kind `def`,
`@name.reference.call` → kind `ref`. Each Tag is
`(rel_fname, fname, line, name, kind)`. If a language's query yields defs
but no refs (cpp), **pygments lexing backfills refs** as every `Token.Name`
with `line=-1`. 32 languages ship queries in the language pack.

**2. Cache.** `diskcache.Cache` at `.aider.tags.cache.v4/` (SQLite), key =
abs fname, value = `{mtime, tags[]}`. Miss on mtime change. All cache
errors degrade to an in-memory dict.

**3. Graph** (`get_ranked_tags`). For all files:
- `defines[ident] = {files}`, `references[ident] = [files...]`
- **personalization**: files in chat get `100/len(files)`; mentioned
  filenames (and path components matching mentioned idents) get it too
- edges `referencer → definer`, weight = `mul * sqrt(num_refs)` where:
  - `mul *= 10` if ident is mentioned, or is snake/kebab/camel and ≥8 chars
    (long compound names are intentional, not noise)
  - `mul *= 0.1` if ident starts with `_` or has >5 definers (overloaded
    generic names)
  - `mul *= 50` if the *referencer* is a chat file (conversation-adjacent
    edges dominate)
  - defs with zero refs get a 0.1 self-edge (so they still enter the graph)

**4. PageRank** on the MultiDiGraph, `weight="weight"`,
`personalization` + `dangling=personalization` (so rank leaks back into
chat files rather than evaporating).

**5. Rank distribution.** Each node's rank splits across its out-edges
proportionally to weight; `ranked_definitions[(definer, ident)]` sums the
rank flowing into each definition. Sort desc. Definitions in chat files are
dropped (the model has them open already). Then top-ranked *files* with no
included tags are appended, then "special" files (README, Makefile —
`filter_important_files`).

**6. Budgeted render** (`get_ranked_tags_map_uncached`). Binary search over
"how many of the ranked tags to include": render `to_tree(ranked[:middle])`,
estimate tokens (sampled 1% for big strings), compare to budget, halve.
`to_tree` groups tags per file, passes the tag lines to **TreeContext**
(grep-ast) which prints each tag's line *with its enclosing structure*, `│`
prefix, `⋮` for elided spans — truncated to 100 chars/line. ±15% error band
accepted. Result memoized per `(files, budget)` key.

## Niffler port analysis

**Ports 1:1** — the whole scoring core: defines/references maps, edge
weights (including the snake/camel/_/>5-definers heuristics), rank
distribution, chat-file exclusion, binary-search budget. All pure data
structures; ~250 lines of Nim. **Deterministic** (sorted inputs, stable
tie-break) — satisfies our byte-identical-cache doctrine.

**Replacements:**

| Aider dependency | Niffler answer |
|---|---|
| `networkx.pagerank` (scipy) | hand-rolled power iteration on our edge list, ~50 lines; graph is ≤10⁴ nodes — 20 iterations, ~damping 0.85, converges to 1e-6 well under the tool budget |
| `diskcache` | `var/repomap-tags/` — per-file JSON or one SQLite; mtime key, CACHE_VERSION on format change. Same degradation rule: cache failure = in-memory |
| `grep_ast.TreeContext` render | v1: **our outline style** — `rel:line:col  kind  name` one-liners (consistent with lsp documentSymbol, ~10× smaller than aider's snippets). v2 (optional): aider-style signature lines read from source; we have the ranges already if tags carry them |
| pygments ref backfill | skip; regex ident-matcher floor (Reasonix-style) instead |
| `filename_to_lang` / parser pack | the tags seam (below) |

**The refs problem** (the real port decision). The graph needs
references, not just definitions — that's what makes it a *graph*. Options
per tier:

1. **tree-sitter queries** — port aider's `.scm` files (Apache-2.0, 32
   languages) and add our own (Nim first). The generated parsers are C, so a
   Nim binding is ~100 lines of `importc` against the C ABI — no existing
   binding needed (this resolves the open question in AIDER.md §1).
2. **universal-ctags** — defs for ~50 languages, refs only for some parsers
   (`--_xformat`/kind `r`); breadth fallback, weakest on refs.
3. **LSP** — defs via documentSymbol, refs only per-symbol via
   findReferences (a whole-repo sweep would be thousands of requests). Not
   viable as the graph source; fine as a semantic verifier.

   Recommended: tree-sitter primary (Nim/Go/TS/Python first), ctags breadth,
   regex floor. Aider's `CACHE_VERSION` bump on query changes is a pattern
   to copy.

**The Niffler twist — better personalization inputs.** Aider guesses
"files in chat" from the prompt. We *know*: the store's seen-state records
every file this conversation read or edited, and grep hits name the idents
the model is chasing. Personalization = recently-touched files (decay by
recency) + ident mentions. That's a strictly better seed than aider's, at
zero extra cost. A `focus` parameter on the tool covers the explicit case.

**Architecture** (per the seam discussion, AGENTS.md-compliant):

```
repomap component (feat/repomap)
  onDemand tool  repo_map {workspace, focus?, budget?}
  consumes: tags seam — per-file defs+refs from whichever provider
            (tree-sitter first; ctags breadth; regex floor)
  cache: var/repomap-tags (mtime-keyed) + in-memory map cache
  output: append-only tool result, deterministic, budget-capped
```

Baseprompt line only after the bench A/B proves the economics (full30 +
Multi10 with map on/off, same protocol as the read-outline change).

## Port plan

1. **tags seam + tree-sitter in Nim** — compile 4 grammars (nim/go/ts/py) to
   C, `importc` wrapper, port aider's tags queries; fixture-test defs+refs
   against this repo
2. **graph + PageRank + render** — pure Nim, golden tests (determinism,
   budget bounds, chat-file exclusion)
3. **`repo_map` component** — bus contract, cache in `var/`, onDemand tool
4. **bench A/B** — full30 with/without map in the systemprompt workflow;
   Multi10 spot-check on unfamiliar repos
5. later: aider-style signature render, personalization-from-store decay

Nothing here touches core: the component is a peer, the language knowledge
is data (queries + grammar choice), the tool is onDemand. Adding a language
= add a grammar + a tags query + a registry entry.
