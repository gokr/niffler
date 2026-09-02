# bench report — expert-grounded-bfbb81b

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 26.5 | 1 | 81.2k | 18.2k | 2.5k | 60.5k/0 | 0.0000 | 13/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 21.6 | 1 | 101.2k | 10.0k | 2.2k | 89.1k/0 | 0.0000 | 3/3 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 122.5 | 1 | 208.5k | 15.3k | 16.5k | 176.7k/0 | 0.0000 | 158/52 | 2/0/0 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler-expert | 3/3 | 57 | 130.3k | 14.5k | 108.8k | 7.1k | 58/19 |

*`invalid*` = tests pass but protected files (tests) were modified.*
