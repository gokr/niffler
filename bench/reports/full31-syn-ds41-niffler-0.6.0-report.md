# bench report — full31-syn-ds41-niffler-0.6.0

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| syn-deepseek-v41 | niffler | t01-roman | pass | 7.5 | 1 | 4 | 15.9k | 4.4k | 0.4k | 11.1k/0.0k | 0.0058 | 0.0019 | 19/1 |
| syn-deepseek-v41 | niffler | t02-jsonrepair | pass | 13.2 | 1 | 5 | 23.7k | 3.9k | 1.4k | 18.4k/0.0k | 0.0077 | 0.0029 | 98/1 |
| syn-deepseek-v41 | niffler | t03-ringbuffer | pass | 22.8 | 1 | 5 | 22.1k | 2.8k | 0.8k | 18.4k/0.0k | 0.0062 | 0.0019 | 19/4 |
| syn-deepseek-v41 | niffler | t04-csvbugfix | pass | 8.0 | 1 | 5 | 21.1k | 2.3k | 0.5k | 18.3k/0.0k | 0.0054 | 0.0014 | 3/3 |
| syn-deepseek-v41 | niffler | t05-todostore | pass | 12.8 | 1 | 5 | 22.5k | 3.3k | 0.7k | 18.4k/0.0k | 0.0065 | 0.0020 | 19/4 |
| syn-deepseek-v41 | niffler | t06-stackvm | pass | 43.5 | 1 | 8 | 85.8k | 18.4k | 5.2k | 62.2k/0.0k | 0.0309 | 0.0121 | 171/57 |
| syn-deepseek-v41 | niffler | t07-validate | pass | 18.7 | 1 | 6 | 33.5k | 6.1k | 1.5k | 25.9k/0.0k | 0.0109 | 0.0038 | 10/5 |
| syn-deepseek-v41 | niffler | t08-logsum | pass | 27.0 | 1 | 12 | 72.3k | 7.6k | 2.5k | 62.2k/0.0k | 0.0190 | 0.0056 | 73/3 |
| syn-deepseek-v41 | niffler | t09-poolrace | pass | 18.0 | 1 | 6 | 31.8k | 5.3k | 1.2k | 25.2k/0.0k | 0.0098 | 0.0032 | 6/1 |
| syn-deepseek-v41 | niffler | t10-iniparse | pass | 14.2 | 1 | 5 | 23.0k | 3.0k | 0.8k | 19.2k/0.0k | 0.0064 | 0.0019 | 7/6 |
| syn-deepseek-v41 | niffler | t11-asyncbugs | pass | 8.2 | 1 | 4 | 17.6k | 2.5k | 0.7k | 14.3k/0.0k | 0.0052 | 0.0017 | 6/11 |
| syn-deepseek-v41 | niffler | t12-refactor | pass | 7.7 | 1 | 5 | 22.3k | 3.1k | 0.6k | 18.6k/0.0k | 0.0062 | 0.0018 | 2/4 |
| syn-deepseek-v41 | niffler | t13-batchrename | pass | 8.1 | 1 | 5 | 27.2k | 5.2k | 0.6k | 21.4k/0.0k | 0.0083 | 0.0024 | 27/27 |
| syn-deepseek-v41 | niffler | t14-todosweep | pass | 16.1 | 1 | 6 | 29.7k | 4.3k | 1.4k | 23.9k/0.0k | 0.0090 | 0.0032 | 18/0 |
| syn-deepseek-v41 | niffler | t15-pollstats | pass | 15.8 | 1 | 6 | 26.1k | 2.6k | 0.8k | 22.8k/0.0k | 0.0066 | 0.0018 | 1/0 |
| syn-deepseek-v41 | niffler | t16-apisum | pass | 18.7 | 1 | 8 | 41.5k | 5.9k | 1.7k | 33.9k/0.0k | 0.0122 | 0.0040 | 23/0 |
| syn-deepseek-v41 | niffler | t17-doccheck | pass | 107.5 | 1 | 26 | 295.3k | 31.8k | 12.2k | 251.3k/0.0k | 0.0803 | 0.0257 | 204/0 |
| syn-deepseek-v41 | niffler | t18-lruttl | pass | 20.2 | 1 | 6 | 35.4k | 5.9k | 1.7k | 27.8k/0.0k | 0.0112 | 0.0040 | 99/12 |
| syn-deepseek-v41 | niffler | t19-tokbucket | pass | 8.4 | 1 | 4 | 19.2k | 3.4k | 0.7k | 15.1k/0.0k | 0.0059 | 0.0019 | 26/8 |
| syn-deepseek-v41 | niffler | t20-jsonpatch | pass | 39.5 | 1 | 9 | 81.4k | 14.2k | 4.7k | 62.5k/0.0k | 0.0270 | 0.0103 | 232/13 |
| syn-deepseek-v41 | niffler | t21-wireproto | pass | 21.0 | 1 | 5 | 29.3k | 6.0k | 1.9k | 21.4k/0.0k | 0.0105 | 0.0042 | 62/8 |
| syn-deepseek-v41 | niffler | t22-cronnext | pass | 22.8 | 1 | 5 | 33.0k | 8.0k | 2.7k | 22.4k/0.0k | 0.0132 | 0.0057 | 107/12 |
| syn-deepseek-v41 | niffler | t23-mergesched | pass | 21.0 | 1 | 5 | 27.3k | 5.5k | 2.3k | 19.6k/0.0k | 0.0102 | 0.0045 | 72/4 |
| syn-deepseek-v41 | niffler | t24-editops | pass | 44.1 | 1 | 9 | 65.9k | 11.6k | 5.2k | 49.2k/0.0k | 0.0234 | 0.0100 | 107/11 |
| syn-deepseek-v41 | niffler | t25-shardmap | pass | 21.6 | 1 | 6 | 33.7k | 5.4k | 1.4k | 26.9k/0.0k | 0.0104 | 0.0035 | 92/16 |
| syn-deepseek-v41 | niffler | t26-logfilter | pass | 35.6 | 1 | 5 | 33.3k | 12.0k | 4.1k | 17.2k/0.0k | 0.0173 | 0.0086 | 257/4 |
| syn-deepseek-v41 | niffler | t27-tarpeek | pass | 35.3 | 1 | 8 | 58.6k | 13.3k | 2.9k | 42.4k/0.0k | 0.0209 | 0.0077 | 96/1 |
| syn-deepseek-v41 | niffler | t28-docbackfill | pass | 16.5 | 1 | 6 | 32.2k | 5.3k | 0.9k | 26.0k/0.0k | 0.0095 | 0.0028 | 18/9 |
| syn-deepseek-v41 | niffler | t29-logrollup | pass | 136.4 | 1 | 6 | 29.9k | 3.7k | 0.8k | 25.3k/0.0k | 0.0080 | 0.0023 | 436/0 |
| syn-deepseek-v41 | niffler | t30-ifacedrift | pass | 39.8 | 1 | 10 | 109.7k | 21.1k | 4.5k | 84.1k/0.0k | 0.0357 | 0.0122 | 48/48 |
| syn-deepseek-v41 | niffler | t31-tinyrename | pass | 10.2 | 1 | 5 | 25.4k | 5.4k | 0.9k | 19.1k/0.0k | 0.0084 | 0.0028 | 6/6 |

*Lane: Synthetic `syn-deepseek-v41`, low effort, one round, jobs-1, 2026-11-25. Six cells (t26–t31) were invalidated by a DNS outage mid-run and re-run on a healthy network; every task in this file is a clean-network result.*
