# Worklist slice: component: console

From `worklist.tsv` (6 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A579 (doc-edit)
source: `components/console.md`

- MANUAL: MANUAL: "Or better: **the console component** (`./var/bin/console`, not in the manifest — start it yourself in a second terminal) subscribes to everything and renders the wire traffic readably: calls with tool + args, results, errors, events, approvals — it is how you follow a live install or a stuck-tool call:"
- CODE: components/console/main.nim:35-56 (render), :64-100 (subscribe `>` + loop)
- FIX: update to "…renders the wire traffic readably: calls with subject + tool + args, results, errors, events, approvals. Two limits are worth knowing: a `reg.publish`/`reg.depart` payload prints as a bare `event <subject>` line (use `observe_subjects`/`catalog` to see which component came up), and every SDK result prints with an empty tool name — correlate by the call above it." [doc-edit]

## A580 (doc-edit)
source: `components/console.md`

- MANUAL: MANUAL: "subscribes to everything and renders the wire traffic readably: calls with tool + args, results, errors, events, approvals — it is how you follow a live install or a stuck-tool call:"
- CODE: components/console/main.nim:48-56 (event payload only; top-level registration fields dropped)
- FIX: add "Registration and departure payloads are the one thing it cannot show in detail: `reg.publish` is a bare JSON object (not an envelope), so console prints its subject with an empty body — `observe` keeps the payload intact if you need it." [doc-edit]

## A582 (code-bug?)
source: `components/console.md`

- MANUAL: MANUAL: "subscribes to everything and renders the wire traffic readably: calls with tool + args, results, errors, events, approvals — it is how you follow a live install or a stuck-tool call:"
- CODE: components/console/main.nim:48-56 (events render `env.payload` only), sdk/niffler/sdk.nim:530-535 (a `reg.publish` payload has no `payload` key)
- FIX: code bug — for a non-envelope message (a bare registration/departure payload) render the decoded top-level object (e.g. `event reg.publish  {name: "bash", pid: 1234}`) instead of an empty body; without this, the arrival of every component is a blank line [code-bug?]

## A583 (code-bug?)
source: `components/console.md`

- MANUAL: MANUAL: absent
- CODE: components/console/main.nim:42-44 (prints `env.tool`, empty for SDK replies), sdk/niffler/sdk.nim:725 + sdk/envelope.nim:72-73 (replies carry no `tool`)
- FIX: code bug — make results identifiable on a busy bus: echo the envelope `id`, or keep an id→tool map from the calls already rendered, so a `result   → {…}` line can be attributed [code-bug?]

## A584 (doc-edit)
source: `components/console.md`

- MANUAL: MANUAL: absent
- CODE: components/console/main.nim:64-68 and :93-99 (natsnim reconnect budget ~4 min before giving up; then the outer loop re-reads the discovery file every 2 s)
- FIX: add "When the bus dies, console goes quiet for the client's reconnect budget (tens of seconds to ~4 minutes), then prints `bus connection lost — reconnecting…` and retries every 2 s, re-reading `var/nats-url` each time — a harness that restarts on a new random port is picked up automatically." [doc-edit]

## A588 (doc-edit)
source: `components/console.md`

- MANUAL: MANUAL: "It preserves the original JSON node, including unknown envelope fields and bare registration payloads."
- CODE: components/observe/main.nim (raw `>` ring) vs components/console/main.nim:48-56 (payload-only render, non-envelope messages show an empty body)
- FIX: add "(the sibling `console` does not: it renders envelopes only, so a bare `reg.publish` shows as `event reg.publish` with no body — see [The bus in one screen](#the-bus-in-one-screen))" [doc-edit]

