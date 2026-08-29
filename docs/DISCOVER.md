# Progressive tool discovery

Status: **implemented**.

Niffler keeps one complete global catalog while exposing a small, immutable
toolset to each conversation. Additional schemas enter the append-only message
history through `discover`; calls to those tools go through the fixed `invoke`
gateway. This reduces prompt bloat without weakening core approval or timeout
policy.

## Model

### Existence is global; exposure is per conversation

A component exists when it is live on the bus. `reg.publish` inserts all its
tools into core's catalog; `reg.depart` or supervisor cleanup removes them. A
binary under `var/bin` is inert until manifest autostart, `core.spawn`, or a
plugin install starts it.

Exposure is a separate concern:

| Level | Schema metadata | Direct LLM schema | Discovery | Invocation |
|---|---|---|---|---|
| direct | `x-harness.onDemand` absent | included in a new session snapshot | hint + schema lookup | direct or `invoke` |
| on demand | `x-harness.onDemand: true` | omitted | hint + schema lookup | `invoke` |
| hidden | `x-harness.hidden: true` | omitted | omitted, including explicit lookup | components/core only |

Hidden takes precedence if both flags are present. Exposure is not an ACL:
the complete catalog remains authoritative for routing. The LLM-facing
`invoke` gateway refuses hidden targets, while components can still request
hidden tools directly over NATS.

### Full catalog and projections

- `catalog {op: "snapshot"}` returns complete component registrations and
  schemas. Session runners seed their local catalogs from it.
- `catalog {op: "components"}` returns the complete component-to-tool-name
  map used by the CLI.
- `catalog {op: "list"}` returns the current name-sorted direct projection for
  a *new* conversation. It is not the toolset of an existing session.
- Dispatch, approvals, `x-harness.timeoutMs`, and component-to-component calls
  always consult the full catalog.

## Core tools

`discover` and `invoke` are direct core tools in every new conversation.

### Hints

```json
{"query": "web"}
```

`query` is optional and matches component names, tool names, and descriptions
case-insensitively. The result is deterministic: components and tools are
name-sorted, descriptions are whitespace-normalized one-line hints capped at
200 characters, and volatile fields such as pid and registration time are
excluded.

```json
{
  "components": [
    {
      "name": "fetch",
      "version": "0.1.0",
      "direct": [],
      "onDemand": [
        {"name": "fetch", "description": "Fetch a web page or API endpoint..."}
      ]
    }
  ],
  "count": 1
}
```

`discover {component: "fetch"}` returns that component's direct and on-demand
hints. Components with no non-hidden tools are omitted.

### Schemas

Request only the tools needed for the next step, up to 16 at a time:

```json
{"component": "fetch", "tools": ["fetch"]}
```

The result contains normalized full schemas, sorted by tool name:

```json
{
  "component": "fetch",
  "tools": [
    {"name": "fetch", "schema": {"type": "object", "properties": {}}}
  ]
}
```

Unknown and hidden tool requests have the same error shape so discovery is not
a hidden-tool existence oracle.

### Invocation

Call a discovered schema through the fixed gateway:

```json
{
  "tool": "fetch",
  "arguments": {"url": "https://example.com"}
}
```

`invoke` recursively enters the normal `dispatchToolCall` path. The target
tool's approval dialog, timeout, component routing, and errors therefore behave
exactly like a direct call. It can also reach a newly registered non-hidden
tool that was not present when the conversation started.

## Session state and caching

Provider prompt caches include top-level tool definitions. Adding a discovered
concrete schema to a later `tools` array would change the prefix and invalidate
the accumulated cache. Returning a schema only as a tool result is append-only,
but the model still needs a declared function through which to call it; that is
why `invoke` is fixed and generic.

On the first turn, a session runner:

1. computes `Catalog.promptTools()`;
2. stores the exact ordered schemas under store kind `session`, id
   `<sessionId>:tools`;
3. uses that snapshot for every LLM round and after runner restart.

The document shape is:

```json
{
  "version": 1,
  "direct": [
    {"component": "bash", "name": "bash", "schema": {}}
  ],
  "discovered": [
    {"component": "fetch", "name": "fetch"}
  ],
  "initializedAt": 0,
  "updatedAt": 0
}
```

`direct` carries schemas because it is the resume-safe provider snapshot.
`discovered` is a durable summary for inspection and UI state; the schemas
themselves live in persisted tool-result messages. Only a successful
full-schema `discover` call updates it. Hint searches and failed lookups do not.

Component registration churn never changes an existing conversation's direct
array. A late component is found through `discover` and called through
`invoke`. If a direct component departs, its frozen schema remains in that
conversation for cache stability; a call fails through normal routing and
current discovery reflects that it is gone.

## Shipped policy

With the complete shipped manifest, 13 tools are direct:

- Core: `discover`, `invoke`.
- Routine work: `bash`, store `get`/`list`, `grep`/`files`, `write`, and
  The file tools are direct: `read`/`edit`/`write`/`undo_last_edit` (the
`edit` component). Anchored block moves (the niffler-hashline plugin)
register their `replace`/`undo_last_replace` as onDemand: run
`discover`/`invoke` against them once installed.
- Skill entry points: `skill_list`, `skill_load`.

The long tail is on demand:

- Core lifecycle/status/catalog, builder, plugins, and fetch.
- Models and provider administration.
- Observe and logfile diagnostics.
- Skill resources, online search, install, and remove.

Internal tools remain hidden: core `session`, store `put`/`del`, LLM `chat`,
and credential-bearing `provider_active`.

Absent `onDemand` metadata remains direct for third-party compatibility. A
component spawned after a session starts still does not mutate that session's
frozen direct array; discover/invoke is the handshake for the new capability.

## UI

The Live Components panel joins global `core.status` data with the active
session's exposure document. Tool chips use text plus color:

- `direct`: in the immutable provider tool array;
- `seen`: its schema was successfully discovered in this conversation;
- `demand`: live and non-hidden, but not exposed in this conversation;
- `internal`: hidden from the LLM.

Component liveness remains a separate status dot. The panel reloads on session
selection, catalog changes, discovery/done events, reconnect, and periodic
polling. Deleting a conversation also deletes its exposure document.

## Verification

`tests/t_discover.nim` is the end-to-end contract. It proves deterministic
projection and discovery, full-catalog retention, hidden non-disclosure,
approval and timeout preservation through invoke, the actual session-runner LLM
payload, immutable behavior across late registrations, schema persistence in
message history, and durable UI exposure metadata.

Run it alone with `make test-discover`; it is also part of `make test`.
