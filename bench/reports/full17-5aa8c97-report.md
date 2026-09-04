# bench report — full17-5aa8c97 (+ pi/opencode from full17-2830c91)

Niffler and Niffler-expert cells come from the `full17-5aa8c97` rerun (after the
fd CLOEXEC sweep, round-budget fix, and bench prompt-diet fixes). Pi and Opencode
cells are carried over from `full17-2830c91` — their numbers were collected there
and not re-run. Caveats for the comparison:

- Same 17 tasks, same prompts, same models; harness order rotated per task in both runs.
- `full17-2830c91` predates the bench validity fixes: t10-iniparse was invalid on
  ALL 8 combos there (protected-file trip), so t10 reads `invalid*` for every
  harness from that run — it is a task fix, not a harness regression/improvement.
- Niffler-side prompt diet (8-tool direct set) only affects the niffler harnesses;
  pi/opencode prompts were unchanged between the runs.

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | diff (+/-) | run |
|---|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| deepseek-v4-flash | niffler | t01-roman | pass | 9.2 | 1 | 23.0k | 5.1k | 562 | 17280/0 | 1/20/1 | 5aa8c97 |
| deepseek-v4-flash | niffler | t02-jsonrepair | pass | 47.3 | 1 | 104.9k | 4.9k | 4909 | 95104/0 | 1/86/1 | 5aa8c97 |
| deepseek-v4-flash | niffler | t03-ringbuffer | pass | 12.2 | 1 | 22.1k | 2.0k | 617 | 19456/0 | 2/18/4 | 5aa8c97 |
| deepseek-v4-flash | niffler | t04-csvbugfix | pass | 11.2 | 1 | 29.4k | 2.1k | 1056 | 26240/0 | 1/3/3 | 5aa8c97 |
| deepseek-v4-flash | niffler | t05-todostore | pass | 9.9 | 1 | 25.0k | 1.9k | 745 | 22400/0 | 1/25/4 | 5aa8c97 |
| deepseek-v4-flash | niffler | t06-stackvm | pass | 113.3 | 1 | 111.9k | 6.7k | 12435 | 92800/0 | 2/146/43 | 5aa8c97 |
| deepseek-v4-flash | niffler | t07-validate | pass | 28.6 | 1 | 36.9k | 2.1k | 3484 | 31360/0 | 1/22/8 | 5aa8c97 |
| deepseek-v4-flash | niffler | t08-logsum | pass | 26 | 1 | 59.2k | 3.4k | 3068 | 52736/0 | 1/55/4 | 5aa8c97 |
| deepseek-v4-flash | niffler | t09-poolrace | pass | 12.7 | 1 | 23.6k | 2.1k | 1167 | 20352/0 | 1/4/1 | 5aa8c97 |
| deepseek-v4-flash | niffler | t10-iniparse | pass | 17.7 | 1 | 31.1k | 2.6k | 1453 | 27008/0 | 2/7/6 | 5aa8c97 |
| deepseek-v4-flash | niffler | t11-asyncbugs | pass | 19.2 | 1 | 26.3k | 2.0k | 2173 | 22144/0 | 1/6/7 | 5aa8c97 |
| deepseek-v4-flash | niffler | t12-refactor | pass | 12 | 1 | 25.5k | 1.7k | 1004 | 22784/0 | 1/2/4 | 5aa8c97 |
| deepseek-v4-flash | niffler | t13-batchrename | pass | 8.6 | 1 | 15.3k | 1.4k | 345 | 13568/0 | 26/27/27 | 5aa8c97 |
| deepseek-v4-flash | niffler | t14-todosweep | pass | 18.7 | 1 | 39.2k | 2.4k | 1633 | 35200/0 | 1/18/0 | 5aa8c97 |
| deepseek-v4-flash | niffler | t15-pollstats | pass | 13 | 1 | 25.7k | 1.6k | 686 | 23424/0 | 1/1/0 | 5aa8c97 |
| deepseek-v4-flash | niffler | t16-apisum | pass | 10.3 | 1 | 20.8k | 1.7k | 524 | 18560/0 | 2/23/0 | 5aa8c97 |
| deepseek-v4-flash | niffler | t17-doccheck | pass | 49.4 | 1 | 122.1k | 4.7k | 4689 | 112768/0 | 9/35/0 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t01-roman | pass | 10.7 | 1 | 25.4k | 8.3k | 871 | 16256/0 | 1/13/1 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t02-jsonrepair | pass | 38.6 | 1 | 48.5k | 8.8k | 4786 | 34944/0 | 1/103/1 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t03-ringbuffer | pass | 15.1 | 1 | 32.7k | 3.1k | 1289 | 28288/0 | 2/17/4 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t04-csvbugfix | pass | 10.1 | 1 | 30.8k | 2.3k | 650 | 27776/0 | 1/3/3 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t05-todostore | pass | 10.1 | 1 | 28.3k | 2.8k | 818 | 24704/0 | 1/21/4 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t06-stackvm | pass | 66.5 | 1 | 82.0k | 8.4k | 8892 | 64768/0 | 2/119/23 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t07-validate | pass | 31.9 | 1 | 38.3k | 6.5k | 3048 | 28736/0 | 1/12/8 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t08-logsum | pass | 22.9 | 1 | 51.3k | 4.7k | 2209 | 44416/0 | 1/48/2 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t09-poolrace | pass | 13.3 | 1 | 37.0k | 3.6k | 1366 | 32000/0 | 1/13/6 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t10-iniparse | pass | 33.3 | 1 | 48.4k | 6.7k | 3020 | 38656/0 | 2/9/7 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t11-asyncbugs | pass | 16.1 | 1 | 38.6k | 4.0k | 1689 | 32896/0 | 1/7/5 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t12-refactor | pass | 13.3 | 1 | 37.8k | 3.6k | 1437 | 32768/0 | 1/2/4 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t13-batchrename | pass | 8.2 | 1 | 28.7k | 2.8k | 461 | 25472/0 | 26/27/27 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t14-todosweep | pass | 28.4 | 1 | 53.7k | 5.6k | 2262 | 45824/0 | 1/18/0 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t15-pollstats | pass | 8.3 | 1 | 20.0k | 1.5k | 432 | 18048/0 | 1/1/0 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t16-apisum | pass | 12.9 | 1 | 31.7k | 3.5k | 623 | 27584/0 | 2/27/0 | 5aa8c97 |
| deepseek-v4-flash | niffler-expert | t17-doccheck | pass | 41.2 | 1 | 112.2k | 5.2k | 3576 | 103424/0 | 9/39/0 | 5aa8c97 |
| deepseek-v4-flash | pi | t01-roman | pass | 6.7 | 1 | 10.4k | 1.9k | 662 | 7808/0 | 1/13/1 | 2830c91 |
| deepseek-v4-flash | pi | t02-jsonrepair | pass | 88.3 | 1 | 112.5k | 3.4k | 11264 | 97792/0 | 1/138/1 | 2830c91 |
| deepseek-v4-flash | pi | t03-ringbuffer | pass | 19.1 | 1 | 17.6k | 2.5k | 1651 | 13440/0 | 2/17/4 | 2830c91 |
| deepseek-v4-flash | pi | t04-csvbugfix | pass | 10.6 | 1 | 15.9k | 2.3k | 1115 | 12416/0 | 1/3/3 | 2830c91 |
| deepseek-v4-flash | pi | t05-todostore | pass | 18.7 | 1 | 18.9k | 2.8k | 1045 | 15104/0 | 1/19/4 | 2830c91 |
| deepseek-v4-flash | pi | t06-stackvm | pass | 148.4 | 1 | 109.3k | 6.5k | 19543 | 83328/0 | 2/167/53 | 2830c91 |
| deepseek-v4-flash | pi | t07-validate | pass | 21.7 | 1 | 20.4k | 2.8k | 2436 | 15232/0 | 1/7/9 | 2830c91 |
| deepseek-v4-flash | pi | t08-logsum | pass | 50.3 | 1 | 61.0k | 3.6k | 5931 | 51456/0 | 1/58/2 | 2830c91 |
| deepseek-v4-flash | pi | t09-poolrace | pass | 40.4 | 1 | 15.9k | 2.1k | 1329 | 12416/0 | 1/8/1 | 2830c91 |
| deepseek-v4-flash | pi | t10-iniparse | invalid* | 70.7 | 1 | 27.3k | 3.5k | 2384 | 21376/0 | 2/5/6 | 2830c91 |
| deepseek-v4-flash | pi | t11-asyncbugs | pass | 21.5 | 1 | 17.9k | 2.9k | 1484 | 13568/0 | 1/6/4 | 2830c91 |
| deepseek-v4-flash | pi | t12-refactor | pass | 23.7 | 1 | 24.3k | 2.8k | 1995 | 19456/0 | 1/2/4 | 2830c91 |
| deepseek-v4-flash | pi | t13-batchrename | pass | 12.3 | 1 | 26.2k | 4.4k | 918 | 20864/0 | 26/27/27 | 2830c91 |
| deepseek-v4-flash | pi | t14-todosweep | pass | 30.9 | 1 | 30.3k | 4.0k | 3040 | 23296/0 | 1/18/0 | 2830c91 |
| deepseek-v4-flash | pi | t15-pollstats | pass | 17.3 | 1 | 18.5k | 2.4k | 1021 | 15104/0 | 1/1/0 | 2830c91 |
| deepseek-v4-flash | pi | t16-apisum | pass | 9.9 | 1 | 15.2k | 2.8k | 820 | 11520/0 | 2/27/0 | 2830c91 |
| deepseek-v4-flash | pi | t17-doccheck | pass | 105.2 | 1 | 80.4k | 3.7k | 12302 | 64384/0 | 9/59/0 | 2830c91 |
| deepseek-v4-flash | opencode | t01-roman | pass | 21 | 1 | 90.4k | 16.4k | 682 | 73344/0 | 1/13/1 | 2830c91 |
| deepseek-v4-flash | opencode | t02-jsonrepair | pass | 47.3 | 1 | 111.2k | 16.6k | 1179 | 93440/0 | 1/93/1 | 2830c91 |
| deepseek-v4-flash | opencode | t03-ringbuffer | pass | 25.3 | 1 | 91.4k | 16.4k | 799 | 74240/0 | 2/15/4 | 2830c91 |
| deepseek-v4-flash | opencode | t04-csvbugfix | pass | 26 | 1 | 127.8k | 16.4k | 846 | 110464/0 | 1/3/3 | 2830c91 |
| deepseek-v4-flash | opencode | t05-todostore | pass | 30.6 | 1 | 91.6k | 16.8k | 796 | 73984/0 | 1/16/4 | 2830c91 |
| deepseek-v4-flash | opencode | t06-stackvm | pass | 143.9 | 1 | 218.6k | 21.5k | 4058 | 193024/0 | 2/174/51 | 2830c91 |
| deepseek-v4-flash | opencode | t07-validate | pass | 62.1 | 1 | 100.8k | 17.1k | 1028 | 82688/0 | 1/10/11 | 2830c91 |
| deepseek-v4-flash | opencode | t08-logsum | pass | 59.3 | 1 | 183.6k | 18.3k | 1696 | 163584/0 | 2/57/4 | 2830c91 |
| deepseek-v4-flash | opencode | t09-poolrace | pass | 27.7 | 1 | 73.7k | 16.1k | 777 | 56832/0 | 1/9/2 | 2830c91 |
| deepseek-v4-flash | opencode | t10-iniparse | invalid* | 52.8 | 1 | 135.3k | 17.4k | 830 | 117120/0 | 2/6/7 | 2830c91 |
| deepseek-v4-flash | opencode | t11-asyncbugs | pass | 32.8 | 1 | 93.4k | 16.8k | 901 | 75648/0 | 1/6/4 | 2830c91 |
| deepseek-v4-flash | opencode | t12-refactor | pass | 24 | 1 | 110.8k | 16.7k | 744 | 93312/0 | 1/2/4 | 2830c91 |
| deepseek-v4-flash | opencode | t13-batchrename | pass | 26.8 | 1 | 118.8k | 18.9k | 570 | 99328/0 | 26/27/27 | 2830c91 |
| deepseek-v4-flash | opencode | t14-todosweep | pass | 41.5 | 1 | 138.1k | 17.7k | 839 | 119552/0 | 1/18/0 | 2830c91 |
| deepseek-v4-flash | opencode | t15-pollstats | pass | 28.8 | 1 | 109.5k | 16.4k | 566 | 92544/0 | 1/1/0 | 2830c91 |
| deepseek-v4-flash | opencode | t16-apisum | pass | 21.9 | 1 | 90.9k | 16.5k | 625 | 73728/0 | 2/16/0 | 2830c91 |
| deepseek-v4-flash | opencode | t17-doccheck | pass | 41.3 | 1 | 116.0k | 16.5k | 797 | 98688/0 | 9/34/0 | 2830c91 |
| glm-5.3-flash | niffler | t01-roman | pass | 34.2 | 1 | 20.2k | 4.5k | 375 | 15296/0 | 1/17/1 | 5aa8c97 |
| glm-5.3-flash | niffler | t02-jsonrepair | pass | 39.1 | 1 | 19.6k | 10.3k | 901 | 8448/0 | 1/69/1 | 5aa8c97 |
| glm-5.3-flash | niffler | t03-ringbuffer | pass | 37.9 | 1 | 19.0k | 2.7k | 776 | 15616/0 | 2/13/4 | 5aa8c97 |
| glm-5.3-flash | niffler | t04-csvbugfix | pass | 20.2 | 1 | 14.1k | 2.8k | 167 | 11136/0 | 1/3/3 | 5aa8c97 |
| glm-5.3-flash | niffler | t05-todostore | pass | 23.1 | 1 | 13.8k | 1.3k | 393 | 12096/0 | 1/16/4 | 5aa8c97 |
| glm-5.3-flash | niffler | t06-stackvm | pass | 76.7 | 1 | 61.7k | 9.0k | 2695 | 49984/0 | 2/171/60 | 5aa8c97 |
| glm-5.3-flash | niffler | t07-validate | pass | 37.4 | 1 | 28.8k | 15.6k | 495 | 12672/0 | 1/14/12 | 5aa8c97 |
| glm-5.3-flash | niffler | t08-logsum | pass | 45 | 1 | 29.8k | 11.1k | 636 | 18048/0 | 1/48/3 | 5aa8c97 |
| glm-5.3-flash | niffler | t09-poolrace | pass | 23 | 1 | 13.7k | 4.7k | 390 | 8640/0 | 1/4/1 | 5aa8c97 |
| glm-5.3-flash | niffler | t10-iniparse | pass | 122.4 | 1 | 75.7k | 19.5k | 1993 | 54208/0 | 2/6/5 | 5aa8c97 |
| glm-5.3-flash | niffler | t11-asyncbugs | pass | 80.3 | 1 | 42.2k | 11.8k | 818 | 29568/0 | 1/6/11 | 5aa8c97 |
| glm-5.3-flash | niffler | t12-refactor | pass | 36.3 | 1 | 26.7k | 11.1k | 395 | 15168/0 | 1/2/4 | 5aa8c97 |
| glm-5.3-flash | niffler | t13-batchrename | pass | 24.9 | 1 | 9.4k | 3.7k | 109 | 5568/0 | 26/27/27 | 5aa8c97 |
| glm-5.3-flash | niffler | t14-todosweep | pass | 14 | 1 | 10.9k | 5.2k | 126 | 5504/0 | 1/18/0 | 5aa8c97 |
| glm-5.3-flash | niffler | t15-pollstats | pass | 23 | 1 | 16.6k | 4.9k | 294 | 11392/0 | 1/1/0 | 5aa8c97 |
| glm-5.3-flash | niffler | t16-apisum | pass | 22.9 | 1 | 12.7k | 7.0k | 176 | 5568/0 | 2/11/0 | 5aa8c97 |
| glm-5.3-flash | niffler | t17-doccheck | pass | 174.5 | 1 | 128.7k | 39.8k | 3297 | 85632/0 | 11/140/0 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t01-roman | pass | 22.5 | 1 | 21.4k | 8.6k | 343 | 12416/0 | 1/13/4 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t02-jsonrepair | pass | 77.4 | 1 | 65.8k | 16.2k | 1779 | 47808/0 | 1/63/11 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t03-ringbuffer | pass | 27.3 | 1 | 21.8k | 1.7k | 557 | 19456/0 | 2/13/4 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t04-csvbugfix | pass | 20.6 | 1 | 22.1k | 2.9k | 246 | 18944/0 | 1/3/3 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t05-todostore | pass | 20.5 | 1 | 21.7k | 2.0k | 482 | 19136/0 | 1/16/4 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t06-stackvm | pass | 62.3 | 1 | 56.5k | 12.6k | 2268 | 41600/0 | 2/120/37 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t07-validate | pass | 44.7 | 1 | 41.6k | 11.8k | 800 | 29056/0 | 1/7/9 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t08-logsum | pass | 41.7 | 1 | 38.2k | 15.7k | 688 | 21824/0 | 1/45/2 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t09-poolrace | pass | 24.8 | 1 | 26.1k | 10.3k | 415 | 15424/0 | 1/4/1 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t10-iniparse | pass | 36.4 | 1 | 32.4k | 2.9k | 577 | 28864/0 | 2/6/5 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t11-asyncbugs | pass | 55.6 | 1 | 55.0k | 21.2k | 722 | 33152/0 | 1/6/5 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t12-refactor | pass | 39.6 | 1 | 35.1k | 13.2k | 579 | 21312/0 | 1/2/4 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t13-batchrename | pass | 13.7 | 1 | 13.8k | 4.6k | 148 | 9024/0 | 26/27/27 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t14-todosweep | pass | 16.3 | 1 | 14.5k | 5.4k | 144 | 8960/0 | 1/18/0 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t15-pollstats | pass | 18.9 | 1 | 13.1k | 3.9k | 185 | 9024/0 | 1/1/0 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t16-apisum | pass | 19.4 | 1 | 22.2k | 9.3k | 248 | 12672/0 | 2/11/0 | 5aa8c97 |
| glm-5.3-flash | niffler-expert | t17-doccheck | pass | 43.3 | 1 | 32.4k | 12.1k | 979 | 19328/0 | 10/56/0 | 5aa8c97 |
| glm-5.3-flash | pi | t01-roman | pass | 11.6 | 1 | 7.4k | 3.4k | 280 | 3712/0 | 1/13/1 | 2830c91 |
| glm-5.3-flash | pi | t02-jsonrepair | pass | 112.2 | 1 | 64.1k | 24.8k | 3175 | 36096/0 | 1/84/1 | 2830c91 |
| glm-5.3-flash | pi | t03-ringbuffer | pass | 20.7 | 1 | 8.6k | 4.7k | 413 | 3456/0 | 2/14/4 | 2830c91 |
| glm-5.3-flash | pi | t04-csvbugfix | pass | 10.1 | 1 | 8.5k | 5.0k | 192 | 3328/0 | 1/3/3 | 2830c91 |
| glm-5.3-flash | pi | t05-todostore | pass | 39.2 | 1 | 8.3k | 4.5k | 392 | 3456/0 | 1/16/4 | 2830c91 |
| glm-5.3-flash | pi | t06-stackvm | pass | 65.8 | 1 | 27.4k | 15.4k | 2239 | 9792/0 | 2/141/31 | 2830c91 |
| glm-5.3-flash | pi | t07-validate | pass | 34 | 1 | 29.9k | 11.8k | 771 | 17344/0 | 1/7/5 | 2830c91 |
| glm-5.3-flash | pi | t08-logsum | pass | 76.3 | 1 | 50.5k | 19.3k | 1388 | 29824/0 | 1/40/2 | 2830c91 |
| glm-5.3-flash | pi | t09-poolrace | pass | 15.7 | 1 | 8.0k | 7.5k | 383 | 128/0 | 1/4/1 | 2830c91 |
| glm-5.3-flash | pi | t10-iniparse | invalid* | 25.8 | 1 | 12.7k | 7.8k | 509 | 4352/0 | 2/6/7 | 2830c91 |
| glm-5.3-flash | pi | t11-asyncbugs | pass | 30.2 | 1 | 21.4k | 15.4k | 603 | 5312/0 | 1/6/11 | 2830c91 |
| glm-5.3-flash | pi | t12-refactor | pass | 19.7 | 1 | 10.6k | 6.3k | 349 | 3968/0 | 1/2/4 | 2830c91 |
| glm-5.3-flash | pi | t13-batchrename | pass | 13.4 | 1 | 5.5k | 2.5k | 99 | 2880/0 | 26/27/27 | 2830c91 |
| glm-5.3-flash | pi | t14-todosweep | pass | 10.3 | 1 | 6.5k | 4.9k | 147 | 1536/0 | 1/18/0 | 2830c91 |
| glm-5.3-flash | pi | t15-pollstats | pass | 14.2 | 1 | 9.4k | 3.0k | 233 | 6144/0 | 1/1/0 | 2830c91 |
| glm-5.3-flash | pi | t16-apisum | pass | 25 | 1 | 10.3k | 6.1k | 190 | 3968/0 | 2/7/0 | 2830c91 |
| glm-5.3-flash | pi | t17-doccheck | pass | 35 | 1 | 24.8k | 6.3k | 963 | 17536/0 | 10/69/0 | 2830c91 |
| glm-5.3-flash | opencode | t01-roman | pass | 48.4 | 1 | 83.9k | 26.0k | 505 | 57408/0 | 1/13/1 | 2830c91 |
| glm-5.3-flash | opencode | t02-jsonrepair | pass | 129.5 | 1 | 92.7k | 51.5k | 1124 | 40128/0 | 1/97/1 | 2830c91 |
| glm-5.3-flash | opencode | t03-ringbuffer | pass | 61.3 | 1 | 103.1k | 38.8k | 735 | 63488/0 | 2/16/4 | 2830c91 |
| glm-5.3-flash | opencode | t04-csvbugfix | pass | 45.4 | 1 | 84.6k | 24.3k | 347 | 60032/0 | 1/3/3 | 2830c91 |
| glm-5.3-flash | opencode | t05-todostore | pass | 30.1 | 1 | 85.3k | 8.1k | 556 | 76608/0 | 1/14/4 | 2830c91 |
| glm-5.3-flash | opencode | t06-stackvm | pass | 350.1 | 1 | 350.4k | 43.6k | 3490 | 303296/0 | 2/171/67 | 2830c91 |
| glm-5.3-flash | opencode | t07-validate | pass | 95.7 | 1 | 130.5k | 45.4k | 991 | 84032/0 | 1/6/9 | 2830c91 |
| glm-5.3-flash | opencode | t08-logsum | pass | 146.9 | 1 | 215.7k | 60.7k | 1560 | 153344/0 | 1/46/2 | 2830c91 |
| glm-5.3-flash | opencode | t09-poolrace | pass | 64.7 | 1 | 138.5k | 34.7k | 763 | 103104/0 | 1/7/4 | 2830c91 |
| glm-5.3-flash | opencode | t10-iniparse | invalid* | 50.6 | 1 | 105.4k | 26.8k | 675 | 77888/0 | 2/8/5 | 2830c91 |
| glm-5.3-flash | opencode | t11-asyncbugs | pass | 41.8 | 1 | 86.7k | 21.5k | 629 | 64640/0 | 1/6/4 | 2830c91 |
| glm-5.3-flash | opencode | t12-refactor | pass | 57.2 | 1 | 142.6k | 23.2k | 749 | 118656/0 | 1/2/4 | 2830c91 |
| glm-5.3-flash | opencode | t13-batchrename | pass | 36.9 | 1 | 85.7k | 19.7k | 209 | 65792/0 | 26/27/27 | 2830c91 |
| glm-5.3-flash | opencode | t14-todosweep | pass | 34.3 | 1 | 51.6k | 37.2k | 262 | 14144/0 | 1/18/0 | 2830c91 |
| glm-5.3-flash | opencode | t15-pollstats | pass | 47.5 | 1 | 103.6k | 34.8k | 610 | 68160/0 | 1/1/0 | 2830c91 |
| glm-5.3-flash | opencode | t16-apisum | pass | 48 | 1 | 85.5k | 37.9k | 504 | 47104/0 | 2/20/0 | 2830c91 |
| glm-5.3-flash | opencode | t17-doccheck | pass | 131.7 | 1 | 216.3k | 65.7k | 2682 | 147840/0 | 10/114/0 | 2830c91 |

