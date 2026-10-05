# bench report — full31-maki-low

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| deepseek-v4-flash | maki | t01-roman | pass | 6.7 | 1 | 4 | 32.7k | 7.9k | 435 | 24.3k/0 | 0.0030 | 0.0030 | 19/1 |
| deepseek-v4-flash | maki | t02-jsonrepair | pass | 9.4 | 1 | 6 | 52.6k | 8.6k | 1.1k | 42.9k/0 | 0.0042 | 0.0042 | 63/1 |
| deepseek-v4-flash | maki | t03-ringbuffer | pass | 11.5 | 1 | 5 | 43.2k | 8.3k | 784 | 34.2k/0 | 0.0036 | 0.0036 | 17/4 |
| deepseek-v4-flash | maki | t04-csvbugfix | pass | 10 | 1 | 7 | 61.2k | 8.9k | 728 | 51.6k/0 | 0.0038 | 0.0038 | 3/3 |
| deepseek-v4-flash | maki | t05-todostore | pass | 8 | 1 | 5 | 43.6k | 8.5k | 775 | 34.3k/0 | 0.0037 | 0.0037 | 18/4 |
| deepseek-v4-flash | maki | t06-stackvm | pass | 13.4 | 1 | 5 | 66.0k | 13.4k | 3.0k | 49.5k/0 | 0.0079 | 0.0079 | 143/32 |
| deepseek-v4-flash | maki | t07-validate | pass | 8 | 1 | 5 | 48.3k | 9.6k | 1.0k | 37.6k/0 | 0.0043 | 0.0043 | 12/5 |
| deepseek-v4-flash | maki | t08-logsum | pass | 16.2 | 1 | 9 | 91.4k | 9.9k | 2.1k | 79.4k/0 | 0.0059 | 0.0059 | 60/2 |
| deepseek-v4-flash | maki | t09-poolrace | pass | 9.8 | 1 | 5 | 43.3k | 8.4k | 968 | 33.9k/0 | 0.0039 | 0.0039 | 8/4 |
| deepseek-v4-flash | maki | t10-iniparse | pass | 18.1 | 1 | 6 | 57.1k | 9.6k | 1.1k | 46.3k/0 | 0.0045 | 0.0045 | 6/5 |
| deepseek-v4-flash | maki | t11-asyncbugs | pass | 13.8 | 1 | 9 | 91.4k | 11.0k | 1.5k | 78.8k/0 | 0.0056 | 0.0056 | 5/10 |
| deepseek-v4-flash | maki | t12-refactor | pass | 9 | 1 | 5 | 44.1k | 8.7k | 954 | 34.4k/0 | 0.0040 | 0.0040 | 2/4 |
| deepseek-v4-flash | maki | t13-batchrename | pass | 6.8 | 1 | 4 | 33.5k | 8.2k | 339 | 25.0k/0 | 0.0030 | 0.0030 | 27/27 |
| deepseek-v4-flash | maki | t14-todosweep | pass | 6.4 | 1 | 4 | 34.9k | 8.5k | 420 | 26.0k/0 | 0.0032 | 0.0032 | 18/0 |
| deepseek-v4-flash | maki | t15-pollstats | pass | 7.5 | 1 | 4 | 33.9k | 8.1k | 536 | 25.3k/0 | 0.0032 | 0.0032 | 1/0 |
| deepseek-v4-flash | maki | t16-apisum | pass | 8.6 | 1 | 5 | 43.0k | 8.4k | 572 | 34.0k/0 | 0.0034 | 0.0034 | 22/0 |
| deepseek-v4-flash | maki | t17-doccheck | pass | 9.1 | 1 | 6 | 52.9k | 8.6k | 949 | 43.4k/0 | 0.0040 | 0.0040 | 45/0 |
| deepseek-v4-flash | maki | t18-lruttl | pass | 11.3 | 1 | 6 | 64.9k | 10.4k | 1.9k | 52.6k/0 | 0.0057 | 0.0057 | 139/11 |
| deepseek-v4-flash | maki | t19-tokbucket | pass | 8.4 | 1 | 5 | 46.4k | 8.7k | 1.4k | 36.2k/0 | 0.0045 | 0.0045 | 27/10 |
| deepseek-v4-flash | maki | t20-jsonpatch | pass | 21.9 | 1 | 9 | 113.7k | 12.0k | 4.3k | 97.4k/0 | 0.0093 | 0.0093 | 231/13 |
| deepseek-v4-flash | maki | t21-wireproto | pass | 8.8 | 1 | 4 | 42.7k | 10.2k | 1.4k | 31.1k/0 | 0.0049 | 0.0049 | 62/8 |
| deepseek-v4-flash | maki | t22-cronnext | pass | 17.6 | 1 | 7 | 88.2k | 12.2k | 3.3k | 72.6k/0 | 0.0081 | 0.0081 | 200/16 |
| deepseek-v4-flash | maki | t23-mergesched | pass | 9.3 | 1 | 5 | 48.3k | 9.4k | 1.4k | 37.5k/0 | 0.0047 | 0.0047 | 65/4 |
| deepseek-v4-flash | maki | t24-editops | pass | 13.3 | 1 | 7 | 72.2k | 10.2k | 2.2k | 59.8k/0 | 0.0061 | 0.0061 | 101/11 |
| deepseek-v4-flash | maki | t25-shardmap | pass | 11.2 | 1 | 5 | 51.6k | 9.9k | 1.7k | 40.1k/0 | 0.0052 | 0.0052 | 80/16 |
| deepseek-v4-flash | maki | t26-logfilter | pass | 13.4 | 1 | 6 | 61.3k | 11.8k | 2.5k | 47.0k/0 | 0.0068 | 0.0068 | 257/4 |
| deepseek-v4-flash | maki | t27-tarpeek | pass | 49.7 | 1 | 24 | 325.2k | 14.7k | 3.8k | 306.7k/0 | 0.0108 | 0.0108 | 82/1 |
| deepseek-v4-flash | maki | t28-docbackfill | pass | 15.1 | 1 | 8 | 78.8k | 9.9k | 1.6k | 67.3k/0 | 0.0053 | 0.0053 | 18/9 |
| deepseek-v4-flash | maki | t29-logrollup | pass | 5.4 | 1 | 3 | 26.7k | 8.7k | 480 | 17.5k/0 | 0.0033 | 0.0033 | 436/0 |
| deepseek-v4-flash | maki | t30-ifacedrift | pass | 8.7 | 1 | 6 | 55.7k | 9.6k | 798 | 45.3k/0 | 0.0041 | 0.0041 | 48/48 |
| deepseek-v4-flash | maki | t31-tinyrename | pass | 8.7 | 1 | 5 | 46.4k | 8.9k | 1.2k | 36.2k/0 | 0.0044 | 0.0044 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | maki | 31/31 | 6.3 | 12 | 64.4k | 9.7k | 53.2k | 1.5k | 0.1547 | 0.1547 | 72/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*

