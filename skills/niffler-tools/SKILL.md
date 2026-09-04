---
name: niffler-tools
description: When-to-use guidance for every Niffler core component and tool — which tool fits which job, what stays in bash, and how progressive discovery works. Load when unsure whether a dedicated Niffler tool exists for a task, before hand-rolling an integration in bash, or when choosing between read/read_many/files/grep, edit/write, agent_run/fabric, or the self-extension path. The expert advisory peer embeds this skill verbatim in its knowledge prefix.
---

# Niffler core tools — when to use what

Niffler is a self-extending harness. Many capabilities are NOT in the direct
toolset: they are **on-demand tools** reachable only via `discover` + `invoke`.
The cardinal rule: **before hand-rolling a job in bash, ask whether a Niffler
component already does it** — `discover` (query, or `component` for one
component) lists live components and tools outside the fixed direct set;
`invoke` calls a discovered tool with its documented arguments.

## File tools (direct)

- `read` — single file, pageable (offset/limit). Use for one file.
- `read_many` — up to 8 files in ONE call. Batch related reads; cut tool
  round trips when inspecting several files at once.
- `files` — sorted file listing by path/glob. The listing tool.
- `write` — atomic whole-file write (create or overwrite). Use for new files
  or full rewrites.
- `edit` — surgical change: unique `old_string` → `new_string` per edit,
  `replace_all` for repeated replacements, a guarded fallback cascade when
  the exact string is ambiguous. Use edit for small precise changes, write
  for whole files.
- `undo_last_edit` — approval-gated revert of the last edit mutation.

Never `cat`, `sed -i` or `python -c` file edits in bash when edit/write exist.

## Search

- `grep` — ripgrep-backed content search returning path:line:match,
  .gitignore-aware, no shell quoting needed. ON-DEMAND: discover + invoke.
- `files` lists, `grep` searches contents. Shell `grep -rn` is the
  anti-pattern: slower, respects nothing, floods the transcript.

## Git (read-only, on-demand)

- `git_status`, `git_diff`, `git_log`, `git_show`, `git_blame` — fixed-argv,
  approval-free reads. ON-DEMAND: discover + invoke.
- Mutations (commit, push, checkout…) deliberately stay in `bash`.
- `review_receipt` — fingerprint a diff for a pre-push review handoff.

Shell `git status` / `git diff` when the git component is one discover away
is the classic misuse.

## bash

Still right for: builds and test runs, pipelines, git mutations, and anything
without a dedicated tool. Wrong for: reading/searching files, git inspection,
web fetching, or repeating what a listed tool already does. Oversized output
spills to a file instead of the transcript.

## Web

- `fetch` — HTTP(S) retrieval with HTML→text extraction, size caps and file
  spill for large bodies. ON-DEMAND. Not curl.

## Durable state

- `store` — `put/get/list/del` over the bus. Conversations, plugin records,
  the catalog and component state persist here; use it for your own durable
  state too (never for transient scratch).

## Self-extension (the core loop)

write source → `builder.build` (compiles agent-written Nim/Go/TS into
`var/bin`) → `core.spawn` (runs it; approval-gated) → `discover` → `invoke`.
`core.kill` stops a group temporarily, `core.remove` deletes its record.
ON-DEMAND: builder.*, core.spawn/kill/remove. Building a new integration
before checking the ecosystem is the classic mistake.

## Plugins (on-demand)

- `plugin_search` (topic search) → `plugin_install` (clone, build, spawn
  service components) → `plugin_update` / `plugin_remove`.
- Always search before building an integration by hand.

## Skills (on-demand)

- `skill_list` / `skill_load` — reviewed workflow guides (including this one
  and niffler-fabric). Skills add strategy, not tools.

## Context economy

- `agent_run` — exploratory subtask in a FRESH context (own loop, summary
  returned). DIRECT tool. Give subagents per-job budgets: maxRounds,
  maxCalls, maxTokens.
- `fabric` — one Nim program orchestrates many tool calls; only `finish()`'s
  value enters the conversation. ON-DEMAND. See the niffler-fabric skill for
  program construction.
- Direct loop — right when each result changes the plan.
- Decision rule: one step or plan-changing results → direct loop; mechanical
  known-shape fan-out / big intermediates / edit-then-verify / polling →
  fabric; exploratory with per-step judgment → agent_run; mechanical
  collection plus ONE judgment → a fabric program calling agent_run.
- Oversized outputs spill to files instead of the transcript.

## Core operations (on-demand)

- `catalog` (op list/schemas) — what is registered; `status` — live
  component processes; `doctor` — one-shot health probe; `prompt_preview` —
  a conversation's frozen direct tools and prompt provenance;
  `session_info` — a conversation's summary; `conversation_delete` — remove
  a conversation.

## Observation (on-demand)

- `observe` — bounded live bus ring and explicit capture exports;
  `logfile` — rotating JSONL logs with bounded search. Use when debugging
  the harness itself, not the task.

## Anti-patterns (the steer-worthy list)

- shell `git status`/`git diff`/`grep -rn` when the dedicated tools are one
  discover away
- building an integration before `plugin_search`
- `cat`/`sed` file edits; `curl` for web pages
- bulk exploration in the main transcript instead of agent_run/fabric
- re-running work a listed tool already did
