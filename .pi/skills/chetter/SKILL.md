---
name: chetter
description: Operate the Chetter runner fleet through its MCP server — fleet/task status, submitting, cancelling, rerunning and recovering tasks, triggers, event callbacks, agent sessions, model catalog, definitions and proposals, git identities, usage and audit. Use when the user asks about Chetter runners, tasks, triggers, sessions, usage, or wants a self-test run.
---

# Chetter

Chetter is reached through the `chetter` MCP server (project `.mcp.json`, token from `CHETTER_MCP_TOKEN`; 60 tools). In Pi the adapter exposes them through the `mcp` proxy for single calls and `mcpScript` for anything involving loops or several calls:

```
mcp({ search: "runner" })                       # find tools
mcp({ describe: "chetter_chetter_submit_task" }) # exact shapes
mcp({ tool: "chetter_chetter_list_tasks", args: { status: "running" } })
```

**Naming**: 59 tools are double-prefixed `chetter_chetter_<name>`; one is single-prefixed `chetter_task_events` (full event history). Search before assuming a path.

Never reveal or echo secrets (`action_config`, tokens). Never prune/delete/clear without an explicit request: `chetter_chetter_clear_queue` and `chetter_chetter_delete_*` are destructive and need `confirm` where the schema demands it.

## Task lifecycle

| Tool | Shape | Notes |
|------|-------|-------|
| `chetter_chetter_list_tasks` | `{status?, trigger_name?, search?, limit?}` | statuses: `pending`, `running`, `done`, `errored`, `cancelled` |
| `chetter_chetter_task_status` | `{task_id}` | current status + result details |
| `chetter_chetter_task_progress` | `{task_id, limit?, offset?}` | distilled progress timeline |
| `chetter_chetter_task_latest_event` | `{task_id}` | newest event only |
| `chetter_task_events` | `{task_id}` | **full** event history (single-prefix path) |
| `chetter_chetter_task_export` | `{task_id}` | markdown transcript of a finished task |
| `chetter_chetter_list_task_artifacts` | `{task_id?, execution_attempt_id?, artifact_type?, repo?, search?, limit?, offset?}` | GitHub artifacts (issues/PRs/comments) a run produced |
| `chetter_chetter_cancel_task` | `{task_id, reason?}` | pending/running only |
| `chetter_chetter_rerun_task` | `{task_id}` | identical parameters, new task |
| `chetter_chetter_recover_task` | `{task_id, prompt?}` | fresh agent session seeded with the failed session's export |
| `chetter_chetter_clear_queue` | `{confirm: true}` | cancels **all** pending tasks — only on explicit ask |

**Submit** — `chetter_chetter_submit_task`. Key fields: `prompt` (required), `git_url`, `git_ref`, `harness` (`opencode` | `claude-code` | `pi` | `codewhale` | `codex`; empty = runner default), `agent`, `provider_id`, `model_id`, `variant_id` (e.g. `high`/`minimal`), `skills[]`, `mcp_endpoints[]`, `env{}` (non-secret), `timeout_sec`, `isolation` (`required` = force gVisor; hardened fleets may demand it), `session_mode` (`none` | `resumable`, latter needs gVisor), `pause_reason`, `ttl_hours`, `team_id`/`team_name` (required when a non-admin token spans teams). Ask for prompt + repo before submitting; return the new task id.

**Sessions** — `chetter_chetter_list_agent_sessions` `{status?, search?, limit?}`; `chetter_chetter_agent_session_status` `{session_id}`; resume a paused/recoverable one with `chetter_chetter_resume_agent_session` `{session_id, prompt, timeout_sec?}`.

## Fleet

- `chetter_chetter_runner_health` `{include_tasks?}` — fleet health; `include_tasks=true` for per-runner task detail. Report image versions, running/stale counts.
- `chetter_chetter_drain_runner` `{runner_id, timeout_sec?}` — stop claiming new tasks, wait for current ones. Only on explicit ask.
- `chetter_chetter_usage_summary` `{group_by?, since_hours?, since?, until?, team_name?, trigger_name?, trigger_type?, repo?}` — token/cost aggregation.
- `chetter_chetter_list_audit_events` `{event_type?, source_type?, source_id?, target_type?, target_id?, repo?, search?, since_hours?, limit?, offset?, exclude_types?}` — server-side audit log.

## Self-test

`chetter_chetter_run_self_test` `{profile}` — profiles `quick`, `harnesses`, `providers`, `full` (default `quick`). Report the run id and submitted checks, then poll `chetter_chetter_self_test_status` `{run_id}` until pass/fail; summarize each check, including runner-observed MCP evidence.

