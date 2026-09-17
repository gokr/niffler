# CodeWhale's TUI — prior-art analysis for Niffler

Companion to [CODEWHALE.md](CODEWHALE.md), which covers CodeWhale's *core/runtime*
ideas (prompt-cache prefix, memory, sandbox, permission types, subagent postures,
runtime API). This note covers the surface the earlier sweep never looked at: the
terminal UI. It is written for whoever next touches Niffler's client — today the
`tui` plugin (`~/git/niffler-tui`, Go/bubbletea) — and its `agent`/`approval`/
`store`/`llm` peers on the bus.

**Provenance.** Swept 2026-09-17 at CodeWhale `06b44cca5` by two subagent runs (one
on presentation/interaction, one on state/control), each writing a raw fact sheet
into `var/codewhale-tui/` (disposable; this file is the durable copy). The
citations below were spot-checked by hand against the tree — e.g.
`tui/persistence_actor.rs:57` really is the compound `CompletedCommit` with the
ordering hazard in its comment, `tui/active_cell.rs:12-20` really is the "at most
one mutable in-flight cell, rendered after history" contract, and
`agent_roster.rs:22-26` really renders an empty roster as prose, not `0`. Where the
sweep could not verify something, the item says so.

## 1. What it is

Rust, `ratatui` + `crossterm`. The `crates/tui` crate is 853 `.rs` files / ~981k
lines (much of it tests); `src/tui/` alone is ~269k lines, and the crate also
embeds a runtime engine, so "the TUI" there includes the client half of an
agent harness. It ships a golden-buffer snapshot corpus (`src/tui/goldens/*.txt`,
120×32 down to 40×3) and a layout harness, so its chrome is regression-tested
pixel-wise.

The most portable thing in the crate is not a feature but a document:
`crates/tui/AGENTS.md` states the UI's invariants as contracts. From it:

- **One owner per fact.** Mode, permission and live counts live in the posture bar
  (`phase_strip.rs`); model/context/cost/ttft/tok-s in the metrics line
  (`infoline.rs`); the roster and to-do in the work surface; receipts in the
  transcript. A fact with two owners is a bug waiting to disagree with itself.
- **Status ink goes through a palette grammar** (`codewhale_palette::grammar`,
  `docs/design/STATUS_BAR_COLOR_GRAMMAR.md`): "do not invent an eighth semantic or
  spend Failure red on non-failure chrome".
- **Renderers must not infer state from prose.** Derive from typed enums
  (`ShellPhase`, `OceanTreatment`); never parse English strings for lifecycle state.
- **Keep settled output still.** Motion is semantic, bounded, and fully disabled by
  reduced-motion settings.
- **Notices are typed** (level + lifetime) through one toast system; no new writes
  to the legacy `status_message` sink.
- **Compact layouts remove chrome before content.** Selectable rows need recorded
  hitboxes, visible focus, keyboard/mouse parity, and confirmation for destructive
  actions.
- **Prose is localized by message id** (`tr(locale, MessageId::…)`); keys, glyphs
  and commands are composed in code.
- **Evidence:** "Direct PTY or terminal behavior is stronger evidence for visible UX
  than an assertion over render internals."

Niffler's worth from these is immediate: today's worker-badge bug (a count computed
from a lazily refreshed snapshot, no owner) and the README's `Ctrl+G`-for-shift+tab
drift are both *exactly* the failures these contracts forbid.

## 2. Tier 1 — truthful live surfaces

The theme running through the best items in both sweeps: **a live surface must be
derived from one typed source, and must never claim more than it knows.** This is the
class of bug we hit and fixed by hand today (`agents.go`: badge count from a stale
roster; age from the newest child; a `count` that read `0` when unknown).

