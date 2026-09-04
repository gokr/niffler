# bench report — full17-d2a1a36

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 11 | 1 | 28.7k | 6.9k | 865 | 21.0k/0 | 0.0000 | 31/1 | 1/1/1 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 45.5 | 1 | 56.0k | 9.4k | 5.3k | 41.2k/0 | 0.0000 | 104/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 37 | 1 | 46.4k | 3.3k | 1.1k | 42.0k/0 | 0.0000 | 16/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 7.8 | 1 | 26.3k | 1.5k | 542 | 24.3k/0 | 0.0000 | 3/3 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 18.9 | 1 | 57.3k | 5.0k | 1.9k | 50.4k/0 | 0.0000 | 21/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 70 | 1 | 87.1k | 7.1k | 9.4k | 70.6k/0 | 0.0000 | 146/68 | 1/1/1 |
| deepseek-v4-flash | niffler-expert | t07-validate | pass | 25.1 | 1 | 51.3k | 4.9k | 2.8k | 43.6k/0 | 0.0000 | 13/9 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t08-logsum | pass | 24.5 | 1 | 77.2k | 5.4k | 2.5k | 69.3k/0 | 0.0000 | 71/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t09-poolrace | pass | 14.3 | 1 | 40.6k | 4.2k | 1.4k | 34.9k/0 | 0.0000 | 4/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t10-iniparse | pass | 24.8 | 1 | 55.2k | 5.2k | 1.4k | 48.5k/0 | 0.0000 | 5/6 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t11-asyncbugs | pass | 15.7 | 1 | 41.9k | 4.8k | 1.8k | 35.3k/0 | 0.0000 | 5/10 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t12-refactor | pass | 11.4 | 1 | 42.1k | 3.7k | 1.0k | 37.3k/0 | 0.0000 | 2/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t13-batchrename | pass | 7.1 | 1 | 29.8k | 4.5k | 660 | 24.6k/0 | 0.0000 | 27/27 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t14-todosweep | pass | 16.6 | 1 | 45.4k | 5.2k | 1.9k | 38.3k/0 | 0.0000 | 18/0 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t15-pollstats | pass | 10.9 | 1 | 27.4k | 2.3k | 562 | 24.4k/0 | 0.0000 | 1/0 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t16-apisum | pass | 11.3 | 1 | 29.8k | 2.1k | 1.0k | 26.7k/0 | 0.0000 | 22/0 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t17-doccheck | pass | 26.4 | 1 | 83.9k | 4.0k | 2.4k | 77.4k/0 | 0.0000 | 74/0 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 25.7 | 1 | 19.0k | 6.9k | 300 | 11.8k/0 | 0.0000 | 13/1 | 1/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 36.3 | 1 | 31.5k | 10.0k | 596 | 20.9k/0 | 0.0000 | 47/10 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 39.3 | 1 | 36.2k | 4.4k | 622 | 31.2k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 77.1 | 1 | 49.0k | 4.9k | 532 | 43.6k/0 | 0.0000 | 3/3 | 2/1/1 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 60.1 | 1 | 13.9k | 1.4k | 400 | 12.1k/0 | 0.0000 | 18/4 | 0/0/0 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 95.4 | 1 | 59.8k | 6.7k | 2.6k | 50.5k/0 | 0.0000 | 131/32 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t07-validate | pass | 34.7 | 1 | 32.7k | 2.9k | 783 | 29.1k/0 | 0.0000 | 16/8 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t08-logsum | pass | 59.4 | 1 | 49.0k | 16.0k | 814 | 32.1k/0 | 0.0000 | 50/2 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t09-poolrace | pass | 45.7 | 1 | 13.6k | 4.2k | 381 | 9.1k/0 | 0.0000 | 4/1 | 0/0/0 |
| glm-5.3-flash | niffler-expert | t10-iniparse | pass | 75.8 | 1 | 37.7k | 8.0k | 655 | 29.0k/0 | 0.0000 | 7/5 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t11-asyncbugs | pass | 24.7 | 1 | 20.1k | 7.6k | 344 | 12.2k/0 | 0.0000 | 6/11 | 0/0/0 |
| glm-5.3-flash | niffler-expert | t12-refactor | pass | 42 | 1 | 27.9k | 10.2k | 370 | 17.3k/0 | 0.0000 | 2/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t13-batchrename | pass | 15.1 | 1 | 10.1k | 1.8k | 89 | 8.3k/0 | 0.0000 | 27/27 | 0/0/0 |
| glm-5.3-flash | niffler-expert | t14-todosweep | pass | 26.5 | 1 | 16.9k | 2.7k | 157 | 14.1k/0 | 0.0000 | 18/0 | 1/0/0 |
| glm-5.3-flash | niffler-expert | t15-pollstats | pass | 25.4 | 1 | 19.4k | 1.4k | 313 | 17.6k/0 | 0.0000 | 1/0 | 1/0/0 |
| glm-5.3-flash | niffler-expert | t16-apisum | pass | 42.6 | 1 | 28.4k | 3.0k | 445 | 25.0k/0 | 0.0000 | 14/0 | 1/1/1 |
| glm-5.3-flash | niffler-expert | t17-doccheck | pass | 36.5 | 1 | 37.0k | 7.3k | 702 | 29.0k/0 | 0.0000 | 39/0 | 2/0/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler-expert | 17/17 | 22 | 48.6k | 4.7k | 41.8k | 2.2k | 33/8 |
| glm-5.3-flash | niffler-expert | 17/17 | 45 | 29.5k | 5.8k | 23.1k | 596 | 24/7 |

*`invalid*` = tests pass but protected files (tests) were modified.*

## Niffler-expert delta vs full17-5aa8c97 (same 17 tasks, both models)

The only variable between the runs is the expert rebuild at `d2a1a36`
(tool-selection mission policy, session-visible knowledge, skill-backed
prefix, observation-grounded delivery gates); worker prompt/tools and
task code are identical.

- Verdicts: 17/17 both models in both runs — no worker regressions, no new
  invalid cells.
- Accepted steers: deepseek 0 -> 2 (t01-roman, t06-stackvm), glm 1 -> 2
  (t04-csvbugfix, t16-apisum). First run where a deepseek worker accepted
  expert advice. The four steers name a component and a concrete tool
  (discover+invoke, files/read_many vs ls/cat, git_status/git_show,
  fetch with url/strings args) — the richer steer contract in action.
- Validation held: 1 steer suppressed (glm t07) for not naming the tool
  verbatim in the message; 1 task-strategy steer (deepseek t11, "verify
  the bash result") suppressed by the tool-change gate. Errors 4 -> 1
  across both models.
- Judge economics: prefix grew (avg judgment prompt 7.1k -> 11.1k deepseek,
  7.1k -> 8.3k glm tokens) but cache-hit rate improved (77.8 -> 82.5%,
  87.2 -> 90.0%) — the added knowledge is the cached, per-follow part.
  Judgment cadence unchanged (1.7/1.8 -> 1.65/1.29 per task).
- glm quiet cells: t05/t09/t11/t13 ran 0 judgments (cooldown + in-flight
  scheduling with the larger judge prompt) — best-effort lossiness, no
  delivery errors; noted as a tuning lever, not a failure.
