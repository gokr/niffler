# Skill locations observed in local harness sources

Inspection of `/home/gokr/git/harnesses`; these are checkout observations,
not a claim that every released harness supports every location. Paths may
change with configuration, profiles, platform or version.

Niffler's agreed normal discovery: workspace `.agents/skills`, user
`~/.agents/skills`, bundled. Shared SKILL.md format does not guarantee identical
execution, resource or metadata semantics across harnesses.

## Evidence and candidate explicit copy sources

| Harness/convention | User location | Project location | Evidence relative to harness checkout |
|---|---|---|---|
| Generic agents | `~/.agents/skills` | `.agents/skills` | Codex `codex-rs/ext/skills/src/host_roots.rs:96-110,154`; Gemini `packages/core/src/config/storage.ts:142-148,352-358`; Kimi `src/kimi_cli/skill/__init__.py:55-98` |
| Generic config alternative | `~/.config/agents/skills` | — | Kimi same file:55-64; prefers this over ~/.agents/skills within its generic group |
| Claude compatibility | `~/.claude/skills` | `.claude/skills` | Kimi same file:67-98; Maki `plugins/skill/init.lua:11-21`; OpenCode `packages/core/src/config/plugin/compatibility.ts:40` (compatibility roots) |
| Codex | `$CODEX_HOME/skills` (normally `~/.codex/skills`) | `.codex/skills` via project config roots | Codex `codex-rs/ext/skills/src/host_roots.rs:85-110`; user location explicitly called deprecated there; sample installer `codex-rs/skills/src/assets/samples/skill-installer/SKILL.md:48` |
| Gemini | `~/.gemini/skills` | `.gemini/skills` | `packages/core/src/config/storage.ts:142,352`; `skills/skillManager.ts` also loads .agents aliases |
| Kimi | `~/.kimi/skills` | `.kimi/skills` | `src/kimi_cli/skill/__init__.py:67-98` |
| Pi | `~/.pi/agent/skills` (agent dir override possible) | `.pi/skills` | `packages/coding-agent/src/core/skills.ts:458-463`; `src/config.ts:581,604-610` |
| Maki | `~/.config/maki/skills` (legacy `~/.maki/skills`) | `.maki/skills` | `site/docs/content/skills/_index.md:19-21`, `plugins/skill/init.lua:11-21`; runtime config directory may differ |
| OpenCode compatibility | `~/.config/opencode/skills` | `.opencode/skills` | Maki `plugins/skill/init.lua:14,19` explicitly recognizes these; current OpenCode has configurable directory sources in `packages/core/src/config/plugin/skill.ts:87` rather than one universal fixed root |
| Hermes | `$HERMES_HOME/skills` (normally `~/.hermes/skills`) | — | `tools/skills_tool.py:66-75`, `hermes_constants.py:1198-1200`; profiles can change root |
| Legacy Niffler | `~/.niffler/skills` | `.opencode/skills` in older Niffler | Our previous component source; explicit copy source only, no automatic activation |

## Future explicit scan/import behavior

Not implemented yet. Keep candidate paths as a declarative registry with home,
workspace and optional configured-root anchors. Do not automatically scan all
these directories during ordinary skill_list/load.

- Scan only on explicit request; report harness, path, parsed name and conflicts.
- Copy the full selected skill tree to user/workspace `.agents/skills`, with
  approval and no overwrite by default. Leave originals intact.
- Show provenance; do not import hidden caches, trash or system bundles merely
  because a recursive walk finds a SKILL.md. Codex `.system` is one example.
- Handle symlinks deliberately: avoid loops and escapes, distinguish duplicate
  real files, and bound copied bytes/files. Niffler's ordinary discovery does
  not follow symlinked directories or SKILL.md files.
- Do not execute imported scripts, hooks or installers. Loading instructions
  appends history; it must not alter the frozen prompt prefix.

This survey does not copy or move any actual user skills. Legacy Niffler user
skills must be explicitly copied/imported; no silent destructive migration.
