# batch-open2-1 — Layout of a running system (55 rows)

`edits/batch-open2-1.json` decides every open row of
`batch-open2-1.txt` (`sections/layout-of-a-running-system.md`) against
`docs/MANUAL.md` @ working tree, sha256 prefix `c6884160053d914f`.

| status | rows | which |
|---|---|---|
| apply | 24 | A529 A530 A534 A535 A560 A592 A594 A604 A629 A648 A649 A694 A726 A733 A735 A737 A738 A739 A740 A744 A746 A777 A786 A802 |
| already | 16 | A533 A559 A561 A577 A591 A603 A628 A673 A734 A736 A741 A742 A743 A748 A750 A820 |
| skip | 13 | A578 A593 A595 A596 A597 A598 A650 A745 A747 A749 A772 A780 A803 |
| code | 2 | A538 A599 |

Every `old_string` was verified twice against the current `docs/MANUAL.md`
(each occurs exactly once), the whole set was simulated in id order (no
anchor is consumed by another row's replacement, every `new_string` lands),
and no `new_string` contains another row's anchor.

**Merges / collisions worth knowing about**

- `A744` (hardcoded kind list, silent kind loss) and `A745`/`A772` share one
  anchor sentence → one edit; `A746` (ambiguous-source refusal) also carries
  `A747` ("either direction" is false) and `A749`'s re-run trap; `A649` (new
  `grep` in detail subsection) carries `A650` (rg missing → exit 127);
  `A777`'s table row carries `A780` (the bus binary is built by `make build`);
  `A802` carries `A803`'s "what the example does not do".
- `store_migrate`'s `A730`-`A732` (batch-open2-5, "The store") quote the same
  MANUAL sentences as `A744`/`A745`/`A746`/`A747`. That batch (already written)
  decided them `skip`, deferring explicitly to the rows here, so these are the
  only edits of those sentences and there is no duplicate-anchor ordering risk.
- `A781` (batch-open2-3, `apply`) rewrites the whole `**Attach to any bus**`
  bullet; `A780` therefore no longer anchors inside it — its content rides in
  `A777`'s new `nats-server` table row instead, and the two edits cannot
  collide.

**Code findings (not MANUAL edits)**

- `A538` — `builder.build` advertises `timeoutMs: 300000` but the Nim branch
  calls `runCmd` with no timeout (procutil default 120 000 ms):
  `components/builder/main.nim:96-99`.
- `A599` — `components/dialog/dialog.sh`: a headless `dialog_ask` returns the
  same `answer: timeout` as a human timeout, the raw `kind` is echoed although
  `show_dialog` normalizes it, and `shown: true` is returned for `via: log` and
  after a failed `zenity`/`notify-send` (`|| true` at :118/:123).
- `A749` (tool-doc half) — `niffler-store-migrate --force` is parsed and never
  honoured, while its own docstring promises a live-store refusal
  (`tools/store_migrate.nim:11`, :444-445).
