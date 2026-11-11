# Local embedding models — what is actually out there, measured

Status: **research + two gaps fixed, a wiring defect found and fixed, and the
local install/bundle path measured end to end (§8).**
Nothing here needs a new harness abstraction: `llm.embed` already posts
OpenAI-compatible `{base}/embeddings`, so "local" is a provider record pointed
at localhost. The two registration gaps (§5) are closed, and — found while
closing them — `embedModel` had never reached the models catalog at all (§7),
so following §6's recommendation changed nothing before this worktree.

Everything below was measured on this machine on 2026-11-10 (no GPU, 367 GB
free, Python 3.12.3, no ollama/llama-server/llamafile installed).

## 1. The answer to "do we need a local Ollama?"

**No.** Ollama is the heaviest option on the list and buys nothing for
embeddings:

| Ollama | |
|---|---|
| Linux tarball | **1 545.8 MB** (`ollama-linux-amd64.tar.zst`, v0.40.16) |
| Plus the model | nomic-embed-text ≈ **270 MB** |
| Total | **~1.8 GB**, plus a daemon and a second package manager |

Its value is model management for *chat*. For one embedding model behind an
OpenAI-compatible route, three lighter paths exist, and the harness already
speaks all of them.

## 2. The options, by footprint

| Option | Install | Disk | Runtime | OpenAI `/embeddings`? |
|---|---|---|---|---|
| **llama.cpp `llama-server`** | one prebuilt tarball, no install step | **23.2 MB** binary + **~270 MB** Q4 GGUF (or 1.86 GB for the full tree) | native, single process | **yes** (`--embeddings`, `/v1/embeddings`) |
| **model2vec** (static embeddings) | `pip install model2vec` (numpy, tokenizers, safetensors — **no torch**) | **61.4 MB** (`minishlab/potion-base-8M`), 260 MB for the 32M | pure Python/numpy, **no GPU, no ONNX** | no — needs a ~40-line shim, or in-process use |
| **sentence-transformers** | `pip install sentence-transformers` | ~2 GB (pulls **torch**) + model | torch, CPU ok | no (needs a shim) |
| **transformers.js** (Node) | `npm i @huggingface/transformers` | ~300 MB (onnxruntime-node) | Node process, CPU | no (needs a shim) |
| **ollama** | 1.5 GB daemon | 270 MB model | daemon | yes (`/v1` shim) |
| **Synthetic API** (already configured) | nothing | 0 | network | **yes, verified** |

Notes that matter:

- **llama.cpp is the best local *server*.** A 23 MB static tarball, no
  installer, no daemon — `llama-server -m nomic.gguf --embeddings` listens on
  localhost and answers `/v1/embeddings`. It is the only local option that
  gives the harness a drop-in OpenAI route with nothing but a binary.
- **model2vec is the best local *library*.** 61 MB, no torch, no GPU, sub-ms
  embedding. Its models are *static* (a distilled token-lookup embedding, not
  a transformer): quality is below nomic on hard retrieval, well above nothing,
  and it is the cheapest way to have a real local embedder with no compiled
  dependency at all.
- **torch is the cost centre.** Anything `sentence-transformers`-shaped is a
  ~2 GB install to embed a few thousand strings; that is why it is listed and
  not recommended.

## 3. The model itself

`nomic-embed-text-v1.5` (768 dims; the card says an 8192-token window but the
GGUF serves **2048** without YaRN scaling — see §8, which corrects this) is the
one to standardize on: it is served by Synthetic (verified, see below), commonly published as
GGUF, and its dims already match the store's vector index for that width.

One trap worth documenting: **it wants task prefixes.** Documents are embedded
as `search_document: <text>` and queries as `search_query: <text>` (from the
model card). Synthetic's endpoint does *not* add them. Mixing prefixed and
unprefixed vectors in one index quietly degrades retrieval, so whatever writes
vectors must apply the prefix consistently — a note for the memory component's
vector mode, not a harness setting.

## 4. What is already true (measured today)

Synthetic **does** serve embeddings, despite omitting them from `/models`:

```
GET  /openai/v1/models          -> 13 chat models, no embed entries
POST /openai/v1/embeddings
  {"model":"hf:nomic-ai/nomic-embed-text-v1.5","input":["hello world"]}
  -> 200, 768 dims, ||v|| = 0.9998, batch of 2 works, usage reported
```

Also measured, so nobody repeats the probe:

- The model id **must** carry the `hf:` prefix — a bare `nomic-embed-text` is a
  400 telling you so.
- Of seven candidate ids, only `hf:nomic-ai/nomic-embed-text-v1.5` is accepted;
  `hf:BAAI/bge-m3`, `hf:intfloat/multilingual-e5-large`, `hf:Qwen/Qwen3-Embedding-8B`,
  `hf:google/embeddinggemma-300m` and two sentence-transformer ids all answer
  `Unsupported embeddings model`.
