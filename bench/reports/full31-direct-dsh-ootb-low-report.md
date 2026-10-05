# bench report — full31-direct-dsh-ootb-low

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | dsh | t01-roman | pass | 9.4 | 1 | 6 | 40.9k | 6.8k | 740 | 33.4k/0 | 0.0031 | 0.0031 | 13/1 |
| deepseek-v4-flash | dsh | t02-jsonrepair | pass | 22.4 | 1 | 8 | 69.1k | 7.5k | 3.7k | 57.9k/0 | 0.0070 | 0.0070 | 72/1 |
| deepseek-v4-flash | dsh | t03-ringbuffer | pass | 15 | 1 | 7 | 52.9k | 7.4k | 1.4k | 44.0k/0 | 0.0042 | 0.0042 | 19/4 |
| deepseek-v4-flash | dsh | t04-csvbugfix | pass | 7.8 | 1 | 5 | 34.1k | 6.6k | 616 | 26.9k/0 | 0.0029 | 0.0029 | 3/3 |
| deepseek-v4-flash | dsh | t05-todostore | pass | 8.9 | 1 | 5 | 36.3k | 7.3k | 814 | 28.2k/0 | 0.0033 | 0.0033 | 21/4 |
| deepseek-v4-flash | dsh | t06-stackvm | pass | 35.2 | 1 | 6 | 93.2k | 12.3k | 8.1k | 72.8k/0 | 0.0138 | 0.0138 | 160/62 |
| deepseek-v4-flash | dsh | t07-validate | pass | 11.1 | 1 | 6 | 50.5k | 8.5k | 1.3k | 40.7k/0 | 0.0043 | 0.0043 | 17/7 |
| deepseek-v4-flash | dsh | t08-logsum | pass | 12.3 | 1 | 5 | 41.2k | 7.9k | 1.8k | 31.5k/0 | 0.0047 | 0.0047 | 72/2 |
| deepseek-v4-flash | dsh | t09-poolrace | pass | 15.9 | 1 | 7 | 52.5k | 7.1k | 1.4k | 43.9k/0 | 0.0041 | 0.0041 | 6/1 |
| deepseek-v4-flash | dsh | t10-iniparse | pass | 14.8 | 1 | 5 | 38.4k | 7.5k | 1.3k | 29.6k/0 | 0.0040 | 0.0040 | 6/5 |
| deepseek-v4-flash | dsh | t11-asyncbugs | pass | 17.1 | 1 | 10 | 82.1k | 8.5k | 1.9k | 71.7k/0 | 0.0053 | 0.0053 | 7/6 |
| deepseek-v4-flash | dsh | t12-refactor | pass | 9 | 1 | 5 | 35.5k | 7.0k | 844 | 27.6k/0 | 0.0033 | 0.0033 | 2/4 |
| deepseek-v4-flash | dsh | t13-batchrename | pass | 7.2 | 1 | 4 | 28.7k | 7.5k | 440 | 20.7k/0 | 0.0029 | 0.0029 | 27/27 |
| deepseek-v4-flash | dsh | t14-todosweep | pass | 12.4 | 1 | 6 | 47.3k | 7.8k | 1.4k | 38.0k/0 | 0.0043 | 0.0043 | 18/0 |
| deepseek-v4-flash | dsh | t15-pollstats | pass | 9.7 | 1 | 3 | 22.6k | 6.8k | 1.5k | 14.3k/0 | 0.0039 | 0.0039 | 1/0 |
| deepseek-v4-flash | dsh | t16-apisum | pass | 9.9 | 1 | 5 | 35.3k | 7.2k | 618 | 27.5k/0 | 0.0031 | 0.0031 | 22/0 |
| deepseek-v4-flash | dsh | t17-doccheck | pass | 36 | 1 | 12 | 142.2k | 9.8k | 6.1k | 126.2k/0 | 0.0111 | 0.0111 | 137/0 |
| deepseek-v4-flash | dsh | t18-lruttl | pass | 15.7 | 1 | 6 | 58.1k | 8.7k | 2.7k | 46.7k/0 | 0.0061 | 0.0061 | 96/12 |
| deepseek-v4-flash | dsh | t19-tokbucket | pass | 13.1 | 1 | 7 | 61.0k | 9.0k | 1.8k | 50.2k/0 | 0.0052 | 0.0052 | 26/11 |
| deepseek-v4-flash | dsh | t20-jsonpatch | pass | 28.8 | 1 | 5 | 57.9k | 9.6k | 6.1k | 42.2k/0 | 0.0104 | 0.0104 | 185/13 |
| deepseek-v4-flash | dsh | t21-wireproto | pass | 18.6 | 1 | 6 | 63.6k | 8.9k | 3.7k | 51.1k/0 | 0.0074 | 0.0074 | 65/8 |
| deepseek-v4-flash | dsh | t22-cronnext | pass | 30 | 1 | 7 | 83.4k | 9.9k | 5.8k | 67.6k/0 | 0.0104 | 0.0104 | 114/16 |
| deepseek-v4-flash | dsh | t23-mergesched | pass | 17.8 | 1 | 7 | 62.6k | 8.3k | 2.6k | 51.7k/0 | 0.0060 | 0.0060 | 78/4 |
| deepseek-v4-flash | dsh | t24-editops | pass | 25.9 | 1 | 7 | 71.4k | 9.2k | 4.5k | 57.7k/0 | 0.0085 | 0.0085 | 111/6 |
| deepseek-v4-flash | dsh | t25-shardmap | pass | 15.9 | 1 | 6 | 55.8k | 8.7k | 2.3k | 44.8k/0 | 0.0057 | 0.0057 | 82/16 |
| deepseek-v4-flash | dsh | t26-logfilter | pass | 40.2 | 1 | 6 | 73.7k | 8.4k | 8.8k | 56.4k/0 | 0.0134 | 0.0134 | 240/4 |
| deepseek-v4-flash | dsh | t27-tarpeek | pass | 46.9 | 1 | 7 | 90.0k | 9.5k | 8.1k | 72.3k/0 | 0.0130 | 0.0130 | 75/1 |
| deepseek-v4-flash | dsh | t28-docbackfill | pass | 16 | 1 | 7 | 57.9k | 8.3k | 1.5k | 48.1k/0 | 0.0045 | 0.0045 | 18/9 |
| deepseek-v4-flash | dsh | t29-logrollup | pass | 6.3 | 1 | 3 | 20.5k | 6.8k | 517 | 13.2k/0 | 0.0027 | 0.0027 | 436/0 |
| deepseek-v4-flash | dsh | t30-ifacedrift | pass | 12.6 | 1 | 6 | 58.1k | 11.2k | 1.0k | 46.0k/0 | 0.0048 | 0.0048 | 48/48 |
| deepseek-v4-flash | dsh | t31-tinyrename | pass | 12.4 | 1 | 5 | 39.6k | 8.0k | 1.4k | 30.2k/0 | 0.0043 | 0.0043 | 6/6 |
| deepseek-v4-flash | niffler | t01-roman | pass | 4.1 | 1 | 3 | 8.0k | 2.6k | 394 | 5.0k/0 | 0.0013 | 0.0013 | 19/1 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 16.6 | 1 | 5 | 26.1k | 3.1k | 3.0k | 20.0k/0 | 0.0047 | 0.0047 | 102/1 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 9.4 | 1 | 4 | 16.8k | 2.2k | 770 | 13.8k/0 | 0.0017 | 0.0017 | 16/4 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 7.7 | 1 | 5 | 19.4k | 2.0k | 618 | 16.8k/0 | 0.0014 | 0.0014 | 3/3 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 9.1 | 1 | 5 | 20.4k | 2.5k | 635 | 17.3k/0 | 0.0016 | 0.0016 | 18/4 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 31.4 | 1 | 7 | 79.1k | 7.3k | 6.4k | 65.4k/0 | 0.0102 | 0.0102 | 188/46 |
| deepseek-v4-flash | niffler | t07-validate | pass | 10.3 | 1 | 5 | 26.7k | 4.2k | 1.1k | 21.4k/0 | 0.0027 | 0.0027 | 6/6 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 22.4 | 1 | 10 | 58.7k | 4.0k | 2.7k | 52.0k/0 | 0.0048 | 0.0048 | 71/3 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 9.2 | 1 | 4 | 15.5k | 1.7k | 697 | 13.1k/0 | 0.0014 | 0.0014 | 5/1 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 14.6 | 1 | 5 | 21.8k | 2.4k | 1.0k | 18.4k/0 | 0.0020 | 0.0020 | 7/6 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 10.6 | 1 | 5 | 22.6k | 3.1k | 1.0k | 18.4k/0 | 0.0023 | 0.0023 | 5/10 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 8 | 1 | 5 | 19.7k | 2.2k | 542 | 16.9k/0 | 0.0014 | 0.0014 | 2/4 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 6.4 | 1 | 5 | 22.7k | 3.0k | 479 | 19.2k/0 | 0.0016 | 0.0016 | 27/27 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 12.6 | 1 | 6 | 28.1k | 2.6k | 1.4k | 24.1k/0 | 0.0026 | 0.0026 | 18/0 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 14 | 1 | 8 | 54.5k | 7.3k | 1.3k | 46.0k/0 | 0.0040 | 0.0040 | 1/0 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 16.6 | 1 | 7 | 31.7k | 3.4k | 765 | 27.5k/0 | 0.0021 | 0.0021 | 18/0 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 20.1 | 1 | 10 | 52.7k | 3.3k | 2.0k | 47.4k/0 | 0.0037 | 0.0037 | 131/0 |
| deepseek-v4-flash | niffler | t18-lruttl | pass | 13.8 | 1 | 5 | 28.2k | 3.6k | 2.0k | 22.7k/0 | 0.0036 | 0.0036 | 100/12 |
| deepseek-v4-flash | niffler | t19-tokbucket | pass | 11 | 1 | 5 | 25.1k | 3.5k | 1.3k | 20.4k/0 | 0.0027 | 0.0027 | 25/11 |
| deepseek-v4-flash | niffler | t20-jsonpatch | pass | 37.7 | 1 | 8 | 77.6k | 4.8k | 7.8k | 65.0k/0 | 0.0112 | 0.0112 | 241/13 |
| deepseek-v4-flash | niffler | t21-wireproto | pass | 15 | 1 | 4 | 27.5k | 3.6k | 2.8k | 21.1k/0 | 0.0046 | 0.0046 | 63/8 |
| deepseek-v4-flash | niffler | t22-cronnext | pass | 22.4 | 1 | 5 | 35.2k | 4.3k | 3.6k | 27.3k/0 | 0.0057 | 0.0057 | 113/16 |
| deepseek-v4-flash | niffler | t23-mergesched | pass | 16.7 | 1 | 4 | 23.8k | 2.7k | 2.5k | 18.7k/0 | 0.0039 | 0.0039 | 76/4 |
| deepseek-v4-flash | niffler | t24-editops | pass | 31.6 | 1 | 9 | 75.7k | 5.1k | 5.2k | 65.4k/0 | 0.0081 | 0.0081 | 96/11 |
| deepseek-v4-flash | niffler | t25-shardmap | pass | 16.9 | 1 | 5 | 25.7k | 3.4k | 1.3k | 21.0k/0 | 0.0027 | 0.0027 | 78/16 |
| deepseek-v4-flash | niffler | t26-logfilter | pass | 39.5 | 1 | 7 | 62.1k | 3.8k | 8.1k | 50.2k/0 | 0.0112 | 0.0112 | 257/4 |
| deepseek-v4-flash | niffler | t27-tarpeek | pass | 40.4 | 1 | 12 | 86.0k | 4.7k | 5.1k | 76.2k/0 | 0.0080 | 0.0080 | 71/1 |
| deepseek-v4-flash | niffler | t28-docbackfill | pass | 67 | 1 | 10 | 102.9k | 13.2k | 4.0k | 85.8k/0 | 0.0092 | 0.0092 | 18/9 |
| deepseek-v4-flash | niffler | t29-logrollup | pass | 9.2 | 1 | 6 | 25.7k | 2.7k | 765 | 22.3k/0 | 0.0019 | 0.0019 | 436/0 |
| deepseek-v4-flash | niffler | t30-ifacedrift | pass | 12.1 | 1 | 5 | 32.7k | 6.2k | 741 | 25.7k/0 | 0.0029 | 0.0029 | 48/48 |
| deepseek-v4-flash | niffler | t31-tinyrename | pass | 22.3 | 1 | 8 | 39.8k | 3.9k | 826 | 35.1k/0 | 0.0024 | 0.0024 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | dsh | 31/31 | 6.1 | 18 | 56.7k | 8.3k | 45.6k | 2.7k | 0.1878 | 0.1878 | 70/9 |
| deepseek-v4-flash | niffler | 31/31 | 6.2 | 19 | 38.5k | 4.0k | 32.2k | 2.3k | 0.1277 | 0.1277 | 73/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*