- **Absence is not zero, and "parked" outranks the raw status.**
  `agent_roster.rs:7,39,79,155,180`: every number is an `Option` that renders `—`,
  never `0`; an empty roster renders as prose ("No agents have run in this session
  yet…"); and a child the parent abandoned gets a `Parked` state that outranks its raw
  status. *Why it matters:* "this worker used 96,300 tokens" and "no usage receipt
  exists" are different facts, and a UI that prints `0` for the second is lying.
  *Niffler:* `~/git/niffler-tui/tui/agents.go` + the `agent` component's status
  contract (make `lastStatus`/`error`/`startedAt` presence explicit), `context_status.go`
  (unknown context ≠ 0). **small.**
- **Dismissal is a watermark, not a boolean.** `work_surface/interaction.rs:23,30`,
  `model.rs:338,360`: closing a panel records the row count it had, so it reopens only
  when that view *grows*. *Niffler:* our roster/notice strip could adopt this instead of
  "seen" flags. **small.**
- **Live vs settled projection.** `background_indicator.rs:13,41,92,121`: pending work
  is a *derived union* of sources (no new registry, no lock in the render path); settled
  work leaves the live projection but never the record, via TTL + cap. *Niffler:* the
  same shape our `agent_list` roster + child-activity map now has, but with the TTL/cap
  discipline written down. **small.**
- **"Nothing seems to be happening" becomes named, self-erasing affordances.**
  `hot_tail.rs:1,24`: the newest ~12 graphemes render brighter on a slow breathing
  cadence (grapheme-safe), plus named chips for "waiting on approval" / "blocked on
  background work" that disappear when the cause does. *Why it matters:* each answers a
  specific anxiety — is it writing? why is it silent? — instead of a generic spinner.
  *Niffler:* our busy label already names the running tool; the missing half is the
  *derived* blocked-on-what chip, which needs one typed source per blocker. **small.**

## 3. Tier 1 — chrome, keys and help as one system

- **Help that cannot drift.** `footer_hints.rs:1,17,35`: hints are leased chrome —
  each renders until the user has *actually pressed* it (`USES_TO_RETIRE`), and the
  key text comes from the binding table, never a literal. `shell_key_routing` is the
  single authority for key hints in handlers, footer and `/help`. *Why it matters:* the
  hint is generated from the same source as the behaviour, so prose cannot rot — the
  failure we shipped in `README.md` (Ctrl+G vs shift+tab) becomes unrepresentable.
  *Niffler:* `controls.go`/`main.go` key switches + `i18n.go` help line + `README.md`.
  **small.**
- **Chrome that stands down.** The same item: onboarding/status chrome is consumable,
  and retirement is driven by observed use, not by a timer. *Niffler:* the TUI's
  transient notes (`note.*`) and header chips. **small.**
- **Semantic, non-colour status vocabulary with one owner for the selection look.**
  `menu_style.rs:1-13,25,38`: menus/pickers select through a handful of documented
  style functions so selection-vs-cursor and colour-vs-ink are invariants, not
  per-widget choices. *Niffler:* `theme.go` + `selectors.go` (each selector styles
  itself today). **small/medium.**

## 4. Tier 1 — layout degradation as declared tiers

- **Width degradation is an enum, ordered widest-to-narrowest.**
  `work_surface/render/rows.rs:17-27,40-43` (`AgentRowTier`): how much of a row survives
  at a given width is a named value with a documented priority, so tests and docs can
  cite it. *Niffler:* `toolcard.go`, `agents.go`, `context_status.go` clip ad hoc.
  **small/medium.**
- **Windowing is accounted in *rendered rows*, not entries.** `command_palette.rs:623`
  counts everything the entry loop paints (entries + section labels + separator blanks).
  *Why it matters:* the original bug was diagnostic gold — an uncounted chrome row made
  the list look scrollable when it was not. *Niffler:* `selectors.go`, `slash.go`,
  `filecomp.go` popups. **small.**
- **Compaction sheds qualifiers, never truncates names.** *Niffler:* the status row and
  header (`context_status.go`, `main.go` bottom row). **small.**

## 5. Tier 2 — gates and receipts

- **Approval: decision risk and presentation stakes are different types.**
  `approval/policy.rs:42,61,153`: `RiskLevel` (Benign/Destructive) drives the keymap and
  stays conservative; a second axis governs how the prompt is *presented* and routed.
  *Why it matters:* one enum serving decision, colour and routing is what produces
  "approve everything because the prompt is unreadable". *Niffler:* the `approval`
  component + `approvals.go` (today a y/N modal). **medium.**
- **A silent verdict still leaves a transcript line — except a proven-safe allow.**
  `gate_receipts.rs:1,10,44`: when a gate resolves without a human (policy/model
  guardian), it writes a receipt; only a *proven-safe* allow stays silent. *Why it
  matters:* in an auto-approving posture the interesting event is the one that happened
  without you. *Niffler:* `NIF_AUTO_APPROVE=1` is our only story here; the `observe`
  component is the natural home. **medium.**
- **Cancellation receipts name what was *not* cancelled.** `subagent_routing.rs:40,48,50`:
  `parent_stop_status` reports work that outlived the stopped turn. *Niffler:* `bash`
  process-group kills + `agent_stop`; the TUI could state "stopped the turn; 2 children
  still running". **small/medium.**
- **File mutations produce a structured, success-only receipt with two audiences.**
  `history/file_mutation.rs:54,42,279`: `from_success` returns `None` unless the tool
  actually succeeded — "a diff shown on a failed call is worse than no diff".
  *Niffler:* `edit`'s before/after + undo. **medium.**
- **Restore is typed and gate-specific; the refusal keeps its own remedy.**
  `snapshot/repo.rs:54,79,125`, `snapshot/mod.rs:38`: per-turn snapshots in a side git
  repo with `--git-dir`/`--work-tree` always set, and a refused restore reports the
  specific gate that refused plus how to satisfy it. *Niffler:* our `/restart` handoff
  and the ui-registry refusal note we just fixed — the "refusal carries its remedy"
  half is the missing piece. **small.**

## 6. Tier 2 — cost and context truth

- **A context inspector that shows *why* the prompt costs what it costs.**
  `context_inspector.rs:45`: the live system prompt is decomposed into named layers
  (`SYSTEM_LAYER_MARKERS` → `PromptLayerKind::{Static, Dynamic}`) with per-layer token
  estimates. *Why it matters:* it makes prompt-cache discipline *visible* — you can see
  which layer is static (cacheable) and which is being re-derived per turn. *Niffler:*
  `context_status.go` is a bar/percent today, and this conversation is the proof of
  value: 98.5% DeepSeek cache hits are a fact nobody can currently inspect per layer.
  **medium.**
- **Context accounting is pure arithmetic with a named pressure level, and compaction
  leaves a receipt.** `context_budget.rs:46,77,140,184`: one module derives the numbers
  everything else reasons with (spendable, reserve, pressure), instead of re-deriving
  "how full is it" in three places. *Niffler:* `core/session.nim` trim/compaction +
  `ev.session.context`; we already emit reset reasons, so this is mostly a *consolidation*
  argument. **medium.**
- **Background spend and the counters that qualify it drain as one fact, exactly once.**
  `cost_status.rs:51,58,64` + `subagent_routing.rs:489,499,519`: LLM calls outside the
  main turn report into a side channel, and usage arriving by two routes (sync sink +
  bus) is deduplicated by identity. *Niffler:* `llm`/`provider` usage → core accounting.
  **medium.**
- **Session metrics omit rather than estimate, with a documented shed order.**
  *Niffler:* the bottom row's cache/ctx figures — worth writing down which number
  disappears first at narrow widths and never fabricating a rate. **small.**

## 7. Tier 2 — rendering, input and evidence

- **Revision-keyed render caches owned by the wrapping surface.**
  `transcript_cache.rs:3-14`: wrapped output is cached under `(cell, width, revision)`
  with an explicit revision counter bumped per mutation, so invalidation is a fact, not
  a heuristic. *Niffler:* `transcript.go`/`toolrender.go` have `pieceEpoch`/`renderFrom`
  (coarser, whole-window invalidation). **medium.**
- **One motion contract animated surfaces must ask, plus a coalescing frame requester.**
  `motion/mod.rs:1,9-14` (`MotionMode::{Full,Reduced,Still}` with per-surface
  semantics) + `motion/frame_requester.rs:1-5`. *Why it matters:* reduced motion is
  specified as *different rendering semantics*, not a speed knob. *Niffler:* we have
  viewport flush coalescing; we have no reduced-motion setting. **medium.**
- **The reader's contract: sticky tail, copy fidelity, out-of-band links.**
  `live_transcript.rs:6,51`: auto-follow is an explicit reversible flag (at bottom,
  every refresh re-pins; off-bottom, it yields), the rendered and copyable forms are kept
  distinct, and links are metadata rather than cell content. *Niffler:*
  `scrollback_test.go`/viewport work; OSC 8 links in `transcript.go` markdown paths are
  a small nicety. **small/medium.**
- **A bounded fuzzy index with relevance boosts and a query-targeted repair path.**
  `file_picker.rs:47,51`: one walk honouring `.gitignore`, capped at 20k paths, and the
  loss is *repaired on demand* by querying deeper. *Niffler:* `filecomp.go` filters with
  no index and no boosting. **medium.**
- **`@`-mentions as typed context attachments with budgets and an explicit unavailable
  state.** `git_mention.rs:2-16,24,28`: `@git`/`@diff` resolve to bounded payloads (32
  KiB / 8 KiB) that say when they are truncated or unavailable. *Niffler:* `filecomp.go`
  + `slash.go` do path completion only; a *typed attachment* with a budget is the
  upgrade that keeps the composer honest. **medium.**
- **Terminal capability ladder: glyph charter, colour downsampling, one probe per
  capability.** `glyphs.rs:1-8,44` + `color_compat.rs:26`: renderers name a semantic
  mark; one module maps it to a character (with an ASCII fallback) and to the colour
  depth the terminal actually has. *Niffler:* `theme.go` (lipgloss degrades colour
  silently; no glyph charter, no ASCII mode). **small/medium.**
- **Pending-input preview: queued and rejected input is visible and editable.**
  *Niffler:* steer exists on the bus; the client shows nothing queued. **small/medium.**
- **Golden-buffer snapshot harness with a bless protocol.**
  `src/tui/goldens/*.txt` at sizes down to 40×3 + a bless workflow. *Niffler:* we have
  `viewport_probe_test.go` and `toolcard_layout_test.go`; borrowing the *practice* for
  the transcript + tool cards (not every widget) would catch the layout regressions we
  currently catch by eye. **medium.**

## 8. Parity — we already have it

From the same sweeps, with the CodeWhale ref for contrast: bracketed-paste handling
(`paste.rs`) — ours exists, the burst heuristic does not; OSC 52 clipboard
(`clipboard/`) — ours exists; rich clipboard conversions (image→file, HTML→markdown)
— we do not; hitbox-recorded selectable rows (`mouse_ui/`) — we test clicks, but
positions are computed, not recorded; tool-card previews with an honest omission
counter (`widgets/tool_card.rs`, `diff_render.rs:38,49`) — our cards already say
`… (N earlier lines, ctrl+e to expand)`; per-conversation model+effort — ours;
localized prose by message id — ours (`i18n.go`, 3 locales); a typed run inside the
transcript — ours; one mutable in-flight cell (`active_cell.rs`) — conceptually ours
(streaming block reuse); frame coalescing — ours (`viewportFlushInterval`).

## 9. Deliberate non-borrows

- **Ambience** (`ocean/`, `whales.rs`, `tideline.rs`, `underwater.rs`,
  `ambient_life/`, `focus_texture.rs`, `cursor_accent.rs`): delightful, and it is the
  reason their AGENTS.md needs a motion contract. Niffler's client is a tool; revisit
  only if we adopt the motion contract first.
- **Audio notifications** (`notification_audio.rs`, `sound_policy.rs`) — same reason,
  plus it does not travel over SSH.
- **Fleet/cloud/computer-use surfaces** (`views/fleet_*`, `cloud_dispatch.rs`,
  `computer_meter/`): no Niffler counterpart, and CODEWHALE.md already covers the
  cloud-dispatch *pattern*.
- **Goldens for every widget**: too much corpus for our change rate; borrow the
  practice narrowly (transcript + tool cards).
- **Their embedded runtime engine** (`crates/tui/src/core/engine/`): Niffler's split is
  NATS processes by design; the interesting part is the *contract* (§1), not the
  co-location.
- **The control socket** (`control_socket.rs:187,131`): the design rule ("a verb is a
  seam into an existing path, never a second implementation") is worth keeping; the
  *mechanism* is unnecessary — our bus is already the seam.
- **`vim_mode.rs`**: nice, niche; only if a user asks.

## 10. Order I would actually work

1. **Truthful live surfaces** (§2): `Option`→`—`, empty-as-prose, settled TTL/cap,
   blocked-on-what chips. Small, and it closes the bug class we hit today by hand.
2. **Key/help single authority + retiring hints** (§3): kills doc drift permanently and
   is a prerequisite for any keymap growth.
3. **Layout degradation tiers + rows-not-entries windowing + absent-never-zero** (§4):
   small, visibly calmer at narrow widths.
4. **Gate receipts + approval axes** (§5): our y/N modal is the weakest surface left;
   needs `approval` + `observe` changes but no protocol break.
5. **Context inspector** (§6): the highest-value *new* surface, and the natural
   companion to the prompt-cache discipline CODEWHALE.md made us enforce.

## 11. Open questions / not swept

Both sweeps reported gaps: `runtime_threads.rs` (13k lines), `ui/event_loop`,
`session_manager`, most of `views/`, `hotbar/`, `history/latex_render.rs`, `tideline.rs`
internals, context-menu internals; whether the ink-plane colour goldens exist (a comment
only); whether the latest-wins persistence coalescing can drop a *distinct* session's
write under contention; and whether `dismissed_at_rows` is recomputed when rows are
re-placed. Niffler-side, the cache-win magnitudes of §7's render work are unprofiled —
any adoption should start by measuring our own repaint cost the way
`viewport_scroll_perf_test.go` already does.