- **DeepSeek's first-party API has no embeddings at all**: `POST
  /embeddings` and `/v1/embeddings` both 404, and its `/models` lists chat
  models only. So the deepseek plugin correctly declares no embed model.

## 5. The two gaps (both small, both in `provider`)

`llm.embed` is complete and OpenAI-only by design. The blocker for a local
endpoint is *registration*, not inference:

1. **`provider_add` requires `apiKey`** (`"required": ["nickname","apiKey"]`,
   plus a hard `errors.New("apiKey required")`). A local llama-server or shim
   needs no key, so configuring one requires inventing a dummy string.
2. **`hasCredential()` requires a non-empty API key**, and `validStoredProvider`
   gates on it — so even a record written around the tool is treated as invalid.

**Both fixed** (in this worktree): `apiKey` is optional when `baseUrl` is a
loopback address (`127.0.0.1`/`localhost`/`::1`), and `hasCredential` accepts
"loopback base URL, no key". Nothing else changed: `llm.embed` already sends
whatever key it has (an empty `Authorization` is fine for llama-server, and the
shims ignore it). The refusal message now names the rule it enforced
(`apiKey required (only a loopback baseUrl may omit it)`) — the original text
made a keyless local runtime look like a malformed request.
`make test-embed-chain` pins both directions: a loopback record registers with
no key, and a remote one is still refused.

## 6. Recommendation

- **Now:** configure the Synthetic embed model — `provider_update {nickname:
  "synthetic", embedModel: "hf:nomic-ai/nomic-embed-text-v1.5"}`. Zero install,
  already paid for, verified working (and as of §7 actually reaches the
  catalog; before that this recommendation was a no-op). This is the path the
  memory component should use first.
- **If offline is required:** `llama-server` with a Q4 GGUF of the same model,
  as a second provider record (`baseUrl: http://127.0.0.1:8080/v1`, **no
  apiKey**). Measured cost and gotchas are in §8 — 107 MB total, but *keep
  `-b 2048 -ub 2048`* (the batch default of 512 fails long inputs) and treat
  **2048 tokens as the real window** unless YaRN is enabled. Note the dims stay
  768, so both answer the same vec0 table — but vectors from two different
  runtimes of one model are *not* interchangeable; keep one embedder per store,
  and put the model id in the embedding document (it already is).
- **A local embedder is the default-on candidate, not an opt-in one.** Unlike
  von (5.4 GB, `make install-jev`), 107 MB and no daemon makes "bundled with the
  harness" defensible. The open questions are the ones §8 names — resolving a
  rolling llama.cpp tag with an asset, and per-platform runner builds — so this
  belongs as a `scripts/install-embed.*` with a spawn record, mirroring
  `install-lsp.sh`, rather than in `make setup`.
- **Not recommended:** ollama (1.8 GB for the same shape), torch-based stacks
  (~2 GB), and a plugin-hosted in-process embedder (adds a Python/IPC runtime
  the harness does not have, to save one HTTP call).

## 7. `embedModel` was dead configuration (found 2026-11-10, fixed)

The wiring this document *assumes* did not exist. `updateEmbedDocumentsLocked`
in `components/models` has always read `provider["embedModel"]` when building
the embedding view, but nothing ever put it there: the catalog is projected from
the **models.dev baseline file**, while a configured embed model lives in a
**provider record** — a different document that `models` never read. So:

- `provider_update {embedModel: "..."}` reported success and stored it;
- `provider_list` showed it back, so it looked configured;
- `models_list {embed: true}`, `models_get` and `models_providers.embedModel`
  did not contain it — the last one is a third surface projected from the same
  empty document — so the embedder fell back and `llm.embed` reported
  `model not found`;
- the defect was invisible because the one Go unit test covering the embedding
  view **injected the field into its own fixture** — it asserted the projection,
  never the path from a stored record to the projection.

Fixed by reading each provider record's `embedModel` on refresh
(`catalogState.storedEmbedModels`) and holding it in its own field that every
rebuild overlays onto the baseline before the projection. A provider the
baseline has never heard of — a local llama-server, the whole point of this
document — gets a minimal document so its model is listable; a declared
`x-embed-source` patch still merges dimensions and window over it, which is the
only way a caller learns 384/512 (768/8192 for nomic) for a bare id.

Two details worth keeping if this code is ever reworked:

- **Not in `base`.** The obvious version writes `embedModel` straight into
  `c.base`. It passes the happy-path test and leaks forever: `base` is the
  baseline and is replaced wholesale on reload, while every rebuild derives
  from it, so a removed provider's model (or a cleared field) stays in the
  view. `TestClearedEmbedModelLeavesTheView` fails on that version by design.
- **Not on the idle seam.** It reads another component, so it stays where
  `refresh` already runs: an owned worker goroutine. `OnIdle` runs on the pump
  thread and a request/reply there stalls every message the component owes for
  the timeout. The component is already shaped for this — `models_refresh`
  only *queues* (`queued: true`) instead of refreshing inline, and the worker's
  timer drains it — so the new call inherits that placement rather than
  inventing a lane.

Asserted end to end by `make test-embed-chain` (`tests/t_embed_chain.nim`),
which drives the real tools rather than a fixture: a stored record's model
appears, an unknown local provider appears, dimensions and context arrive from a
declaration, and an embed model never enters the chat list (`models_list
{embed:false}`, where a chat request for it would be a 400).