## Run provenance and interpretation

- Fresh solo-lane run on 2026-10-05: `node bench/run.mjs --harness maki --model deepseek-v4-flash --task all --rounds 1 --jobs 2 --thinking low --run-id full31-maki-low`. First-party `https://api.deepseek.com/v1`, **no LLM Gateway**; 31 results, all `pass`, no invalid/leak/error cells.
- Maki pinned at `e6fc72a4` (`v0.6.0` + 5, `main` at run time), built from `~/git/harnesses/maki` with `cargo build --release`. Model spec `deepseek/deepseek-v4-flash`; driven via `maki --print --output-format stream-json --yolo --trust` (Claude-Code-compatible stream; `--resume <session_id>` continues feedback rounds — none needed here).
- Usage and tool-call counts come from the stream itself: `assistant`/`result` `usage` blocks (input/output plus `cache_read_input_tokens`/`cache_creation_input_tokens`) and `system/init`'s tool inventory. `shape.tools` records actual calls: read 98, bash 70, list 25, edit 17, write 15, multiedit 6, code_execution 8, edit_lines 5, index 2, batch 2, grep 1 — Maki's 18-tool surface.
- Solo lane caveat: same two concurrent cells as the paired runs, so wall-times are comparable across lanes; per-lane API contention is slightly lower than in paired scheduling. `firstPromptTokens` is not captured for this lane.
- Effort caveat: `thinking low` has no Maki spelling (its CLI exposes `--max-thinking-tokens`, not effort levels), so this lane ran with Maki's default thinking configuration — not effort-matched to the low lanes. Its speed lead (12.1s avg vs Niffler 18.7s / DSH-sdk 17.9s) holds under that caveat; token volume (301k uncached + 1.65M cache-read + 45k out) sits between the other lanes.
