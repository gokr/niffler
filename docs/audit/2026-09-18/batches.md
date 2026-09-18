# Consolidation batches

One batch per subagent; each writes an edit set to `edits/batch-N.json`
(plus `edits/batch-N.summary.md`) which the parent applies to `docs/MANUAL.md`.
Handled by the parent: layout-of-a-running-system, state-and-configuration.

## batch-1 (60 rows)

- `sections/skills.md` — 26 rows
- `sections/context-window.md` — 12 rows
- `sections/fabric-and-subagents.md` — 9 rows
- `sections/x-claims-that-are-simply-wrong.md` — 7 rows
- `sections/a-documented-but-stale-wrong.md` — 4 rows
- `sections/wrong-or-misleading-claims-in-this-slice.md` — 2 rows

## batch-2 (59 rows)

- `sections/component-bash.md` — 22 rows
- `sections/y-capabilities-missing-from-manual.md` — 13 rows
- `sections/component-mcp.md` — 9 rows
- `sections/testing.md` — 7 rows
- `sections/troubleshooting.md` — 5 rows
- `sections/minimal-boot-profile.md` — 2 rows
- `sections/contents.md` — 1 rows

## batch-3 (59 rows)

- `sections/fetch.md` — 22 rows
- `sections/component-llm.md` — 12 rows
- `sections/background-processes-processes.md` — 9 rows
- `sections/observation-and-logs.md` — 7 rows
- `sections/shipped-components.md` — 5 rows
- `sections/common-tasks.md` — 3 rows
- `sections/could-not-determine.md` — 1 rows

## batch-4 (59 rows)

- `sections/component-expert.md` — 18 rows
- `sections/starting-and-stopping.md` — 13 rows
- `sections/component-provider.md` — 10 rows
- `sections/component-processes.md` — 8 rows
- `sections/the-bus-in-one-screen.md` — 6 rows
- `sections/system-prompt-systemprompt.md` — 3 rows
- `sections/shipped-components-layout.md` — 1 rows

## batch-5 (59 rows)

- `sections/component-edit.md` — 16 rows
- `sections/environment-variables.md` — 14 rows
- `sections/component-fabric.md` — 11 rows
- `sections/provider-registry-provider.md` — 8 rows
- `sections/wrong-claims-summary.md` — 6 rows
- `sections/y-missing-capability.md` — 3 rows
- `sections/the-env-file.md` — 1 rows

## batch-6 (59 rows)

- `sections/component-repomap.md` — 16 rows
- `sections/approvals.md` — 13 rows
- `sections/model-catalog-models.md` — 12 rows
- `sections/component-models.md` — 7 rows
- `sections/component-ecosystem-plugins.md` — 6 rows
- `sections/expert-model-catalog-background-processes-mcp-spot-checks.md` — 4 rows
- `sections/z-sections-to-trim-to-a-pointer-other-docs-own-them.md` — 1 rows

## batch-7 (58 rows)

- `sections/proposed-top-level-outline-for-manual-as-a-reference-manual.md` — 16 rows
- `sections/progressive-tool-discovery.md` — 13 rows
- `sections/the-store.md` — 12 rows
- `sections/language-servers-lsp.md` — 7 rows
- `sections/hooks.md` — 6 rows
- `sections/recovery.md` — 4 rows

## batch-8 (58 rows)

- `sections/component-git.md` — 14 rows
- `sections/component-lsp.md` — 14 rows
- `sections/external-mcp-servers-mcp.md` — 12 rows
- `sections/self-extension-and-component-lifecycle.md` — 9 rows
- `sections/expert-advisory-peer-expert.md` — 5 rows
- `sections/session-runners.md` — 4 rows


Split note: batch-5 died on its token budget with nothing written; it was
split into 5a (component-edit, environment-variables, the-env-file — 31 rows)
and 5b (component-fabric, provider-registry-provider, wrong-claims-summary,
y-missing-capability — 28 rows).
