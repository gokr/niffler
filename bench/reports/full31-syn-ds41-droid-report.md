# bench report — full31-syn-ds41-droid

| model | harness | task | verdict | time (s) | rounds | turns | tok total | uncached in | tok out | cache r/w | cost $ | official $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|
| syn-deepseek-v41 | droid | t01-roman | pass | 10.4 | 1 | 1 | 45.1k | 1.4k | 626 | 43.1k/0 | 0.0088 | 0.0014 | 15/1 |
| syn-deepseek-v41 | droid | t02-jsonrepair | pass | 36 | 1 | 3 | 64.9k | 2.7k | 3.0k | 59.1k/0 | 0.0153 | 0.0048 | 101/1 |
| syn-deepseek-v41 | droid | t03-ringbuffer | pass | 21.2 | 1 | 1 | 72.9k | 2.6k | 1.5k | 68.7k/0 | 0.0149 | 0.0030 | 16/4 |
| syn-deepseek-v41 | droid | t04-csvbugfix | pass | 14.7 | 1 | 1 | 71.9k | 2.2k | 1.1k | 68.6k/0 | 0.0140 | 0.0023 | 3/3 |
| syn-deepseek-v41 | droid | t05-todostore | pass | 16.4 | 1 | 1 | 72.8k | 2.4k | 1.2k | 69.2k/0 | 0.0144 | 0.0026 | 16/4 |
| syn-deepseek-v41 | droid | t06-stackvm | pass | 95.7 | 1 | 3 | 131.3k | 7.8k | 8.4k | 115.1k/0 | 0.0348 | 0.0131 | 158/42 |
| syn-deepseek-v41 | droid | t07-validate | pass | 25.3 | 1 | 3 | 80.8k | 4.5k | 2.0k | 74.2k/0 | 0.0179 | 0.0042 | 16/8 |
| syn-deepseek-v41 | droid | t08-logsum | pass | 39.4 | 1 | 3 | 138.5k | 4.0k | 3.1k | 131.3k/0 | 0.0280 | 0.0057 | 73/4 |
| syn-deepseek-v41 | droid | t09-poolrace | pass | 17.4 | 1 | 1 | 47.0k | 1.9k | 1.0k | 44.2k/0 | 0.0098 | 0.0021 | 7/4 |
| syn-deepseek-v41 | droid | t10-iniparse | pass | 22.5 | 1 | 2 | 60.6k | 2.9k | 1.3k | 56.4k/0 | 0.0129 | 0.0027 | 6/5 |
| syn-deepseek-v41 | droid | t11-asyncbugs | pass | 21 | 1 | 3 | 86.1k | 3.4k | 1.7k | 81.0k/0 | 0.0177 | 0.0035 | 5/10 |
| syn-deepseek-v41 | droid | t12-refactor | pass | 14.9 | 1 | 3 | 59.7k | 2.7k | 955 | 56.1k/0 | 0.0123 | 0.0023 | 2/4 |
| syn-deepseek-v41 | droid | t13-batchrename | pass | 12.3 | 1 | 1 | 59.5k | 2.5k | 749 | 56.2k/0 | 0.0119 | 0.0020 | 27/27 |
| syn-deepseek-v41 | droid | t14-todosweep | pass | 21 | 1 | 1 | 73.2k | 1.9k | 1.3k | 70.0k/0 | 0.0143 | 0.0025 | 18/0 |
| syn-deepseek-v41 | droid | t15-pollstats | pass | 14.8 | 1 | 2 | 58.6k | 1.6k | 1.0k | 55.9k/0 | 0.0115 | 0.0020 | 1/0 |
| syn-deepseek-v41 | droid | t16-apisum | pass | 15 | 1 | 1 | 46.3k | 1.4k | 736 | 44.2k/0 | 0.0091 | 0.0016 | 24/0 |
| syn-deepseek-v41 | droid | t17-doccheck | pass | 46.5 | 1 | 2 | 97.5k | 2.8k | 4.0k | 90.8k/0 | 0.0215 | 0.0061 | 90/0 |
| syn-deepseek-v41 | droid | t18-lruttl | pass | 28 | 1 | 3 | 54.0k | 4.7k | 2.0k | 47.4k/0 | 0.0137 | 0.0040 | 123/12 |
| syn-deepseek-v41 | droid | t19-tokbucket | pass | 19.6 | 1 | 2 | 51.2k | 2.9k | 1.3k | 47.0k/0 | 0.0114 | 0.0028 | 26/11 |
| syn-deepseek-v41 | droid | t20-jsonpatch | pass | 53.6 | 1 | 3 | 74.0k | 5.9k | 4.7k | 63.4k/0 | 0.0206 | 0.0078 | 209/19 |
| syn-deepseek-v41 | droid | t21-wireproto | pass | 31.8 | 1 | 1 | 56.7k | 3.6k | 2.7k | 50.4k/0 | 0.0141 | 0.0046 | 64/8 |
| syn-deepseek-v41 | droid | t22-cronnext | pass | 48 | 1 | 2 | 62.8k | 5.2k | 4.2k | 53.4k/0 | 0.0177 | 0.0069 | 93/17 |
| syn-deepseek-v41 | droid | t23-mergesched | pass | 30.4 | 1 | 1 | 53.5k | 2.7k | 2.4k | 48.4k/0 | 0.0128 | 0.0040 | 78/4 |
| syn-deepseek-v41 | droid | t24-editops | pass | 42.1 | 1 | 1 | 84.6k | 3.2k | 3.5k | 78.0k/0 | 0.0192 | 0.0056 | 109/14 |
| syn-deepseek-v41 | droid | t25-shardmap | pass | 21 | 1 | 3 | 51.9k | 3.8k | 1.5k | 46.6k/0 | 0.0123 | 0.0032 | 83/16 |
| syn-deepseek-v41 | droid | t26-logfilter | pass | 76.3 | 1 | 2 | 67.8k | 4.5k | 6.9k | 56.4k/0 | 0.0209 | 0.0099 | 220/4 |
| syn-deepseek-v41 | droid | t27-tarpeek | pass | 76.4 | 1 | 1 | 143.6k | 7.9k | 6.5k | 129.2k/0 | 0.0349 | 0.0110 | 84/1 |
| syn-deepseek-v41 | droid | t28-docbackfill | pass | 16.5 | 1 | 1 | 61.6k | 2.3k | 1.2k | 58.1k/0 | 0.0125 | 0.0024 | 18/9 |
| syn-deepseek-v41 | droid | t29-logrollup | pass | 11.7 | 1 | 1 | 37.3k | 2.5k | 780 | 34.0k/0 | 0.0084 | 0.0019 | 436/0 |
| syn-deepseek-v41 | droid | t30-ifacedrift | pass | 19 | 1 | 4 | 87.7k | 6.3k | 1.5k | 79.9k/0 | 0.0197 | 0.0042 | 48/48 |
| syn-deepseek-v41 | droid | t31-tinyrename | pass | 17.9 | 1 | 1 | 60.5k | 2.5k | 1.3k | 56.7k/0 | 0.0126 | 0.0026 | 6/6 |
| syn-deepseek-v41 | niffler | t01-roman | pass | 7.7 | 1 | 5 | 19.8k | 4.7k | 458 | 14.6k/0 | 0.0067 | 0.0021 | 15/1 |
| syn-deepseek-v41 | niffler | t02-jsonrepair | pass | 19.3 | 1 | 6 | 28.4k | 3.8k | 1.7k | 22.9k/0 | 0.0087 | 0.0033 | 106/1 |
| syn-deepseek-v41 | niffler | t03-ringbuffer | pass | 13.1 | 1 | 5 | 22.1k | 3.0k | 862 | 18.2k/0 | 0.0064 | 0.0021 | 17/4 |
| syn-deepseek-v41 | niffler | t04-csvbugfix | pass | 7.5 | 1 | 5 | 21.0k | 2.3k | 613 | 18.0k/0 | 0.0055 | 0.0015 | 3/3 |
| syn-deepseek-v41 | niffler | t05-todostore | pass | 10.1 | 1 | 5 | 22.3k | 8.1k | 688 | 13.6k/0 | 0.0095 | 0.0033 | 16/4 |
| syn-deepseek-v41 | niffler | t06-stackvm | pass | 68.6 | 1 | 6 | 56.8k | 17.4k | 6.0k | 33.4k/0 | 0.0264 | 0.0126 | 115/13 |
| syn-deepseek-v41 | niffler | t07-validate | pass | 16.3 | 1 | 5 | 28.0k | 5.6k | 1.3k | 21.1k/0 | 0.0094 | 0.0033 | 9/7 |
| syn-deepseek-v41 | niffler | t08-logsum | pass | 24 | 1 | 8 | 43.3k | 5.3k | 2.0k | 36.0k/0 | 0.0124 | 0.0042 | 70/5 |
| syn-deepseek-v41 | niffler | t09-poolrace | pass | 18.1 | 1 | 7 | 32.9k | 4.0k | 1.0k | 27.9k/0 | 0.0088 | 0.0026 | 9/2 |
| syn-deepseek-v41 | niffler | t10-iniparse | pass | 18.9 | 1 | 5 | 25.7k | 5.1k | 928 | 19.7k/0 | 0.0083 | 0.0028 | 6/5 |
| syn-deepseek-v41 | niffler | t11-asyncbugs | pass | 13 | 1 | 6 | 29.7k | 4.2k | 1.0k | 24.4k/0 | 0.0085 | 0.0026 | 5/10 |
| syn-deepseek-v41 | niffler | t12-refactor | pass | 11.9 | 1 | 5 | 21.2k | 3.0k | 620 | 17.5k/0 | 0.0060 | 0.0018 | 2/4 |
| syn-deepseek-v41 | niffler | t13-batchrename | pass | 8.5 | 1 | 5 | 24.2k | 5.6k | 581 | 18.0k/0 | 0.0080 | 0.0025 | 27/27 |
| syn-deepseek-v41 | niffler | t14-todosweep | pass | 21.1 | 1 | 8 | 43.1k | 6.5k | 1.5k | 35.1k/0 | 0.0126 | 0.0040 | 18/0 |
| syn-deepseek-v41 | niffler | t15-pollstats | pass | 6.3 | 1 | 4 | 16.4k | 1.0k | 477 | 14.8k/0 | 0.0038 | 0.0010 | 1/0 |
| syn-deepseek-v41 | niffler | t16-apisum | pass | 25.8 | 1 | 10 | 52.2k | 7.8k | 1.5k | 42.9k/0 | 0.0149 | 0.0044 | 23/0 |
| syn-deepseek-v41 | niffler | t17-doccheck | pass | 103.5 | 1 | 16 | 153.1k | 21.6k | 8.9k | 122.5k/0 | 0.0476 | 0.0179 | 173/0 |
| syn-deepseek-v41 | niffler | t18-lruttl | pass | 26.6 | 1 | 5 | 28.4k | 5.4k | 1.7k | 21.2k/0 | 0.0098 | 0.0038 | 107/12 |
| syn-deepseek-v41 | niffler | t19-tokbucket | pass | 22.8 | 1 | 5 | 29.5k | 5.4k | 1.8k | 22.3k/0 | 0.0101 | 0.0040 | 27/8 |
| syn-deepseek-v41 | niffler | t20-jsonpatch | pass | 54.6 | 1 | 5 | 37.5k | 8.3k | 4.9k | 24.3k/0 | 0.0164 | 0.0086 | 215/13 |
| syn-deepseek-v41 | niffler | t21-wireproto | pass | 40.1 | 1 | 8 | 69.7k | 11.7k | 3.1k | 54.9k/0 | 0.0219 | 0.0076 | 64/8 |
| syn-deepseek-v41 | niffler | t22-cronnext | pass | 46.4 | 1 | 5 | 35.3k | 7.1k | 4.2k | 23.9k/0 | 0.0146 | 0.0074 | 100/17 |
| syn-deepseek-v41 | niffler | t23-mergesched | pass | 26.6 | 1 | 5 | 29.1k | 6.5k | 2.3k | 20.4k/0 | 0.0112 | 0.0048 | 65/4 |
| syn-deepseek-v41 | niffler | t24-editops | pass | 71.6 | 1 | 8 | 59.1k | 10.0k | 6.1k | 43.0k/0 | 0.0222 | 0.0106 | 119/11 |
| syn-deepseek-v41 | niffler | t25-shardmap | pass | 21.7 | 1 | 5 | 26.1k | 3.8k | 1.3k | 21.0k/0 | 0.0079 | 0.0028 | 82/16 |
| syn-deepseek-v41 | niffler | t26-logfilter | pass | 88.7 | 1 | 5 | 41.6k | 8.2k | 8.3k | 25.1k/0 | 0.0205 | 0.0125 | 336/4 |
| syn-deepseek-v41 | niffler | t27-tarpeek | pass | 60.9 | 1 | 14 | 116.8k | 17.1k | 5.1k | 94.6k/0 | 0.0349 | 0.0118 | 72/2 |
| syn-deepseek-v41 | niffler | t28-docbackfill | pass | 28.2 | 1 | 10 | 57.6k | 7.3k | 1.7k | 48.6k/0 | 0.0156 | 0.0045 | 18/9 |
| syn-deepseek-v41 | niffler | t29-logrollup | pass | 9.9 | 1 | 4 | 17.1k | 3.8k | 417 | 12.9k/0 | 0.0056 | 0.0017 | 436/0 |
| syn-deepseek-v41 | niffler | t30-ifacedrift | pass | 13.3 | 1 | 7 | 50.1k | 8.6k | 877 | 40.7k/0 | 0.0144 | 0.0039 | 48/48 |
| syn-deepseek-v41 | niffler | t31-tinyrename | pass | 8.8 | 1 | 5 | 22.7k | 3.9k | 699 | 18.0k/0 | 0.0069 | 0.0021 | 6/6 |
| syn-deepseek-v41 | pi | t01-roman | pass | 5.6 | 1 | 4 | 10.0k | 2.7k | 391 | 6.9k/0 | 0.0037 | 0.0013 | 13/1 |
| syn-deepseek-v41 | pi | t02-jsonrepair | pass | 13.7 | 1 | 5 | 15.1k | 2.2k | 1.3k | 11.6k/0 | 0.0051 | 0.0022 | 76/1 |
| syn-deepseek-v41 | pi | t03-ringbuffer | pass | 11.2 | 1 | 5 | 14.3k | 3.3k | 843 | 10.1k/0 | 0.0053 | 0.0021 | 14/4 |
| syn-deepseek-v41 | pi | t04-csvbugfix | pass | 9.9 | 1 | 5 | 14.5k | 2.2k | 843 | 11.5k/0 | 0.0046 | 0.0017 | 3/3 |
| syn-deepseek-v41 | pi | t05-todostore | pass | 8.3 | 1 | 5 | 15.1k | 2.4k | 800 | 11.9k/0 | 0.0047 | 0.0017 | 16/4 |
| syn-deepseek-v41 | pi | t06-stackvm | pass | 83.3 | 1 | 5 | 45.0k | 8.9k | 7.5k | 28.7k/0 | 0.0207 | 0.0118 | 162/55 |
| syn-deepseek-v41 | pi | t07-validate | pass | 15.5 | 1 | 5 | 14.6k | 2.3k | 1.3k | 11.0k/0 | 0.0051 | 0.0023 | 14/9 |
| syn-deepseek-v41 | pi | t08-logsum | pass | 26.2 | 1 | 8 | 34.2k | 4.0k | 2.3k | 27.9k/0 | 0.0105 | 0.0042 | 68/4 |
| syn-deepseek-v41 | pi | t09-poolrace | pass | 9.5 | 1 | 4 | 11.1k | 1.9k | 714 | 8.4k/0 | 0.0037 | 0.0015 | 7/4 |
| syn-deepseek-v41 | pi | t10-iniparse | pass | 20.1 | 1 | 5 | 17.2k | 3.0k | 1.2k | 12.9k/0 | 0.0060 | 0.0025 | 6/5 |
| syn-deepseek-v41 | pi | t11-asyncbugs | pass | 11.4 | 1 | 5 | 15.8k | 2.6k | 986 | 12.2k/0 | 0.0052 | 0.0020 | 5/10 |
| syn-deepseek-v41 | pi | t12-refactor | pass | 10.3 | 1 | 4 | 12.5k | 2.3k | 897 | 9.3k/0 | 0.0044 | 0.0018 | 2/4 |
| syn-deepseek-v41 | pi | t13-batchrename | pass | 6.2 | 1 | 3 | 11.7k | 4.0k | 364 | 7.3k/0 | 0.0048 | 0.0017 | 27/27 |
| syn-deepseek-v41 | pi | t14-todosweep | pass | 13.5 | 1 | 6 | 20.6k | 3.0k | 1.1k | 16.5k/0 | 0.0063 | 0.0023 | 18/0 |
| syn-deepseek-v41 | pi | t15-pollstats | pass | 11.6 | 1 | 5 | 13.2k | 1.8k | 581 | 10.9k/0 | 0.0039 | 0.0013 | 1/0 |
| syn-deepseek-v41 | pi | t16-apisum | pass | 11 | 1 | 5 | 14.6k | 2.2k | 471 | 11.9k/0 | 0.0043 | 0.0013 | 27/0 |
| syn-deepseek-v41 | pi | t17-doccheck | pass | 46.4 | 1 | 11 | 49.0k | 4.9k | 4.3k | 39.8k/0 | 0.0154 | 0.0069 | 125/0 |
| syn-deepseek-v41 | pi | t18-lruttl | pass | 20.2 | 1 | 4 | 18.4k | 4.3k | 1.5k | 12.7k/0 | 0.0072 | 0.0031 | 97/12 |
| syn-deepseek-v41 | pi | t19-tokbucket | pass | 13.7 | 1 | 4 | 15.5k | 3.5k | 946 | 11.0k/0 | 0.0057 | 0.0023 | 26/11 |
| syn-deepseek-v41 | pi | t20-jsonpatch | pass | 48 | 1 | 6 | 29.7k | 5.9k | 4.2k | 19.6k/0 | 0.0129 | 0.0070 | 195/14 |
| syn-deepseek-v41 | pi | t21-wireproto | pass | 35 | 1 | 5 | 22.8k | 4.2k | 3.2k | 15.4k/0 | 0.0097 | 0.0052 | 67/8 |
| syn-deepseek-v41 | pi | t22-cronnext | pass | 43.1 | 1 | 5 | 25.9k | 5.4k | 4.0k | 16.5k/0 | 0.0117 | 0.0065 | 130/12 |
| syn-deepseek-v41 | pi | t23-mergesched | pass | 27.3 | 1 | 4 | 16.7k | 3.2k | 2.5k | 11.0k/0 | 0.0073 | 0.0040 | 78/4 |
| syn-deepseek-v41 | pi | t24-editops | pass | 35.7 | 1 | 6 | 25.6k | 4.2k | 3.1k | 18.3k/0 | 0.0100 | 0.0051 | 90/6 |
| syn-deepseek-v41 | pi | t25-shardmap | pass | 22 | 1 | 5 | 19.7k | 3.8k | 1.3k | 14.6k/0 | 0.0069 | 0.0028 | 84/16 |
| syn-deepseek-v41 | pi | t26-logfilter | pass | 90.1 | 1 | 5 | 29.2k | 4.7k | 8.5k | 16.0k/0 | 0.0166 | 0.0117 | 213/4 |
| syn-deepseek-v41 | pi | t27-tarpeek | pass | 69.4 | 1 | 12 | 117.7k | 11.6k | 5.9k | 100.2k/0 | 0.0324 | 0.0112 | 99/1 |
| syn-deepseek-v41 | pi | t28-docbackfill | pass | 9.1 | 1 | 4 | 13.4k | 2.8k | 751 | 9.9k/0 | 0.0047 | 0.0018 | 18/9 |
| syn-deepseek-v41 | pi | t29-logrollup | pass | 6.7 | 1 | 3 | 8.7k | 2.0k | 565 | 6.1k/0 | 0.0032 | 0.0013 | 436/0 |
| syn-deepseek-v41 | pi | t30-ifacedrift | pass | 12.8 | 1 | 6 | 33.2k | 5.6k | 1.0k | 26.5k/0 | 0.0100 | 0.0031 | 48/48 |
| syn-deepseek-v41 | pi | t31-tinyrename | pass | 9.8 | 1 | 5 | 15.1k | 2.4k | 812 | 11.9k/0 | 0.0048 | 0.0018 | 6/6 |

## Per-combo summary

| model | harness | pass rate | avg turns | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | run cost $ (provider) | run cost $ (official) | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| syn-deepseek-v41 | droid | 31/31 | 1.9 | 30 | 71.4k | 3.4k | 65.6k | 2.4k | 0.4996 | 0.1332 | 70/9 |
| syn-deepseek-v41 | niffler | 31/31 | 6.5 | 29 | 40.7k | 7.0k | 31.3k | 2.3k | 0.4156 | 0.1578 | 75/8 |
| syn-deepseek-v41 | pi | 31/31 | 5.3 | 24 | 23.2k | 3.8k | 17.4k | 2.1k | 0.2569 | 0.1154 | 70/9 |

*`invalid*` = tests pass but protected files (tests) were modified.*
*`⚠LEAK` = the cell reached external URLs (fetch/curl/git) — a SWE-bench instance comes from a merged upstream PR, so the verdict is not attributable to capability.*

*Cost bases — provider: the used endpoint's published catalog (Synthetic; cache writes bill at the prompt rate — the catalog's input_cache_writes=0 means "no separate write SKU", not free). official: the same token volumes at the model's first-party API list prices (DeepSeek peak tier; off-peak is half). Models without a verified first-party reference show —.*
