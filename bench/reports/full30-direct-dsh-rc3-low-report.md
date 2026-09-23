# bench report — full30-direct-dsh-rc3-low

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | dsh | t01-roman | pass | 6.6 | 1 | 4 | 5.2k | 1.2k | 469 | 3.6k/0 | 0.0009 | 0.0009 | 16/1 |
| deepseek-v4-flash | dsh | t02-jsonrepair | pass | 61.1 | 1 | 9 | 76.1k | 5.0k | 10.8k | 60.3k/0 | 0.0148 | 0.0148 | 178/1 |
| deepseek-v4-flash | dsh | t03-ringbuffer | pass | 14.2 | 1 | 6 | 14.3k | 2.6k | 1.2k | 10.5k/0 | 0.0022 | 0.0022 | 17/4 |
| deepseek-v4-flash | dsh | t04-csvbugfix | pass | 7.8 | 1 | 4 | 11.7k | 4.3k | 746 | 6.7k/0 | 0.0022 | 0.0022 | 3/3 |
| deepseek-v4-flash | dsh | t05-todostore | pass | 8.1 | 1 | 4 | 7.3k | 1.9k | 847 | 4.5k/0 | 0.0016 | 0.0016 | 16/4 |
| deepseek-v4-flash | dsh | t06-stackvm | pass | 88.7 | 1 | 13 | 215.0k | 13.8k | 15.5k | 185.6k/0 | 0.0239 | 0.0239 | 186/64 |
| deepseek-v4-flash | dsh | t07-validate | pass | 24.7 | 1 | 7 | 29.9k | 4.5k | 4.2k | 21.1k/0 | 0.0065 | 0.0065 | 52/11 |
| deepseek-v4-flash | dsh | t08-logsum | pass | 30.2 | 1 | 7 | 36.7k | 4.7k | 5.0k | 27.0k/0 | 0.0075 | 0.0075 | 107/3 |
| deepseek-v4-flash | dsh | t09-poolrace | pass | 13.4 | 1 | 6 | 13.0k | 2.4k | 1.2k | 9.5k/0 | 0.0022 | 0.0022 | 6/1 |
| deepseek-v4-flash | dsh | t10-iniparse | pass | 40.5 | 1 | 8 | 41.0k | 3.9k | 5.4k | 31.6k/0 | 0.0079 | 0.0079 | 9/6 |
| deepseek-v4-flash | dsh | t11-asyncbugs | pass | 8.3 | 1 | 4 | 8.1k | 2.1k | 1.0k | 5.0k/0 | 0.0019 | 0.0019 | 5/10 |
| deepseek-v4-flash | dsh | t12-refactor | pass | 9.2 | 1 | 6 | 13.9k | 2.7k | 773 | 10.4k/0 | 0.0018 | 0.0018 | 2/4 |
| deepseek-v4-flash | dsh | t13-batchrename | pass | 8.2 | 1 | 5 | 12.7k | 3.0k | 645 | 9.1k/0 | 0.0017 | 0.0017 | 27/27 |
| deepseek-v4-flash | dsh | t14-todosweep | pass | 10.4 | 1 | 4 | 11.4k | 2.8k | 1.2k | 7.3k/0 | 0.0024 | 0.0024 | 18/0 |
| deepseek-v4-flash | dsh | t15-pollstats | pass | 8.6 | 1 | 5 | 8.2k | 1.7k | 738 | 5.8k/0 | 0.0014 | 0.0014 | 1/0 |
| deepseek-v4-flash | dsh | t16-apisum | pass | 7.8 | 1 | 4 | 5.7k | 1.6k | 410 | 3.7k/0 | 0.0010 | 0.0010 | 17/0 |
| deepseek-v4-flash | dsh | t17-doccheck | pass | 53.3 | 1 | 10 | 79.8k | 3.9k | 9.0k | 66.9k/0 | 0.0124 | 0.0124 | 108/0 |
| deepseek-v4-flash | dsh | t18-lruttl | pass | 389.8 | 1 | 10 | 98.8k | 6.7k | 14.5k | 77.7k/0 | 0.0198 | 0.0198 | 130/12 |
| deepseek-v4-flash | dsh | t19-tokbucket | pass | 13 | 1 | 5 | 16.1k | 3.8k | 1.8k | 10.5k/0 | 0.0033 | 0.0033 | 26/11 |
| deepseek-v4-flash | dsh | t20-jsonpatch | pass | 98.7 | 1 | 10 | 155.7k | 7.7k | 18.5k | 129.5k/0 | 0.0253 | 0.0253 | 256/10 |
| deepseek-v4-flash | dsh | t21-wireproto | pass | 37.3 | 1 | 6 | 39.8k | 4.8k | 6.6k | 28.4k/0 | 0.0096 | 0.0096 | 68/8 |
| deepseek-v4-flash | dsh | t22-cronnext | pass | 131 | 1 | 10 | 141.5k | 7.2k | 16.2k | 118.1k/0 | 0.0223 | 0.0223 | 128/12 |
| deepseek-v4-flash | dsh | t23-mergesched | pass | 45.3 | 1 | 8 | 53.7k | 4.5k | 7.3k | 41.9k/0 | 0.0104 | 0.0104 | 83/4 |
| deepseek-v4-flash | dsh | t24-editops | pass | 48.3 | 1 | 9 | 65.9k | 5.2k | 9.5k | 51.2k/0 | 0.0132 | 0.0132 | 187/11 |
| deepseek-v4-flash | dsh | t25-shardmap | pass | 16 | 1 | 3 | 10.9k | 2.7k | 2.5k | 5.8k/0 | 0.0038 | 0.0038 | 92/16 |
| deepseek-v4-flash | dsh | t26-logfilter | pass | 63.4 | 1 | 7 | 75.2k | 8.1k | 12.2k | 54.9k/0 | 0.0174 | 0.0174 | 268/4 |
| deepseek-v4-flash | dsh | t27-tarpeek | pass | 87.1 | 1 | 15 | 223.6k | 13.3k | 13.8k | 196.6k/0 | 0.0217 | 0.0217 | 95/2 |
| deepseek-v4-flash | dsh | t28-docbackfill | pass | 11.2 | 1 | 6 | 21.0k | 4.6k | 1.2k | 15.1k/0 | 0.0030 | 0.0030 | 18/9 |
| deepseek-v4-flash | dsh | t29-logrollup | pass | 6.7 | 1 | 4 | 7.6k | 2.2k | 594 | 4.7k/0 | 0.0014 | 0.0014 | 436/0 |
| deepseek-v4-flash | dsh | t30-ifacedrift | pass | 7.3 | 1 | 4 | 15.6k | 6.1k | 713 | 8.7k/0 | 0.0028 | 0.0028 | 48/48 |
| deepseek-v4-flash | niffler | t01-roman | pass | 6.2 | 1 | 4 | 15.7k | 3.8k | 407 | 11.5k/0 | 0.0017 | 0.0017 | 13/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 17.3 | 1 | 7 | 39.2k | 2.5k | 2.6k | 34.2k/0 | 0.0040 | 0.0040 | 72/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 10.5 | 1 | 5 | 21.3k | 2.3k | 670 | 18.3k/0 | 0.0016 | 0.0016 | 15/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 7.4 | 1 | 5 | 20.3k | 1.9k | 548 | 17.8k/0 | 0.0013 | 0.0013 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 7.8 | 1 | 5 | 22.1k | 2.6k | 753 | 18.8k/0 | 0.0018 | 0.0018 | 20/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 35.7 | 1 | 6 | 71.0k | 6.9k | 7.6k | 56.6k/0 | 0.0115 | 0.0115 | 155/30 |
| deepseek-v4-flash | niffler | t07-validate | pass | 8.8 | 1 | 5 | 22.8k | 2.2k | 1.0k | 19.6k/0 | 0.0020 | 0.0020 | 21/6 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 20.9 | 1 | 9 | 49.3k | 3.4k | 2.0k | 43.9k/0 | 0.0037 | 0.0037 | 80/4 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 12.6 | 1 | 5 | 22.1k | 2.3k | 828 | 18.9k/0 | 0.0018 | 0.0018 | 7/4 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 13 | 1 | 5 | 22.5k | 2.2k | 837 | 19.5k/0 | 0.0018 | 0.0018 | 9/6 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 7.7 | 1 | 5 | 21.6k | 2.1k | 693 | 18.8k/0 | 0.0016 | 0.0016 | 5/10 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 8.5 | 1 | 5 | 20.7k | 2.2k | 534 | 17.9k/0 | 0.0014 | 0.0014 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 4.3 | 1 | 3 | 11.7k | 1.8k | 293 | 9.6k/0 | 0.0010 | 0.0010 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 9.8 | 1 | 5 | 23.5k | 2.5k | 957 | 20.1k/0 | 0.0020 | 0.0020 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 25.9 | 1 | 9 | 63.4k | 6.1k | 2.3k | 55.0k/0 | 0.0049 | 0.0049 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 10.8 | 1 | 5 | 20.3k | 1.9k | 457 | 17.9k/0 | 0.0012 | 0.0012 | 20/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 34.8 | 1 | 9 | 64.1k | 4.5k | 3.4k | 56.2k/0 | 0.0058 | 0.0058 | 114/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 14.5 | 1 | 4 | 26.7k | 3.6k | 2.1k | 21.0k/0 | 0.0037 | 0.0037 | 109/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 8.8 | 1 | 4 | 23.2k | 3.7k | 1.2k | 18.3k/0 | 0.0026 | 0.0026 | 25/11 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 28 | 1 | 8 | 74.9k | 6.7k | 4.3k | 63.9k/0 | 0.0076 | 0.0076 | 209/13 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 28.3 | 1 | 7 | 58.9k | 4.2k | 5.4k | 49.3k/0 | 0.0081 | 0.0081 | 62/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 22.1 | 1 | 5 | 36.9k | 4.6k | 3.8k | 28.5k/0 | 0.0061 | 0.0061 | 103/12 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 10.5 | 1 | 3 | 15.9k | 2.4k | 1.7k | 11.8k/0 | 0.0028 | 0.0028 | 75/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 18.1 | 1 | 6 | 37.3k | 3.4k | 3.4k | 30.6k/0 | 0.0052 | 0.0052 | 86/6 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 15 | 1 | 5 | 27.2k | 3.3k | 1.2k | 22.7k/0 | 0.0026 | 0.0026 | 91/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 29.5 | 1 | 6 | 57.3k | 5.2k | 5.7k | 46.5k/0 | 0.0087 | 0.0087 | 259/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 41.2 | 1 | 11 | 128.5k | 9.4k | 6.1k | 113.0k/0 | 0.0108 | 0.0108 | 85/1 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 21 | 1 | 11 | 71.5k | 6.6k | 2.1k | 62.8k/0 | 0.0049 | 0.0049 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 9.9 | 1 | 6 | 36.3k | 5.2k | 888 | 30.2k/0 | 0.0028 | 0.0028 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 11.4 | 1 | 7 | 50.9k | 6.2k | 1.0k | 43.6k/0 | 0.0034 | 0.0034 | 48/48 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | dsh | 30/30 | 6.8 | 45 | 50.5k | 4.6k | 40.4k | 5.5k | 0.2464 | 0.2464 | 87/10 |
| deepseek-v4-flash | niffler | 30/30 | 6.0 | 17 | 39.2k | 3.9k | 33.2k | 2.2k | 0.1185 | 0.1185 | 73/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*