*`invalid*` = tests pass but protected files (tests) were modified.*

## Per-combo summary

| model | harness | run | cells | pass | invalid | fail | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff f/i/d |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | niffler | 5aa8c97 | 17 | 17 | 0 | 0 | 25 | 43.7k | 2.9k | 38.4k | 2.4k | 3/29/7 |
| deepseek-v4-flash | niffler-expert | 5aa8c97 | 17 | 17 | 0 | 0 | 22 | 43.8k | 4.8k | 36.9k | 2.2k | 3/28/6 |
| deepseek-v4-flash | pi | 2830c91 | 17 | 16 | 1 | 0 | 41 | 36.6k | 3.2k | 29.3k | 4.1k | 3/34/7 |
| deepseek-v4-flash | opencode | 2830c91 | 17 | 16 | 1 | 0 | 42 | 117.8k | 17.2k | 99.5k | 1.0k | 3/29/7 |
| glm-5.3-flash | niffler | 5aa8c97 | 17 | 17 | 0 | 0 | 49 | 32.0k | 9.7k | 21.4k | 0.8k | 3/33/8 |
| glm-5.3-flash | niffler-expert | 5aa8c97 | 17 | 17 | 0 | 0 | 34 | 31.4k | 9.1k | 21.6k | 0.7k | 3/24/7 |
| glm-5.3-flash | pi | 2830c91 | 17 | 16 | 1 | 0 | 33 | 18.5k | 8.8k | 9.0k | 0.7k | 3/27/6 |
| glm-5.3-flash | opencode | 2830c91 | 17 | 16 | 1 | 0 | 84 | 127.2k | 35.3k | 90.9k | 1.0k | 3/33/8 |
