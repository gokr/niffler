# Documentation

Start with the [project README](../README.md) for installation and quick start.
Each document below has one job; follow links rather than duplicating reference
material across them.

| Question | Read |
|---|---|
| How do I operate, configure, test or recover it? | [MANUAL.md](MANUAL.md) |
| What is the exact bus/tool contract? | [WIRE.md](WIRE.md) |
| Why is something core rather than a component? | [ARCHITECTURE.md](ARCHITECTURE.md) |
| What capabilities exist? | [FEATURES.md](FEATURES.md) — index, not reference |
| What should we build next? | [PLAN.md](PLAN.md) — current status and acceptance work |
| How do we finish remote task delegation? | [FLEET.md](FLEET.md) — active plan, authority, receipts, notices and artifacts |
| How do I orchestrate tools and subagents? | [FABRIC_GUIDE.md](FABRIC_GUIDE.md) |
| How does the context projection work? | [COMPACTION.md](COMPACTION.md) — conceptual model; operating knobs stay in the manual |
| How do I extend the model catalog? | [MODEL_SOURCES.md](MODEL_SOURCES.md) |
| Why was a design chosen? | [research/README.md](research/README.md) |
| What ideas are deliberately unscheduled? | [research/BACKLOG.md](research/BACKLOG.md) |

## Status-sensitive reading

- **Write arbitration:** [design and implementation record](research/WRITE-ARBITRATION.md).
  Coordination is not filesystem authorization or OS fencing.
- **Sandboxing:** [current experimental behavior](research/SANDBOX-BASH-STATUS.md)
  versus [agreed conversation-policy target](research/SANDBOX-CONVERSATION-POLICY.md).
  The older sandbox notes retain superseded proposals, not current promises.
- **Fleet:** [manual](MANUAL.md#ssh-and-lima-provisioning),
  [component reference](../components/fleet/README.md) and
  [active delivery plan](FLEET.md).
  Provisioning and read-only task delegation are implemented; unattended coding
  tasks and the full inbox/artifact workflow remain open.

## Maintenance

Keep runtime defaults and commands in the manual, protocol fields in WIRE, and
active priorities in PLAN. A feature-index entry should link to those authorities,
not copy their parameter tables. Research is retained evidence: add a status
banner and a successor link when a decision is superseded.

Localized READMEs/manuals are AI translations of English. Refresh affected
sections after changing the source; retain English headings for stable anchors.
A partial refresh is not a claim that the entire translation is synchronized.
Client keybindings/help and UI implementation belong to the client repository,
not a second independently maintained table here.