## Run provenance and interpretation

- Fresh paired run on 2026-10-05 (second of the day): `node bench/run.mjs --harness niffler,dsh --model deepseek-v4-flash --task all --rounds 1 --jobs 2 --thinking low --run-id full31-direct-dsh-ootb-low`. Both lanes used `https://api.deepseek.com/v1`, `deepseek-v4-flash` (serving V4.1 Flash); **no LLM Gateway**. One verification round per task over the 31-task suite: 31 results per lane, no invalid, leak, or error cells — a clean sweep on both.
- DSH: `dsh-v0.2.1-alpha.1` (`5badb15009`) with the **`sdk` profile: the out-of-the-box `dsh-base` tool surface** (fs read/edit/write, bash, fs-search/glob, skills, web, subagent) driven over SDK JSON-RPC. The interactive `tui`/`web` defaults cannot be driven programmatically; `sdk` is their tool-surface twin. Native effort `low`.
- Niffler: same tree and protocol as `full31-direct-dsh-low` (built from this worktree; per-combo isolated bus/root; `AGENTS.md`/`AGENTS.local.md` excluded from the bench root).
- Compare with `full31-direct-dsh-low` (same day, same suite, DSH on the `sdk-minimal` bash-only profile): there DSH averaged 35s and $0.2687 with long reasoning-heavy rewrites (t20 155s, t26 122s); on its shipped surface it averages 18s with comparable turns/tool-calls to Niffler. The earlier gap was mostly tool-surface, not model behavior — hence this run as the primary DSH comparison.
- The token split still favors Niffler: first prompt averages 2,637 vs 5,675 tokens (`sdk` mounts the full tool schema set), and the suite runs at roughly half the input/cache volume. Times and costs remain descriptive per-cell aggregates.
- Leak-guard caveat for this profile: the bench detector knows `fetch`, bash `curl`/`wget`/`git fetch`; DSH's `tool-web` call names are not covered. No web tool calls appear in any cell's `shape.tools`, and the tasks require in-repo work, so no leak is indicated — but the detector is less sensitive on the out-of-the-box profile.
