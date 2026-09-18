# UI — web SPA over NATS

## Principle: the UI is a NATS client, not a Wails client

The SPA talks to one tiny interface (`send`, `subscribe`) implemented by a Go
bridge inside the Wails app. All state, tool calls, approvals and events ride
the bus. Wails is a *hosting choice*, not architecture: the same SPA runs in a
plain browser against a WebSocket/SSE proxy later with zero SPA changes
(swap `nats.ts`).

The bridge is also a bus citizen — a component like any other:

```
svc.ui.call        # (reserved for future tools; none yet)
ev.session.*       # session list/state for the sidebar
ev.catalog.*       # tool list changes → rebuild the tools panel
ev.approval.*      # approval gate (see below)
```

**Approvals need no bespoke bridge tool.** Core publishes a directed request
on `svc.approval.<caller>.request` (falling back to the broadcast
`ev.approval.request` after ~1.5s); the bridge's `On(">")` forwards every
event to the SPA, which shows the modal (App.svelte) and answers via
`emit("ev.approval.reply", {id, ok})`. The transport stays the bus.

## UI lease registry (numbered clients, conversation ownership)

The web UI participates in core's UI registry (`core/uireg.nim`) alongside
the TUIs, so mixed TUI/web setups coordinate instead of silently sharing a
conversation.

**Identity granularity: one identity per browser tab.** The bridge mints it
(`Bridge.NewUiId()` → `"ui-<12 hex>"`); the SPA persists it in
`sessionStorage` so a reload keeps the assigned display number. Registry ops
(register / renew / release / claim / release_session / owner) are proxied to
core's hidden `ui` tool — the SPA's `lib/uiRegistry.ts` owns the rules, the
bridge only mints and forwards. The same string is stamped as the `caller` of
the tab's session turns (`Bridge.SendAs`), so core's directed approvals
(`svc.approval.ui-<hex>.request`) reach only the tab that drives the turn —
the per-client privacy the TUI gets from its unique component name.

- The header shows the registry's monotonic display number as **"Niffler
  N"** (TUI convention).
- Opening a conversation claims it; a live UI already holding it is reported
  by number and the SPA offers a fresh conversation instead of joining.
- A ~20s lease (re-registered every 5s) is the liveness signal. A lease lost
  while the tab was frozen/suspended re-registers (fresh number) and
  re-claims; if the claim was lost meanwhile, the tab moves to a fresh
  conversation with a note. `beforeunload` releases best-effort; expiry
  covers a crashed tab.
- Coordination only, not authentication: NATS caller names are self-declared
  (docs/WIRE.md). Non-participating clients (CLI, scripts) keep legacy
  behavior and can still open a claimed conversation.
- Workspace parity is withheld until the SPA exposes workspace selection: the
  TUI keys its resume state by bus URL + launch directory, and the web UI has
  no per-tab resume state to key yet.

## Two kinds of dynamism

### 1. Data-driven (milestone 1 — do this first)

Tool schemas carry `x-ui` render hints; the SPA renders any tool from
schema + result JSON:

```json
{"name": "weather", "schema": {...},
 "x-ui": {"view": "table", "summary": ["city", "temp"]}}
```

Generic renderers cover the long tail: chat, tool-call card, JSON tree,
markdown, table, image, stream. A new tool gets a usable UI automatically —
no code, matching the schema-as-runtime-data discipline of the bus.

### 2. Code-driven (later, opt-in)

A component ships a *UI module* — plain JS, or a Svelte component compiled
to a single JS file by the same `builder` component that compiles binaries.
Builder registers it in the catalog:

```json
{"name": "weather", "kind": "ui-module", "version": 3,
 "path": "store://ui/weather.js", "hints": ["weather-card"]}
```

Bridge syncs `var/ui/` from the store on `ev.catalog.updated` and serves
module source to the SPA via a binding:

```
uiModule("weather") -> "export default {...}"     // blob URL + dynamic import()
```

The module registers a renderer for its `x-ui` hint; the next tool call with
that hint renders with it. **No separate HTTP server needed** — the Go bridge
*is* the module server; the embedded SPA stays embedded and offline-capable.

### When server mode becomes worth it

Browser access without the Wails shell, remote use, or multiple clients.
Then a `ui-gateway` component (Go) serves the same `dist/` + `var/ui/` over
HTTP and proxies the bus over WebSocket (dsh does exactly this at
localhost:3080). SPA unchanged — only `nats.ts` changes transport. This is a
later component, never core.

## Trust

| Author | Runs as | Isolation |
|---|---|---|
| Tool component | OS process | strong (exit = disposer) |
| UI module | JS in the UI process | weak — same privilege as the SPA |

Gate: catalog registration (only catalog-listed, versioned modules are
served; served read-only from `var/ui/`). If untrusted module authors ever
appear: render modules in sandboxed iframes before anything else.

## Layout (flatout/builder setup: Wails v2 + Svelte 5 + Vite)

```
ui/
├── main.go            # wails.Run, embedded dist
├── bridge.go          # bindings: send, subscribe, uiModule; NATS client
├── frontend/
│   ├── src/
│   │   ├── nats.ts    # THE interface: send/subscribe — only file aware of transport
│   │   ├── App.svelte
│   │   ├── views/     # generic renderers (chat, toolcard, json, md, table, image)
│   │   └── registry.ts# x-ui hint -> renderer; dynamic modules register here
│   └── (vite + wailsjs as in flatout/builder)
└── wails.json
```

## Gotchas

- **Build only with `wails build`**, never `go build ./...` or
  `go build -o build/bin/niffler-ui .` — a plain `go build` produces a stub
  that prints "Wails applications will not build without the correct build
  tags" (no bindings/tags are compiled in). `go vet ./...` is fine; just never
  let `go build` overwrite `build/bin/niffler-ui`.
- **The binding namespace is the struct name.** `wails build` generates
  `frontend/wailsjs/go/main/<StructName>.js` and injects `window.go.main.<StructName>`
  — named after the bound Go struct (`Bridge`), not the variable you pass to
  `Bind: []interface{}{ app }`. `nats.ts` imports from
  `../wailsjs/go/main/Bridge` and checks `window.go.main.Bridge`. If `wails
  generate`/`build` later regenerates to a different name, update `nats.ts` to
  match (mismatch = the "Running in a browser" banner inside the desktop app).
