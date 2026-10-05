# bench report — full31-direct-dsh-low

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | dsh | t01-roman | pass | 4.9 | 1 | 3 | 4.3k | 1.2k | 486 | 2.6k/0 | 0.0010 | 0.0010 | 31/1 |
| deepseek-v4-flash | dsh | t02-jsonrepair | pass | 55.9 | 1 | 10 | 78.6k | 3.8k | 10.0k | 64.8k/0 | 0.0136 | 0.0136 | 113/1 |
| deepseek-v4-flash | dsh | t03-ringbuffer | pass | 8.8 | 1 | 3 | 4.7k | 1.0k | 758 | 2.9k/0 | 0.0012 | 0.0012 | 15/4 |
| deepseek-v4-flash | dsh | t04-csvbugfix | pass | 8.5 | 1 | 6 | 12.4k | 2.4k | 788 | 9.2k/0 | 0.0017 | 0.0017 | 3/3 |
| deepseek-v4-flash | dsh | t05-todostore | pass | 8 | 1 | 4 | 8.1k | 1.7k | 1.2k | 5.1k/0 | 0.0020 | 0.0020 | 22/4 |
| deepseek-v4-flash | dsh | t06-stackvm | pass | 88.9 | 1 | 13 | 211.0k | 10.0k | 15.6k | 185.5k/0 | 0.0228 | 0.0228 | 162/45 |
| deepseek-v4-flash | dsh | t07-validate | pass | 14.1 | 1 | 6 | 19.5k | 3.9k | 1.9k | 13.7k/0 | 0.0035 | 0.0035 | 24/12 |
| deepseek-v4-flash | dsh | t08-logsum | pass | 29.4 | 1 | 8 | 42.4k | 3.9k | 4.6k | 33.8k/0 | 0.0069 | 0.0069 | 117/5 |
| deepseek-v4-flash | dsh | t09-poolrace | pass | 8.7 | 1 | 3 | 5.8k | 1.4k | 1.1k | 3.2k/0 | 0.0018 | 0.0018 | 10/4 |
| deepseek-v4-flash | dsh | t10-iniparse | pass | 23.3 | 1 | 8 | 30.1k | 3.9k | 2.2k | 24.1k/0 | 0.0039 | 0.0039 | 9/6 |
| deepseek-v4-flash | dsh | t11-asyncbugs | pass | 14.1 | 1 | 8 | 27.2k | 5.0k | 1.5k | 20.7k/0 | 0.0034 | 0.0034 | 5/10 |
| deepseek-v4-flash | dsh | t12-refactor | pass | 7.5 | 1 | 5 | 9.0k | 1.8k | 712 | 6.4k/0 | 0.0014 | 0.0014 | 2/4 |
| deepseek-v4-flash | dsh | t13-batchrename | pass | 6.1 | 1 | 4 | 8.8k | 2.8k | 490 | 5.5k/0 | 0.0015 | 0.0015 | 27/27 |
| deepseek-v4-flash | dsh | t14-todosweep | pass | 9.8 | 1 | 6 | 15.3k | 3.2k | 1.0k | 11.1k/0 | 0.0023 | 0.0023 | 18/0 |
| deepseek-v4-flash | dsh | t15-pollstats | pass | 5.5 | 1 | 3 | 4.8k | 1.3k | 549 | 2.9k/0 | 0.0011 | 0.0011 | 1/0 |
| deepseek-v4-flash | dsh | t16-apisum | pass | 7 | 1 | 3 | 4.7k | 1.3k | 444 | 2.9k/0 | 0.0010 | 0.0010 | 19/0 |
| deepseek-v4-flash | dsh | t17-doccheck | pass | 45.5 | 1 | 8 | 55.5k | 3.1k | 8.0k | 44.4k/0 | 0.0108 | 0.0108 | 101/0 |
| deepseek-v4-flash | dsh | t18-lruttl | pass | 23 | 1 | 5 | 21.3k | 4.6k | 3.7k | 13.1k/0 | 0.0059 | 0.0059 | 126/12 |
| deepseek-v4-flash | dsh | t19-tokbucket | pass | 12.5 | 1 | 5 | 15.6k | 3.6k | 1.8k | 10.2k/0 | 0.0033 | 0.0033 | 23/11 |
| deepseek-v4-flash | dsh | t20-jsonpatch | pass | 155.2 | 1 | 18 | 432.8k | 11.4k | 29.9k | 391.4k/0 | 0.0417 | 0.0417 | 290/14 |
| deepseek-v4-flash | dsh | t21-wireproto | pass | 33.4 | 1 | 5 | 27.6k | 4.0k | 6.2k | 17.4k/0 | 0.0088 | 0.0088 | 71/8 |
| deepseek-v4-flash | dsh | t22-cronnext | pass | 99 | 1 | 11 | 168.8k | 7.0k | 18.9k | 142.8k/0 | 0.0257 | 0.0257 | 131/16 |
| deepseek-v4-flash | dsh | t23-mergesched | pass | 31.6 | 1 | 5 | 29.8k | 4.1k | 5.6k | 20.1k/0 | 0.0080 | 0.0080 | 81/4 |
| deepseek-v4-flash | dsh | t24-editops | pass | 104.4 | 1 | 11 | 155.6k | 5.5k | 19.4k | 130.8k/0 | 0.0257 | 0.0257 | 120/11 |
| deepseek-v4-flash | dsh | t25-shardmap | pass | 20.9 | 1 | 6 | 22.5k | 3.9k | 3.0k | 15.6k/0 | 0.0049 | 0.0049 | 79/16 |
| deepseek-v4-flash | dsh | t26-logfilter | pass | 122.4 | 1 | 12 | 205.8k | 8.0k | 22.5k | 175.4k/0 | 0.0305 | 0.0305 | 326/4 |
| deepseek-v4-flash | dsh | t27-tarpeek | pass | 93 | 1 | 22 | 399.7k | 20.9k | 13.5k | 365.3k/0 | 0.0246 | 0.0246 | 113/1 |
| deepseek-v4-flash | dsh | t28-docbackfill | pass | 11.7 | 1 | 7 | 29.9k | 5.6k | 1.1k | 23.2k/0 | 0.0032 | 0.0032 | 18/9 |
| deepseek-v4-flash | dsh | t29-logrollup | pass | 7 | 1 | 4 | 7.9k | 2.1k | 769 | 5.0k/0 | 0.0016 | 0.0016 | 436/0 |
| deepseek-v4-flash | dsh | t30-ifacedrift | pass | 8.1 | 1 | 6 | 28.8k | 7.4k | 786 | 20.6k/0 | 0.0033 | 0.0033 | 48/48 |
| deepseek-v4-flash | dsh | t31-tinyrename | pass | 6.9 | 1 | 5 | 12.0k | 2.9k | 677 | 8.4k/0 | 0.0017 | 0.0017 | 6/6 |
| deepseek-v4-flash | niffler | t01-roman | pass | 5.5 | 1 | 4 | 14.3k | 3.6k | 436 | 10.2k/0 | 0.0017 | 0.0017 | 13/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 9.6 | 1 | 5 | 21.8k | 1.9k | 1.5k | 18.4k/0 | 0.0025 | 0.0025 | 78/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 11.9 | 1 | 5 | 21.1k | 2.5k | 815 | 17.8k/0 | 0.0018 | 0.0018 | 16/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 6.6 | 1 | 5 | 19.9k | 2.3k | 421 | 17.2k/0 | 0.0013 | 0.0013 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 7.1 | 1 | 5 | 19.9k | 2.4k | 627 | 16.9k/0 | 0.0016 | 0.0016 | 16/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 29.1 | 1 | 5 | 51.3k | 6.7k | 6.3k | 38.3k/0 | 0.0098 | 0.0098 | 143/34 |
| deepseek-v4-flash | niffler | t07-validate | pass | 9.5 | 1 | 5 | 25.7k | 3.5k | 1.2k | 21.0k/0 | 0.0026 | 0.0026 | 15/9 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 18.7 | 1 | 8 | 48.2k | 4.3k | 2.1k | 41.7k/0 | 0.0041 | 0.0041 | 64/2 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 10.2 | 1 | 5 | 18.9k | 1.9k | 606 | 16.4k/0 | 0.0014 | 0.0014 | 6/1 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 16.2 | 1 | 6 | 28.2k | 3.2k | 1.2k | 23.8k/0 | 0.0025 | 0.0025 | 7/6 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 9.3 | 1 | 5 | 22.4k | 3.2k | 870 | 18.3k/0 | 0.0021 | 0.0021 | 5/10 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 5.4 | 1 | 4 | 15.7k | 2.0k | 464 | 13.2k/0 | 0.0012 | 0.0012 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 57.1 | 1 | 7 | 75.3k | 13.0k | 3.0k | 59.3k/0 | 0.0078 | 0.0078 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 5 | 1 | 4 | 15.5k | 1.9k | 433 | 13.2k/0 | 0.0012 | 0.0012 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 6.8 | 1 | 4 | 14.5k | 1.6k | 653 | 12.3k/0 | 0.0013 | 0.0013 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 9.1 | 1 | 4 | 14.4k | 1.7k | 337 | 12.4k/0 | 0.0010 | 0.0010 | 21/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 31 | 1 | 7 | 44.4k | 4.1k | 3.1k | 37.2k/0 | 0.0051 | 0.0051 | 118/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 11.5 | 1 | 4 | 24.0k | 3.5k | 1.7k | 18.8k/0 | 0.0032 | 0.0032 | 123/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 7 | 1 | 3 | 14.4k | 3.1k | 817 | 10.5k/0 | 0.0020 | 0.0020 | 27/13 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 35.8 | 1 | 6 | 52.0k | 4.7k | 7.8k | 39.4k/0 | 0.0111 | 0.0111 | 213/13 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 11.1 | 1 | 3 | 17.3k | 3.4k | 1.9k | 12.0k/0 | 0.0034 | 0.0034 | 62/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 22.9 | 1 | 7 | 56.1k | 4.8k | 3.8k | 47.5k/0 | 0.0063 | 0.0063 | 108/16 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 17.6 | 1 | 5 | 34.7k | 3.9k | 2.8k | 28.0k/0 | 0.0047 | 0.0047 | 80/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 30 | 1 | 8 | 68.9k | 5.7k | 5.5k | 57.7k/0 | 0.0086 | 0.0086 | 107/11 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 11.7 | 1 | 5 | 25.3k | 3.3k | 1.2k | 20.9k/0 | 0.0026 | 0.0026 | 80/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 26.9 | 1 | 4 | 33.5k | 3.2k | 5.3k | 25.0k/0 | 0.0075 | 0.0075 | 263/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 32.6 | 1 | 13 | 117.7k | 9.2k | 4.2k | 104.3k/0 | 0.0085 | 0.0085 | 69/4 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 7.8 | 1 | 5 | 21.9k | 2.9k | 830 | 18.2k/0 | 0.0020 | 0.0020 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 7.9 | 1 | 4 | 17.7k | 2.3k | 927 | 14.5k/0 | 0.0019 | 0.0019 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 12.6 | 1 | 7 | 50.0k | 6.5k | 1.2k | 42.4k/0 | 0.0036 | 0.0036 | 48/48 |
| deepseek-v4-flash | niffler | t31-tinyrename | pass | 12.7 | 1 | 5 | 22.7k | 3.3k | 689 | 18.7k/0 | 0.0019 | 0.0019 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | dsh | 31/31 | 7.2 | 35 | 67.8k | 4.6k | 57.4k | 5.8k | 0.2687 | 0.2687 | 82/9 |
| deepseek-v4-flash | niffler | 31/31 | 5.4 | 16 | 33.1k | 3.9k | 27.3k | 2.0k | 0.1162 | 0.1162 | 71/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*

