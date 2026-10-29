# full31 · Synthetic DeepSeek V4.1 Flash · Droid vs Niffler vs pi

Run `full31-syn-ds41-droid` (2026-10-29), model `syn-deepseek-v41`
(`hf:deepseek-ai/DeepSeek-V4.1-Flash` @ `api.synthetic.new/openai/v1`),
thinking profile `low`, rounds ≤6, 31 tasks, 3 lanes, 93 cells, all
`verdict: pass`, none `invalid`, none `leaked` — full detail in
[the report](full31-syn-ds41-droid-report.md).

Droid is Factory's CLI v0.251.0 in its **BYOK** mode: model wired through a
per-run `--settings` file (`customModels`,
`provider: generic-chat-completion-api`), **no Factory account and no
Factory credits involved** — provider usage is billed to Synthetic. The lane
is new in this repo (`bench/adapters/droid.mjs`); this is its first
end-to-end run.

## Headline

**full31 is saturated for this model class on all three lanes (31/31 each),**
so the comparison is entirely about *shape*: what each harness spends to get
there.

| lane | pass | wall (s) | LLM msgs | tool calls | tools/msg | tok total | uncached in | cache read | tok out | cost (Synthetic) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| droid | 31/31 | 30 | **1.9** | 8.3 | **4.4** | 71.4k | **3.4k** | 65.6k | 2.4k | $0.500 |
| niffler | 31/31 | 29 | 6.5 | 7.6 | 1.2 | 40.7k | 7.0k | 31.3k | 2.3k | $0.416 |
| pi | 31/31 | **24** | 5.3 | 5.0 | 0.9 | **23.2k** | 3.8k | 17.4k | 2.1k | **$0.257** |

Averages per cell. `LLM msgs` is each adapter's own assistant-message count,
so it is only comparable as *round-trip pressure*, not as an absolute: Droid
and OpenHands batch several tool calls into one assistant message, Niffler
and pi mostly do not.

## The trade, in one line

Droid's fixed surface is **~60 400 prompt tokens** (median over 31 tasks:
min 36.5k, max 137k) where Niffler's is **~3 050** (min 3 017, max 3 145) —
a 20× smaller prefix. Droid buys back the difference with
**~4.4 tool calls per assistant message** (it reads four files in one round
trip) versus Niffler's 1.2.

Neither wins outright:

- **Round trips:** Droid 1.9 vs Niffler 6.5 — Droid needs a third of the
  requests.
- **Uncached input:** Droid 3.4k vs Niffler 7.0k — despite the 20× bigger
  prefix, Droid *sends less fresh text*, because its prefix is cached and it
  makes fewer calls. This is the number that quantifies our prefix advantage
  and, at the same time, shows what six sequential round trips cost us.
- **Total tokens:** Niffler 40.7k vs Droid 71.4k — Droid re-reads its big
  cached prefix on each call (65.6k cache reads of 71.4k total).
- **Cost:** $0.416 vs $0.500 per run — a 20% gap, *not* the 1.75× the total
  token column suggests, because cache reads bill at $0.16/M against
  $0.80/M for uncached input.
- **Wall clock:** 29 s vs 30 s — a wash, and both behind pi's 24 s.

So on this suite, **the small frozen prefix and the tool batching cancel out
almost exactly.** The prefix discipline is what keeps a 6.5-round-trip loop
competitive with a 1.9-round-trip one.

## Where the differences actually are

**Droid reads, Niffler shells.** Per cell: Droid `read` 4.6 + `bash` 1.5 +
`edit` 1.1; Niffler `bash` 4.2 + `read` 2.0; pi `bash` 3.2 + `read` 0.7. Our
models reach for `bash` for exploration roughly three times as often as Droid's
model does, and every one of those is a shell round trip whose output is not
bounded by a read budget. Droid's `Grep`/`Glob` were barely used (0.1 each),
so this is not "Droid has better search tools" — it is "Droid's model reads
files, ours explores with the shell".

**Batching works in both, ours is smaller.** Read from the raw streams, not
from the turn counters: Droid's t06 round opens with **five** `tool_call`
frames after one assistant message (11 tool calls in 3 messages); Niffler's
t06 transcript batches **pairs** (`bash,bash` → `bash,bash` → `write,write`
→ `bash` → `bash`). Parallel dispatch is not the gap — `x-harness.parallel` is
already set on `read`/`grep` and the shape telemetry records 1.4 multi-call
messages per cell (max 5 calls in one message). The gap is batch *size*, and
it is a prompt/description lever, not a core change.

**Our model ignores two instructions it is given.** The base prompt says both
"Batch independent calls in one reply" and "Use bash for execution/computation,
not `cat`/`sed` file I/O" — yet across the 31 Niffler cells the bash heads are
`pwd` 26, `cd` 20, `cat` 19, `ls` 6, `find` 3 (against `read` 2.0/cell and
`grep` 0.1/cell). So ~2.4 of our 4.2 bash calls per cell are file navigation
and reading that the direct tools should have absorbed, and roughly 1.5 calls
per cell are spent establishing where we already are. Droid, with the same
kind of instruction, reads (`read` 4.6/cell) and shells out only to run tests
(`bash` 1.5/cell).

That is the cheapest thing this run found: the tools and the words both
exist, and the model routes around them.

**Cheap follow-ups, in order.** (1) Make the read-vs-shell preference
impossible to miss — the word "not" in a 12-word sentence is not carrying it;
consider moving it beside the tool description and naming `cat`/`ls`/`pwd`
explicitly. (2) Ask for larger batches with a concrete shape ("if you need
three files, ask for three in one message"). (3) Check why `pwd` feels
necessary: if the workspace line in the prompt is ambiguous about whether the
repo *is* the cwd, fixing that removes ~1.5 calls per cell for free.

**No pass-rate signal to chase.** Every lane cleared every task in round 1 or
2 (`rounds: 1` on all 93 cells). If we want Droid to be a useful measuring
stick, the next comparison has to move to a suite with headroom — the
mid-tier is saturated too, so `deepswe/` or the SWE-bench slice is where a
Droid lane would say something.

## Notes for whoever re-runs this

- Droid's BYOK path needs the model in a **`--settings` file**, not in
  `~/.factory/settings.json`: a model merged from the home settings is not
  picked up before the folder is trusted, and Droid then silently falls back
  to `gpt-6-sol`, which demands a Factory login. The adapter's header comment
  records this.
- Usage comes from the final `completion` frame (`input_tokens` exclusive of
  `cache_read_input_tokens`, `thinking_tokens`), verified against a controlled
  2-call round; `firstPromptTokens` is the first usage-bearing frame.
- The run was interrupted once (desktop session ended) and resumed with
  `--resume`; the 93 cells above are all from completed cells, and the
  interrupted cells were re-run from scratch.