**The general lesson:** when a component reads a field from a document it does
not own, a unit test that supplies the field proves only the projection. Prove
the source too, or the configuration is decorative.

## 8. Can nomic be installed trivially, or bundled? (measured 2026-11-10)

Yes to trivially installed; a qualified yes to bundled. Measured end to end on
this machine: downloaded llama.cpp, served the GGUF, and embedded through the
harness's own `llm.embed`.

### Trivial install — two files, no installer, no daemon

```
llama-b12253-bin-ubuntu-x64.tar.gz    23.2 MB   (CPU build; no CUDA/ROCm/Vulkan)
nomic-embed-text-v1.5.Q4_K_M.gguf     84.1 MB
```

That is **107 MB total** to have a working local embedder, against ollama's
~1.8 GB. Unpack, `LD_LIBRARY_PATH=… ./llama-server -m nomic.gguf --embeddings`,
and `/v1/embeddings` answers. Gone with `rm -rf`; no system state, no daemon to
babysit, no second package manager.

**Do not fetch "latest" for this.** `releases/latest` for llama.cpp resolves to
a tag (`v0.9.0`) carrying **one asset: `nightly-tag.txt`** — no binaries. The
builds live on the rolling tags (`b12253`, `prerelease: true`), ~38 assets per
tag, so an installer must resolve the newest tag with an asset rather than
`latest`. That is the kind of detail that turns a one-line script into a
support burden, and it belongs in a `scripts/install-embed.sh` the way
`install-lsp.sh` handles per-language server drift.

Quant sizes, if 84 MB is the wrong point: Q4_K_S 78.1, **Q4_K_M 84.1**,
Q5_K_M 99.6, Q8_0 146.1, f16 274.3, f32 547.7 MB. Q4_K_M is the sane default.

### Bundling — possible, with one caveat that changes the size of "bundle"

A GGUF is a single self-contained file: shipping the 84 MB model alongside the
harness is entirely reasonable, and it is the only artifact with licence
questions to check. What cannot be bundled as a single file is the *runner*:
the tarball is 56 MB unpacked (45 MB of it `llama-server` + the per-arch
`libggml-cpu-*.so` backends), it is dynamically linked, and the CPU kernels are
selected at load time. So "bundle nomic" = bundle 84 MB of weights, and either
ship the ~45 MB runner per platform or `require` a system llama.cpp.

### The context window: 8192 is NOT what you get by default

The model card says 8192 tokens and this document said so too (§3, corrected).
The **GGUF metadata says `nomic-bert.context_length = 2048`**, and llama-server
caps the slot to it (`the slot context (8192) exceeds the training context of
the model (2048) - capping`). Measured consequences:

| Request | Default (`-c 2048`) | `--rope-scaling yarn --rope-scale 4 -c 8192` |
|---|---|---|
| ~1000 tokens | 556 tok, 2.0 s | — |
| ~2000 tokens | 996 tok, 3.6 s | 996 tok, 4.1 s |
| ~4000 tokens | 1986 tok, 12.3 s | 1986 tok, 8.6 s |
| ~8000 tokens | **HTTP 500** | 3966 tok, 22.2 s |

Two separate limits were behind the failures, and mixing them up wastes an
afternoon:

- `-b`/`-ub` default to **512**, so a long input fails with `input (2206 tokens)
  is too large to process. increase the physical batch size` — even inside a
  2048 context. Set `-b 2048 -ub 2048` (or higher); this is *not* a context
  problem.
- Past the context, llama-server truncates silently at 2048 unless YaRN scaling
  is enabled. Retrieval quality past that point is the model's own extrapolation
  quality, not something the harness can assume.

Practical rule: **2048 tokens is the honest default window**; enable YaRN
explicitly if you intend to embed long documents and measure retrieval, do not
just raise `-c`.

### It works through the harness, keylessly (after two fixes)

Verified with the real component chain, not a shim: `provider_add {nickname,
baseUrl: http://127.0.0.1:18100/v1, model, embedModel}` with **no apiKey**, then
`llm.embed` → 768 dims, `usage.prompt_tokens` reported. Two defects blocked
exactly this configuration and are fixed:

1. **`llm` refused every keyless provider as "not found"** (`component/llm`,
   `classifyProviderReply`). The key field is `omitempty`, and an empty key is
   *legitimate* for a loopback endpoint, so inferring "usable" from the key
   alone rejected the local-server case outright — while §5's
   registration fix had carefully made that same record acceptable. `provider_get`
   now reports `hasKey` (the provider component's own `hasCredential()` verdict)
   and `llm` trusts it instead of re-deriving the loopback rule in a second
   place. Pinned by `tests/t_embed_chain.nim`.
2. **`embedModel` never reached the catalog** (§7), so the model could not be
   named even when the provider routed.

The lesson from both: this feature crossed three components (provider → models →
llm) and each boundary re-derived a rule its upstream already owned. The
keyless rule belongs to `provider`; the embed model belongs to the record. A
consumer that re-implements either gets the local case wrong.