## Triggers

- List: `chetter_chetter_list_triggers` `{enabled_only?, trigger_type?}` (types: cron, PR review webhook).
- Create: `chetter_chetter_create_trigger` `{name, trigger_type, cron_expr?, repo?, event?, prompt?, git_url?, git_ref?, agent?, provider_id?, model_id?, variant_id?, agent_image?, skills?, team_id?}`.
- Update: `chetter_chetter_update_trigger` `{name, ...fields}` — only provided fields change.
- `chetter_chetter_delete_trigger` `{name}`, `chetter_chetter_run_trigger` `{name}` (fire now), `chetter_chetter_list_trigger_runs` `{trigger_name?, limit?}`.

## Event callbacks

- `chetter_chetter_list_event_callbacks` `{enabled_only?, event_type?, limit?}` — summarize name/event_type/action_type; never print `action_config` secrets.
- `chetter_chetter_create_event_callback` `{name, event_type, action_type, action_config, enabled?}`; update with `chetter_chetter_update_event_callback` `{name, event_type?, action_type?, action_config?, enabled?}` (only provided fields change); delete with `{name}`.
- Deliveries: `chetter_chetter_list_webhook_deliveries` `{limit?, offset?}`, `chetter_chetter_list_callback_deliveries` `{status?, limit?, offset?}` — use to prove an outbound callback actually fired.

## Models, definitions, proposals

- `chetter_chetter_get_model_catalog` `{}` — active catalog, default provider/model, counts, source; `DEFINITIONS_REPO` can override built-ins.
- Sources: `chetter_chetter_list_definition_sources`; `chetter_chetter_get_definition_source` / `chetter_chetter_sync_definition_source` `{source_id?|name?}`; `chetter_chetter_sync_definitions` `{confirm?}` re-pulls everything (admin).
- Definitions: `chetter_chetter_list_definitions` `{definition_type?, source_id?}`; `chetter_chetter_get_definition` `{definition_type, name, source_id?, scope?}`.
- Proposals: `chetter_chetter_list_definition_proposals` `{source_id?, status?, limit?}`; `chetter_chetter_get_definition_proposal` `{proposal_id?|repo?, pr_number?}` includes live PR status; `chetter_chetter_create_definition_proposal` `{title, files, source_id?, task_id?, body?, branch?, base_branch?, draft?}`.

## Git identities

- `chetter_chetter_list_git_identities` `{}` — reference, git author name/email, team scope, credential provider, default flag. Never expose credentials.
- Create/update: `{name, git_author_name, git_author_email, credential_type?}` (+team).
- `chetter_chetter_set_git_identity_default` `{name}` / `chetter_chetter_delete_git_identity` `{name}` — only on explicit request.

## Teams, users, tokens (admin)

`chetter_chetter_list_teams` `{}`, `chetter_chetter_create_team` / `chetter_chetter_delete_team` `{name}`, `chetter_chetter_list_users` `{team_name?}`, `chetter_chetter_list_tokens` `{}`, `chetter_chetter_create_token` `{team_name, user_name, token_name, team_names?, expires_in_hours?}`, `chetter_chetter_delete_token` `{name}`. Admin tooling — act only when asked, and never print token values.

## Arcane vulnerability scanning

`chetter_chetter_arcane_scanner_status` `{environment_id?}`, `chetter_chetter_arcane_environment_summary` `{environment_id?}`, `chetter_chetter_arcane_list_images` `{environment_id?}`, `chetter_chetter_arcane_image_summary` `{image_id, environment_id?}`, `chetter_chetter_arcane_list_vulnerabilities` `{image_id, environment_id?, severity?, page?, limit?}` — Trivy-backed image scanning; `severity` filters CRITICAL/HIGH/etc.

## Workflows

### Status report
`runner_health` (`include_tasks=true`) + `list_tasks` for `running` and `pending` + `list_triggers`. Summarize fleet (image versions, stale runners), each active task (id, repo/branch, model, elapsed, last event), pending queue, and trigger inventory. Flag running tasks quiet for >10 min (check `task_latest_event`).

### Diagnose a specific task
`task_status` → `task_progress` → `task_latest_event`; go to `chetter_task_events` for the full history when the summary is not enough; `task_export` for the transcript; `list_task_artifacts` for what it produced (PRs/issues). Then `rerun_task` (same params) or `recover_task` (session-aware retry).