## Run provenance and interpretation

- Fresh paired run on 2026-10-05: `node bench/run.mjs --harness niffler,dsh --model deepseek-v4-flash --task all --rounds 1 --jobs 2 --thinking low --run-id full31-direct-dsh-low`. Both lanes used `https://api.deepseek.com/v1`, `deepseek-v4-flash` (serving V4.1 Flash); **no LLM Gateway**. One verification round per task over the now-31-task suite (adds `t31-tinyrename`): 31 results per lane, no invalid, leak, or error cells — a clean sweep on both.
- DSH: `dsh-v0.2.1-alpha.1` (`5badb15009`, also `origin/master` at run time) built from `/home/gokr/git/harnesses/deepseek-harness` via `pnpm run clean` + `pnpm run build:lib:host`; `sdk-minimal` profile, `deepseek-official`, native effort `low`. Note for reproducers: building over artifacts left by an older version fails on unresolvable `/invariant` subpaths — run `pnpm run clean` first.
- Niffler: `make build` from this worktree (includes the provider/model one-pin contract `152ccfa` and later main commits); per-combo isolated bus/root; `AGENTS.md`/`AGENTS.local.md` excluded from the bench root.
- Times and costs are descriptive per-cell aggregates. DSH's `sdk-minimal` exposes a leaner tool surface than Niffler's full direct set, so the numbers compare these deployed setups rather than matched tool surfaces. `full30-direct-dsh-rc3-low` used `dsh-v0.1.5-rc.3` and the older full30 used a different gateway — neither is directly comparable to this run; raw cells for this one live in `var/bench/results/full31-direct-dsh-low/`.
