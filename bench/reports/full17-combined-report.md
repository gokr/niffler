# bench report — full17-combined (all five harnesses)

Niffler and niffler-expert cells come from `full17-flat2-fc2f5d4` — the
rerun with plain-text tool results (`(exit N)` status lines, `### path`
read_many blocks, one-line write/edit summaries) and trimmed tool
descriptions. Pi, opencode and codewhale cells are carried over from
`full17-pioc-5aa8c97` — none of those harnesses changed since.

- Same 17 tasks, same prompts, same models (deepseek-v4-flash, glm-5.3-flash);
harness order rotated per task in each run.
- All ten model×harness combos solve all 17 tasks in a single round.

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) | expert judge/steer/accepted |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|---|
| deepseek-v4-flash | codewhale | t01-roman | pass | 8.2 | 1 | 36.4k | 20.6k | 491 | 15.4k/0 | 0.0000 | 20/1 | - |
| deepseek-v4-flash | codewhale | t02-jsonrepair | pass | 28.1 | 1 | 53.2k | 27.7k | 3.5k | 22.0k/0 | 0.0000 | 91/1 | - |
| deepseek-v4-flash | codewhale | t03-ringbuffer | pass | 11.9 | 1 | 38.6k | 21.6k | 624 | 16.4k/0 | 0.0000 | 13/4 | - |
| deepseek-v4-flash | codewhale | t04-csvbugfix | pass | 21.3 | 1 | 37.6k | 21.1k | 463 | 16.0k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | codewhale | t05-todostore | pass | 8.3 | 1 | 40.0k | 22.4k | 708 | 16.9k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | codewhale | t06-stackvm | pass | 84.5 | 1 | 209.4k | 103.0k | 13.2k | 93.3k/0 | 0.0000 | 142/39 | - |
| deepseek-v4-flash | codewhale | t07-validate | pass | 14.5 | 1 | 46.9k | 25.4k | 1.9k | 19.6k/0 | 0.0000 | 11/11 | - |
| deepseek-v4-flash | codewhale | t08-logsum | pass | 17.9 | 1 | 102.7k | 53.9k | 1.6k | 47.2k/0 | 0.0000 | 44/2 | - |
| deepseek-v4-flash | codewhale | t09-poolrace | pass | 1069.7 | 1 | 95.3k | 48.4k | 4.1k | 42.8k/0 | 0.0000 | 8/1 | - |
| deepseek-v4-flash | codewhale | t10-iniparse | pass | 38.7 | 1 | 73.1k | 39.2k | 1.3k | 32.6k/0 | 0.0000 | 5/6 | - |
| deepseek-v4-flash | codewhale | t11-asyncbugs | pass | 15.6 | 1 | 60.3k | 33.1k | 1.6k | 25.6k/0 | 0.0000 | 7/6 | - |
| deepseek-v4-flash | codewhale | t12-refactor | pass | 7.1 | 1 | 38.5k | 21.7k | 586 | 16.3k/0 | 0.0000 | 2/4 | - |
| deepseek-v4-flash | codewhale | t13-batchrename | pass | 7.6 | 1 | 38.6k | 21.6k | 462 | 16.5k/0 | 0.0000 | 27/27 | - |
| deepseek-v4-flash | codewhale | t14-todosweep | pass | 6.7 | 1 | 28.5k | 16.8k | 497 | 11.1k/0 | 0.0000 | 18/0 | - |
| deepseek-v4-flash | codewhale | t15-pollstats | pass | 8.9 | 1 | 39.3k | 22.1k | 549 | 16.6k/0 | 0.0000 | 1/0 | - |
| deepseek-v4-flash | codewhale | t16-apisum | pass | 9.2 | 1 | 39.0k | 21.9k | 542 | 16.5k/0 | 0.0000 | 21/0 | - |
| deepseek-v4-flash | codewhale | t17-doccheck | pass | 221 | 1 | 336.8k | 169.5k | 6.0k | 161.3k/0 | 0.0000 | 31/0 | - |
| deepseek-v4-flash | niffler | t01-roman | pass | 13.9 | 1 | 24.2k | 1.4k | 581 | 22.1k/0 | 0.0000 | 19/1 | - |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 30.3 | 1 | 34.2k | 1.9k | 3.7k | 28.7k/0 | 0.0000 | 99/1 | - |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 19.5 | 1 | 21.8k | 1.5k | 1.0k | 19.3k/0 | 0.0000 | 14/4 | - |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 11.4 | 1 | 30.1k | 1.8k | 804 | 27.5k/0 | 0.0000 | 3/3 | - |
| deepseek-v4-flash | niffler | t05-todostore | pass | 8.6 | 1 | 25.6k | 2.4k | 668 | 22.5k/0 | 0.0000 | 18/4 | - |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 88.4 | 1 | 100.3k | 7.7k | 13.1k | 79.5k/0 | 0.0000 | 159/49 | - |
| deepseek-v4-flash | niffler | t07-validate | pass | 21.6 | 1 | 30.2k | 1.9k | 2.7k | 25.6k/0 | 0.0000 | 16/8 | - |
| deepseek-v4-flash | niffler | t08-logsum | pass | 21.5 | 1 | 55.7k | 3.5k | 2.2k | 50.0k/0 | 0.0000 | 74/4 | - |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 10.5 | 1 | 20.2k | 1.6k | 492 | 18.2k/0 | 0.0000 | 4/1 | - |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 56.6 | 1 | 33.1k | 2.6k | 2.5k | 28.0k/0 | 0.0000 | 6/5 | - |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 54.6 | 1 | 54.1k | 3.4k | 3.4k | 47.4k/0 | 0.0000 | 6/10 | - |
| deepseek-v4-flash | niffler | t12-refactor | pass | 10 | 1 | 24.2k | 3.0k | 771 | 20.4k/0 | 0.0000 | 2/4 | - |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 11.2 | 1 | 43.5k | 6.1k | 672 | 36.7k/0 | 0.0000 | 27/27 | - |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 5.4 | 1 | 12.5k | 1.5k | 406 | 10.6k/0 | 0.0000 | 18/0 | - |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 8.1 | 1 | 26.7k | 2.1k | 566 | 24.1k/0 | 0.0000 | 1/0 | - |
| deepseek-v4-flash | niffler | t16-apisum | pass | 7.7 | 1 | 17.6k | 1.7k | 419 | 15.5k/0 | 0.0000 | 11/0 | - |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 46.6 | 1 | 140.3k | 6.5k | 5.6k | 128.1k/0 | 0.0000 | 127/0 | - |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 11.6 | 1 | 21.0k | 7.1k | 465 | 13.4k/0 | 0.0000 | 19/1 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 89.5 | 1 | 67.9k | 9.2k | 7.1k | 51.6k/0 | 0.0000 | 50/1 | 2/1/1 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 28 | 1 | 37.0k | 9.5k | 918 | 26.6k/0 | 0.0000 | 16/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 11.6 | 1 | 40.0k | 4.1k | 1.3k | 34.7k/0 | 0.0000 | 3/3 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 12.4 | 1 | 33.9k | 8.9k | 750 | 24.3k/0 | 0.0000 | 19/15 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 81.4 | 1 | 103.9k | 8.6k | 11.8k | 83.5k/0 | 0.0000 | 130/23 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t07-validate | pass | 31.8 | 1 | 90.1k | 8.7k | 4.1k | 77.3k/0 | 0.0000 | 24/9 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t08-logsum | pass | 19.4 | 1 | 56.4k | 4.6k | 2.2k | 49.5k/0 | 0.0000 | 73/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t09-poolrace | pass | 13 | 1 | 35.9k | 3.4k | 842 | 31.6k/0 | 0.0000 | 4/1 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t10-iniparse | pass | 21.2 | 1 | 36.8k | 3.4k | 981 | 32.5k/0 | 0.0000 | 6/5 | 2/1/1 |
| deepseek-v4-flash | niffler-expert | t11-asyncbugs | pass | 24.1 | 1 | 45.8k | 4.5k | 2.1k | 39.2k/0 | 0.0000 | 5/10 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t12-refactor | pass | 11.8 | 1 | 37.5k | 3.6k | 1.1k | 32.8k/0 | 0.0000 | 2/4 | 2/0/0 |
| deepseek-v4-flash | niffler-expert | t13-batchrename | pass | 12.5 | 1 | 37.4k | 9.4k | 521 | 27.5k/0 | 0.0000 | 27/27 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t14-todosweep | pass | 8.1 | 1 | 23.7k | 2.0k | 438 | 21.2k/0 | 0.0000 | 18/0 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t15-pollstats | pass | 155.2 | 1 | 272.8k | 9.4k | 13.4k | 250.0k/0 | 0.0000 | 1/0 | 1/1/1 |
| deepseek-v4-flash | niffler-expert | t16-apisum | pass | 127.4 | 1 | 22.7k | 7.7k | 344 | 14.6k/0 | 0.0000 | 16/0 | 1/0/0 |
| deepseek-v4-flash | niffler-expert | t17-doccheck | pass | 34.7 | 1 | 123.1k | 7.2k | 4.0k | 111.9k/0 | 0.0000 | 49/0 | 2/0/0 |
| deepseek-v4-flash | opencode | t01-roman | pass | 19.4 | 1 | 69.2k | 483 | 541 | 68.2k/0 | 0.0004 | 13/1 | - |
| deepseek-v4-flash | opencode | t02-jsonrepair | pass | 92.3 | 1 | 126.9k | 16.7k | 1.7k | 108.5k/0 | 0.0053 | 127/1 | - |
| deepseek-v4-flash | opencode | t03-ringbuffer | pass | 27.1 | 1 | 91.0k | 16.1k | 836 | 74.1k/0 | 0.0028 | 15/4 | - |
| deepseek-v4-flash | opencode | t04-csvbugfix | pass | 45 | 1 | 110.6k | 16.7k | 729 | 93.2k/0 | 0.0029 | 3/3 | - |
| deepseek-v4-flash | opencode | t05-todostore | pass | 30.5 | 1 | 109.4k | 16.8k | 825 | 91.8k/0 | 0.0029 | 19/4 | - |
| deepseek-v4-flash | opencode | t06-stackvm | pass | 110.6 | 1 | 286.5k | 22.1k | 3.1k | 261.2k/0 | 0.0080 | 143/53 | - |
| deepseek-v4-flash | opencode | t07-validate | pass | 56.1 | 1 | 149.7k | 23.6k | 1.2k | 124.9k/0 | 0.0054 | 10/11 | - |
| deepseek-v4-flash | opencode | t08-logsum | pass | 41.3 | 1 | 119.8k | 17.6k | 1.5k | 100.7k/0 | 0.0038 | 45/2 | - |
| deepseek-v4-flash | opencode | t09-poolrace | pass | 24.5 | 1 | 92.5k | 16.3k | 777 | 75.4k/0 | 0.0029 | 8/1 | - |
| deepseek-v4-flash | opencode | t10-iniparse | pass | 63.2 | 1 | 134.1k | 17.7k | 1.0k | 115.3k/0 | 0.0033 | 6/5 | - |
| deepseek-v4-flash | opencode | t11-asyncbugs | pass | 47.7 | 1 | 114.3k | 17.1k | 1.0k | 96.1k/0 | 0.0035 | 5/10 | - |
| deepseek-v4-flash | opencode | t12-refactor | pass | 20.2 | 1 | 91.9k | 16.7k | 740 | 74.4k/0 | 0.0028 | 2/4 | - |
| deepseek-v4-flash | opencode | t13-batchrename | pass | 17.3 | 1 | 77.5k | 18.6k | 326 | 58.6k/0 | 0.0029 | 27/27 | - |
| deepseek-v4-flash | opencode | t14-todosweep | pass | 35.6 | 1 | 140.5k | 18.1k | 1.3k | 121.1k/0 | 0.0037 | 18/0 | - |
| deepseek-v4-flash | opencode | t15-pollstats | pass | 24.7 | 1 | 105.8k | 16.0k | 383 | 89.3k/0 | 0.0026 | 1/0 | - |
| deepseek-v4-flash | opencode | t16-apisum | pass | 21.3 | 1 | 71.0k | 15.9k | 357 | 54.7k/0 | 0.0025 | 12/0 | - |
| deepseek-v4-flash | opencode | t17-doccheck | pass | 97.9 | 1 | 285.8k | 17.2k | 3.0k | 265.7k/0 | 0.0056 | 124/0 | - |
| deepseek-v4-flash | pi | t01-roman | pass | 8.1 | 1 | 9.6k | 666 | 504 | 8.4k/0 | 0.0010 | 21/1 | - |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 36.9 | 1 | 26.2k | 7.2k | 4.6k | 14.3k/0 | 0.0077 | 142/1 | - |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 12.8 | 1 | 13.9k | 2.1k | 869 | 11.0k/0 | 0.0019 | 16/4 | - |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 30.6 | 1 | 18.7k | 2.6k | 1.2k | 14.8k/0 | 0.0025 | 3/3 | - |
| deepseek-v4-flash | pi | t05-todostore | pass | 107.8 | 1 | 14.8k | 2.9k | 765 | 11.1k/0 | 0.0020 | 18/4 | - |
| deepseek-v4-flash | pi | t06-stackvm | pass | 61.3 | 1 | 106.9k | 7.2k | 8.7k | 91.0k/0 | 0.0145 | 143/42 | - |
| deepseek-v4-flash | pi | t07-validate | pass | 20.7 | 1 | 21.8k | 3.0k | 2.9k | 15.9k/0 | 0.0046 | 20/10 | - |
| deepseek-v4-flash | pi | t08-logsum | pass | 26 | 1 | 47.5k | 4.0k | 3.2k | 40.3k/0 | 0.0059 | 72/2 | - |
| deepseek-v4-flash | pi | t09-poolrace | pass | 11 | 1 | 14.7k | 2.2k | 802 | 11.6k/0 | 0.0019 | 9/2 | - |
| deepseek-v4-flash | pi | t10-iniparse | pass | 21.4 | 1 | 18.8k | 3.0k | 1.6k | 14.1k/0 | 0.0031 | 10/6 | - |
| deepseek-v4-flash | pi | t11-asyncbugs | pass | 12.9 | 1 | 17.8k | 2.9k | 1.6k | 13.3k/0 | 0.0030 | 6/10 | - |
| deepseek-v4-flash | pi | t12-refactor | pass | 9.8 | 1 | 15.8k | 2.5k | 1.1k | 12.2k/0 | 0.0023 | 2/4 | - |
| deepseek-v4-flash | pi | t13-batchrename | pass | 10 | 1 | 18.8k | 3.6k | 823 | 14.3k/0 | 0.0024 | 27/27 | - |
| deepseek-v4-flash | pi | t14-todosweep | pass | 12.3 | 1 | 18.1k | 3.0k | 1.3k | 13.8k/0 | 0.0028 | 18/0 | - |
| deepseek-v4-flash | pi | t15-pollstats | pass | 10.7 | 1 | 19.9k | 2.7k | 734 | 16.5k/0 | 0.0021 | 1/0 | - |
| deepseek-v4-flash | pi | t16-apisum | pass | 9.4 | 1 | 11.2k | 2.3k | 507 | 8.4k/0 | 0.0015 | 9/0 | - |
| deepseek-v4-flash | pi | t17-doccheck | pass | 16 | 1 | 25.8k | 3.1k | 1.4k | 21.4k/0 | 0.0030 | 48/0 | - |
| glm-5.3-flash | codewhale | t01-roman | pass | 31.6 | 1 | 28.0k | 20.0k | 325 | 7.7k/0 | 0.0000 | 20/1 | - |
| glm-5.3-flash | codewhale | t02-jsonrepair | pass | 169.3 | 1 | 164.6k | 86.5k | 4.7k | 73.5k/0 | 0.0000 | 109/1 | - |
| glm-5.3-flash | codewhale | t03-ringbuffer | pass | 33.4 | 1 | 40.0k | 21.0k | 483 | 18.5k/0 | 0.0000 | 16/4 | - |
| glm-5.3-flash | codewhale | t04-csvbugfix | pass | 27.8 | 1 | 29.6k | 20.8k | 344 | 8.4k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | codewhale | t05-todostore | pass | 25.5 | 1 | 41.6k | 22.0k | 653 | 18.9k/0 | 0.0000 | 17/4 | - |
| glm-5.3-flash | codewhale | t06-stackvm | pass | 242.6 | 1 | 304.0k | 158.2k | 8.1k | 137.7k/0 | 0.0000 | 176/68 | - |
| glm-5.3-flash | codewhale | t07-validate | pass | 41.9 | 1 | 38.0k | 22.5k | 1.0k | 14.5k/0 | 0.0000 | 22/11 | - |
| glm-5.3-flash | codewhale | t08-logsum | pass | 29.9 | 1 | 32.1k | 22.5k | 565 | 9.1k/0 | 0.0000 | 54/2 | - |
| glm-5.3-flash | codewhale | t09-poolrace | pass | 23.3 | 1 | 28.1k | 19.8k | 384 | 7.9k/0 | 0.0000 | 4/1 | - |
| glm-5.3-flash | codewhale | t10-iniparse | pass | 41.8 | 1 | 51.8k | 28.8k | 816 | 22.1k/0 | 0.0000 | 6/5 | - |
| glm-5.3-flash | codewhale | t11-asyncbugs | pass | 38.8 | 1 | 32.3k | 22.4k | 801 | 9.1k/0 | 0.0000 | 6/10 | - |
| glm-5.3-flash | codewhale | t12-refactor | pass | 29.1 | 1 | 27.7k | 21.0k | 425 | 6.3k/0 | 0.0000 | 2/4 | - |
| glm-5.3-flash | codewhale | t13-batchrename | pass | 15 | 1 | 18.4k | 10.2k | 191 | 8.1k/0 | 0.0000 | 27/27 | - |
| glm-5.3-flash | codewhale | t14-todosweep | pass | 49.7 | 1 | 50.1k | 31.6k | 1.0k | 17.5k/0 | 0.0000 | 18/0 | - |
| glm-5.3-flash | codewhale | t15-pollstats | pass | 28.3 | 1 | 36.9k | 21.1k | 362 | 15.4k/0 | 0.0000 | 1/0 | - |
| glm-5.3-flash | codewhale | t16-apisum | pass | 60.5 | 1 | 29.6k | 20.8k | 228 | 8.5k/0 | 0.0000 | 17/0 | - |
| glm-5.3-flash | codewhale | t17-doccheck | pass | 638.4 | 2 | 149.6k | 91.4k | 5.3k | 52.9k/0 | 0.0000 | 134/0 | - |
| glm-5.3-flash | niffler | t01-roman | pass | 22.7 | 1 | 9.2k | 3.2k | 227 | 5.8k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 63.4 | 1 | 35.4k | 11.3k | 1.7k | 22.4k/0 | 0.0000 | 49/10 | - |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 40.9 | 1 | 18.4k | 2.4k | 809 | 15.2k/0 | 0.0000 | 13/4 | - |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 19 | 1 | 13.8k | 2.0k | 196 | 11.5k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | niffler | t05-todostore | pass | 24 | 1 | 13.6k | 4.0k | 399 | 9.2k/0 | 0.0000 | 16/4 | - |
| glm-5.3-flash | niffler | t06-stackvm | pass | 64.5 | 1 | 43.3k | 10.8k | 2.4k | 30.1k/0 | 0.0000 | 144/64 | - |
| glm-5.3-flash | niffler | t07-validate | pass | 33.4 | 1 | 18.8k | 4.4k | 614 | 13.8k/0 | 0.0000 | 11/10 | - |
| glm-5.3-flash | niffler | t08-logsum | pass | 55.9 | 1 | 44.0k | 7.4k | 1.1k | 35.5k/0 | 0.0000 | 59/4 | - |
| glm-5.3-flash | niffler | t09-poolrace | pass | 63.1 | 1 | 21.2k | 2.1k | 472 | 18.6k/0 | 0.0000 | 4/1 | - |
| glm-5.3-flash | niffler | t10-iniparse | pass | 43.6 | 1 | 27.5k | 8.2k | 414 | 18.9k/0 | 0.0000 | 6/5 | - |
| glm-5.3-flash | niffler | t11-asyncbugs | pass | 43.5 | 1 | 24.8k | 2.8k | 679 | 21.3k/0 | 0.0000 | 6/11 | - |
| glm-5.3-flash | niffler | t12-refactor | pass | 27.5 | 1 | 17.8k | 3.5k | 366 | 14.0k/0 | 0.0000 | 2/4 | - |
| glm-5.3-flash | niffler | t13-batchrename | pass | 30.1 | 1 | 16.0k | 954 | 165 | 14.8k/0 | 0.0000 | 27/27 | - |
| glm-5.3-flash | niffler | t14-todosweep | pass | 24.8 | 1 | 10.6k | 2.3k | 123 | 8.1k/0 | 0.0000 | 18/0 | - |
| glm-5.3-flash | niffler | t15-pollstats | pass | 16.3 | 1 | 12.8k | 1.5k | 190 | 11.1k/0 | 0.0000 | 13/0 | - |
| glm-5.3-flash | niffler | t16-apisum | pass | 17.5 | 1 | 14.0k | 4.8k | 197 | 9.0k/0 | 0.0000 | 12/0 | - |
| glm-5.3-flash | niffler | t17-doccheck | pass | 22.4 | 1 | 18.3k | 5.5k | 397 | 12.4k/0 | 0.0000 | 27/0 | - |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 22 | 1 | 25.4k | 4.5k | 361 | 20.5k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 55.3 | 1 | 42.5k | 5.3k | 1.6k | 35.5k/0 | 0.0000 | 82/10 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 38.8 | 1 | 31.1k | 2.7k | 953 | 27.5k/0 | 0.0000 | 13/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 25.4 | 1 | 26.9k | 4.7k | 319 | 21.8k/0 | 0.0000 | 3/3 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 26.7 | 1 | 26.3k | 2.9k | 494 | 22.8k/0 | 0.0000 | 18/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 180.9 | 1 | 177.6k | 17.8k | 6.1k | 153.7k/0 | 0.0000 | 158/52 | 2/1/1 |
| glm-5.3-flash | niffler-expert | t07-validate | pass | 92.3 | 1 | 36.3k | 13.6k | 585 | 22.1k/0 | 0.0000 | 14/12 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t08-logsum | pass | 62.9 | 1 | 63.5k | 14.1k | 1.2k | 48.3k/0 | 0.0000 | 51/2 | 2/1/1 |
| glm-5.3-flash | niffler-expert | t09-poolrace | pass | 24.1 | 1 | 19.6k | 7.2k | 534 | 11.8k/0 | 0.0000 | 4/1 | 1/1/1 |
| glm-5.3-flash | niffler-expert | t10-iniparse | pass | 71.6 | 1 | 46.6k | 12.3k | 759 | 33.5k/0 | 0.0000 | 8/8 | 2/1/1 |
| glm-5.3-flash | niffler-expert | t11-asyncbugs | pass | 50.7 | 1 | 44.1k | 7.5k | 649 | 36.0k/0 | 0.0000 | 6/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t12-refactor | pass | 18.5 | 1 | 27.2k | 9.3k | 378 | 17.5k/0 | 0.0000 | 2/4 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t13-batchrename | pass | 9.6 | 1 | 15.0k | 465 | 110 | 14.4k/0 | 0.0000 | 27/27 | 1/0/0 |
| glm-5.3-flash | niffler-expert | t14-todosweep | pass | 14.4 | 1 | 20.2k | 1.6k | 250 | 18.3k/0 | 0.0000 | 18/0 | 1/0/0 |
| glm-5.3-flash | niffler-expert | t15-pollstats | pass | 15.2 | 1 | 16.4k | 2.0k | 256 | 14.1k/0 | 0.0000 | 1/0 | 1/0/0 |
| glm-5.3-flash | niffler-expert | t16-apisum | pass | 21.4 | 1 | 25.2k | 1.4k | 277 | 23.5k/0 | 0.0000 | 7/0 | 2/0/0 |
| glm-5.3-flash | niffler-expert | t17-doccheck | pass | 131.9 | 1 | 129.7k | 16.8k | 3.1k | 109.8k/0 | 0.0000 | 36/0 | 1/1/1 |
| glm-5.3-flash | opencode | t01-roman | pass | 42.5 | 1 | 84.4k | 17.2k | 417 | 66.8k/0 | 0.0040 | 13/1 | - |
| glm-5.3-flash | opencode | t02-jsonrepair | pass | 327 | 1 | 209.5k | 66.5k | 1.7k | 141.2k/0 | 0.0157 | 128/1 | - |
| glm-5.3-flash | opencode | t03-ringbuffer | pass | 66.3 | 1 | 103.4k | 18.3k | 755 | 84.4k/0 | 0.0048 | 14/4 | - |
| glm-5.3-flash | opencode | t04-csvbugfix | pass | 59.8 | 1 | 84.4k | 64.3k | 297 | 19.8k/0 | 0.0090 | 3/3 | - |
| glm-5.3-flash | opencode | t05-todostore | pass | 106.9 | 1 | 103.4k | 49.7k | 682 | 53.1k/0 | 0.0080 | 16/4 | - |
| glm-5.3-flash | opencode | t06-stackvm | pass | 289.7 | 1 | 217.6k | 84.0k | 2.6k | 130.9k/0 | 0.0184 | 117/41 | - |
| glm-5.3-flash | opencode | t07-validate | pass | 112.4 | 1 | 108.8k | 56.0k | 938 | 51.8k/0 | 0.0097 | 15/9 | - |
| glm-5.3-flash | opencode | t08-logsum | pass | 232.4 | 1 | 204.2k | 55.0k | 1.5k | 147.7k/0 | 0.0116 | 48/3 | - |
| glm-5.3-flash | opencode | t09-poolrace | pass | 79.2 | 1 | 106.8k | 60.7k | 578 | 45.5k/0 | 0.0094 | 4/1 | - |
| glm-5.3-flash | opencode | t10-iniparse | pass | 100.3 | 1 | 108.4k | 51.2k | 827 | 56.3k/0 | 0.0089 | 10/7 | - |
| glm-5.3-flash | opencode | t11-asyncbugs | pass | 58.8 | 1 | 105.8k | 50.2k | 730 | 54.9k/0 | 0.0083 | 6/5 | - |
| glm-5.3-flash | opencode | t12-refactor | pass | 45.1 | 1 | 86.1k | 50.5k | 440 | 35.1k/0 | 0.0076 | 2/4 | - |
| glm-5.3-flash | opencode | t13-batchrename | pass | 52.8 | 1 | 91.9k | 38.7k | 531 | 52.7k/0 | 0.0066 | 27/27 | - |
| glm-5.3-flash | opencode | t14-todosweep | pass | 57.1 | 1 | 86.5k | 53.0k | 495 | 33.0k/0 | 0.0079 | 18/0 | - |
| glm-5.3-flash | opencode | t15-pollstats | pass | 58.3 | 1 | 103.8k | 22.1k | 649 | 81.1k/0 | 0.0052 | 1/0 | - |
| glm-5.3-flash | opencode | t16-apisum | pass | 113 | 1 | 168.7k | 25.4k | 921 | 142.3k/0 | 0.0076 | 20/0 | - |
| glm-5.3-flash | opencode | t17-doccheck | pass | 321.2 | 1 | 234.6k | 41.3k | 3.4k | 189.8k/0 | 0.0140 | 139/0 | - |
| glm-5.3-flash | pi | t01-roman | pass | 17.2 | 1 | 8.1k | 4.7k | 283 | 3.1k/0 | 0.0000 | 13/1 | - |
| glm-5.3-flash | pi | t02-jsonrepair | pass | 24.2 | 1 | 10.0k | 4.5k | 681 | 4.8k/0 | 0.0000 | 76/1 | - |
| glm-5.3-flash | pi | t03-ringbuffer | pass | 21.9 | 1 | 8.7k | 5.2k | 454 | 3.1k/0 | 0.0000 | 15/4 | - |
| glm-5.3-flash | pi | t04-csvbugfix | pass | 11.7 | 1 | 8.6k | 4.7k | 222 | 3.6k/0 | 0.0000 | 3/3 | - |
| glm-5.3-flash | pi | t05-todostore | pass | 27.5 | 1 | 8.5k | 5.2k | 404 | 2.9k/0 | 0.0000 | 16/4 | - |
| glm-5.3-flash | pi | t06-stackvm | pass | 81.2 | 1 | 43.7k | 22.6k | 3.0k | 18.1k/0 | 0.0000 | 136/49 | - |
| glm-5.3-flash | pi | t07-validate | pass | 28 | 1 | 19.2k | 14.0k | 505 | 4.7k/0 | 0.0000 | 4/7 | - |
| glm-5.3-flash | pi | t08-logsum | pass | 25.9 | 1 | 15.6k | 5.9k | 643 | 9.1k/0 | 0.0000 | 48/2 | - |
| glm-5.3-flash | pi | t09-poolrace | pass | 17.5 | 1 | 7.4k | 5.7k | 184 | 1.5k/0 | 0.0000 | 4/3 | - |
| glm-5.3-flash | pi | t10-iniparse | pass | 33 | 1 | 17.2k | 10.1k | 534 | 6.5k/0 | 0.0000 | 6/5 | - |
| glm-5.3-flash | pi | t11-asyncbugs | pass | 38.9 | 1 | 24.8k | 16.6k | 595 | 7.6k/0 | 0.0000 | 5/10 | - |
| glm-5.3-flash | pi | t12-refactor | pass | 18.1 | 1 | 10.6k | 3.6k | 319 | 6.6k/0 | 0.0000 | 2/4 | - |
| glm-5.3-flash | pi | t13-batchrename | pass | 9.5 | 1 | 5.5k | 3.8k | 119 | 1.5k/0 | 0.0000 | 27/27 | - |
| glm-5.3-flash | pi | t14-todosweep | pass | 12.6 | 1 | 6.6k | 4.9k | 134 | 1.5k/0 | 0.0000 | 18/0 | - |
| glm-5.3-flash | pi | t15-pollstats | pass | 11.9 | 1 | 7.3k | 4.3k | 196 | 2.8k/0 | 0.0000 | 1/0 | - |
| glm-5.3-flash | pi | t16-apisum | pass | 13.9 | 1 | 7.4k | 3.9k | 181 | 3.3k/0 | 0.0000 | 13/0 | - |
| glm-5.3-flash | pi | t17-doccheck | pass | 55.2 | 1 | 33.0k | 19.8k | 1.2k | 12.0k/0 | 0.0000 | 34/8 | - |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | codewhale | 17/17 | 93 | 77.3k | 40.6k | 34.5k | 2.2k | 27/6 |
| deepseek-v4-flash | niffler | 17/17 | 25 | 40.9k | 3.0k | 35.5k | 2.3k | 36/7 |
| deepseek-v4-flash | niffler-expert | 17/17 | 41 | 63.9k | 6.5k | 54.3k | 3.1k | 27/6 |
| deepseek-v4-flash | opencode | 17/17 | 46 | 128.0k | 16.7k | 110.2k | 1.1k | 34/7 |
| deepseek-v4-flash | pi | 17/17 | 25 | 24.7k | 3.2k | 19.6k | 1.9k | 33/7 |
| glm-5.3-flash | codewhale | 17/17 | 90 | 64.9k | 37.7k | 25.7k | 1.5k | 37/8 |
| glm-5.3-flash | niffler | 17/17 | 36 | 21.1k | 4.5k | 16.0k | 618 | 25/9 |
| glm-5.3-flash | niffler-expert | 17/17 | 51 | 45.5k | 7.3k | 37.1k | 1.1k | 27/8 |
| glm-5.3-flash | opencode | 17/17 | 125 | 129.9k | 47.3k | 81.6k | 1.0k | 34/6 |
| glm-5.3-flash | pi | 17/17 | 26 | 14.2k | 8.2k | 5.5k | 570 | 25/8 |

*`invalid*` = tests pass but protected files (tests) were modified.*