## Run provenance and interpretation

- Fresh paired run on 2026-09-23: `node bench/run.mjs --harness niffler,dsh --model deepseek-v4-flash --task all --rounds 1 --jobs 2 --thinking low --run-id full30-direct-dsh-rc3-low`. Both lanes used `https://api.deepseek.com/v1`, `deepseek-v4-flash` (serving V4.1 Flash); **no LLM Gateway**. One verification round per task, 30 results per lane, no invalid, leak, or error cells.
- DSH: pinned clean `dsh-v0.1.5-rc.3` (`a4c74a91e06b00fe0b0937bde982170c526cc842`), built with `pnpm run build:lib:host`, launched via `DSH_BIN` from that worktree with its `sdk-minimal` JSON-RPC profile (`deepseek-official`, native effort `low`). This profile is leaner than the interactive DSH toolset.
- Niffler: this checkout's prebuilt `var/bin` on an isolated bus and root; the bench root excludes `AGENTS.md` and `AGENTS.local.md`. The base prompt in `components/systemprompt/baseprompt.txt` was not changed. Bench prompt composition and tool profiles differ between harnesses; this measures those deployed setups, not a prompt-controlled ablation. The model label is the provider model identifier, not a reproducible model-weight hash.
- The 45s vs 17s mean time and $0.2464 vs $0.1185 peak-price estimates are descriptive **per-cell sums/averages**, not a serial wall-clock or proof of an intrinsic speed/cost advantage; request counts, prompt footprints and output lengths differ. Raw cell transcripts, diffs, and `run.json` live under `var/bench/results/full30-direct-dsh-rc3-low/` (disposable runtime state); the aggregate CSV/Markdown here is the committed record.
- The earlier `full30-deepseek-v4.1-flash-low` Niffler/Pi 30/30 used a different gateway/configuration and is historical, not a controlled third lane of this run.
