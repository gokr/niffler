# UI — web SPA over NATS

## Principle: the UI is a NATS client, not a Wails client

The SPA talks to one tiny interface (`send`, `subscribe`) implemented by a Go
bridge inside the Wails app. All state, tool calls, approvals and events ride
the bus. Wails is a *hosting choice*, not architecture: the same SPA runs in a
plain browser against a WebSocket/SSE proxy later with zero SPA changes
(swap `nats.ts`).

The bridge is also a bus citizen — a component like any other:

```
svc.ui.call   # tools: confirm (approval prompts), notify (toasts)
ev.session.*  # session list/state for the sidebar
ev.catalog.*  # tool list changes → rebuild the tools panel
```

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
