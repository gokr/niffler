# bench report — swe-sympy10-all4-8b50354

| model | harness | task | verdict | time (s) | rounds | tok total | uncached in | tok out | cache r/w | cost $ | diff (+/-) |
|---|---|---|---|---:|---:|---:|---:|---:|---|---:|---|
| deepseek-v4-flash | codewhale | sympy__sympy-11618 | pass | 120.3 | 1 | 410.7k | 207.1k | 9.3k | 194.3k/0 | 0.0000 | 11/2 |
| deepseek-v4-flash | codewhale | sympy__sympy-12096 | pass | 442.8 | 1 | 2129.0k | 1057.6k | 48.3k | 1023.1k/0 | 0.0000 | 13/1 |
| deepseek-v4-flash | codewhale | sympy__sympy-12419 | pass | 610.1 | 1 | 4366.8k | 2176.1k | 65.9k | 2124.8k/0 | 0.0000 | 2/5 |
| deepseek-v4-flash | codewhale | sympy__sympy-12481 | pass | 251.4 | 1 | 1272.1k | 629.7k | 28.1k | 614.3k/0 | 0.0000 | 2/6 |
| deepseek-v4-flash | codewhale | sympy__sympy-12489 | pass | 450 | 1 | 5611.2k | 2791.6k | 52.2k | 2767.4k/0 | 0.0000 | 30/30 |
| deepseek-v4-flash | codewhale | sympy__sympy-13031 | pass | 425.2 | 1 | 3831.5k | 1911.7k | 39.2k | 1880.6k/0 | 0.0000 | 6/4 |
| deepseek-v4-flash | codewhale | sympy__sympy-13091 | fail | 252 | 1 | 1074.2k | 532.2k | 27.1k | 514.9k/0 | 0.0000 | 5/2 |
| deepseek-v4-flash | codewhale | sympy__sympy-13372 | pass | 83.4 | 1 | 102.6k | 55.4k | 1.4k | 45.8k/0 | 0.0000 | 4/0 |
| deepseek-v4-flash | codewhale | sympy__sympy-13480 | pass | 102 | 1 | 235.4k | 120.5k | 5.1k | 109.7k/0 | 0.0000 | 1/1 |
| deepseek-v4-flash | codewhale | sympy__sympy-13551 | pass | 353.2 | 1 | 1396.0k | 688.1k | 38.5k | 669.3k/0 | 0.0000 | 11/4 |
| deepseek-v4-flash | niffler | sympy__sympy-11618 | pass | 61.9 | 1 | 133.9k | 14.8k | 1.4k | 117.6k/0 | 0.0000 | 3/3 |
| deepseek-v4-flash | niffler | sympy__sympy-12096 | pass | 80 | 1 | 51.4k | 2.6k | 4.7k | 44.2k/0 | 0.0000 | 1/1 |
| deepseek-v4-flash | niffler | sympy__sympy-12419 | pass | 112.3 | 1 | 218.1k | 10.4k | 8.5k | 199.2k/0 | 0.0000 | 2/5 |
| deepseek-v4-flash | niffler | sympy__sympy-12481 | pass | 173 | 1 | 633.2k | 29.7k | 13.5k | 590.0k/0 | 0.0000 | 4/7 |
| deepseek-v4-flash | niffler | sympy__sympy-12489 | pass | 250.1 | 1 | 866.7k | 18.2k | 27.3k | 821.2k/0 | 0.0000 | 25/25 |
| deepseek-v4-flash | niffler | sympy__sympy-13031 | fail | 582.8 | 1 | 2839.6k | 31.7k | 69.5k | 2738.4k/0 | 0.0000 | 0/0 |
| deepseek-v4-flash | niffler | sympy__sympy-13091 | fail | 138 | 1 | 233.7k | 10.1k | 12.9k | 210.7k/0 | 0.0000 | 5/2 |
| deepseek-v4-flash | niffler | sympy__sympy-13372 | pass | 138.6 | 1 | 177.4k | 8.9k | 8.8k | 159.7k/0 | 0.0000 | 4/0 |
| deepseek-v4-flash | niffler | sympy__sympy-13480 | pass | 74 | 1 | 58.7k | 3.7k | 2.0k | 53.0k/0 | 0.0000 | 1/1 |
| deepseek-v4-flash | niffler | sympy__sympy-13551 | pass | 327.8 | 1 | 543.0k | 14.6k | 32.0k | 496.4k/0 | 0.0000 | 10/4 |
| deepseek-v4-flash | opencode | sympy__sympy-11618 | pass | 392.7 | 1 | 1072.9k | 24.1k | 4.1k | 1044.6k/0 | 0.0184 | 10/2 |
| deepseek-v4-flash | opencode | sympy__sympy-12096 | pass | 320.7 | 1 | 1168.9k | 35.4k | 4.2k | 1129.2k/0 | 0.0174 | 1/1 |
| deepseek-v4-flash | opencode | sympy__sympy-12419 | pass | 965.7 | 1 | 5239.2k | 56.3k | 12.9k | 5169.9k/0 | 0.0488 | 2/4 |
| deepseek-v4-flash | opencode | sympy__sympy-12481 | pass | 269.9 | 1 | 855.5k | 29.2k | 3.8k | 822.4k/0 | 0.0148 | 2/6 |
| deepseek-v4-flash | opencode | sympy__sympy-12489 | pass | 659.9 | 1 | 6060.3k | 80.2k | 17.4k | 5962.8k/0 | 0.0465 | 33/33 |
| deepseek-v4-flash | opencode | sympy__sympy-13031 | pass | 626.6 | 1 | 4523.4k | 57.6k | 9.5k | 4456.3k/0 | 0.0379 | 12/8 |
| deepseek-v4-flash | opencode | sympy__sympy-13091 | pass | 471.9 | 1 | 3151.6k | 50.4k | 8.7k | 3092.5k/0 | 0.0291 | 25/9 |
| deepseek-v4-flash | opencode | sympy__sympy-13372 | pass | 110.9 | 1 | 133.4k | 21.0k | 1.2k | 111.2k/0 | 0.0041 | 4/0 |
| deepseek-v4-flash | opencode | sympy__sympy-13480 | pass | 73.1 | 1 | 73.9k | 16.7k | 628 | 56.6k/0 | 0.0028 | 1/1 |
| deepseek-v4-flash | opencode | sympy__sympy-13551 | pass | 537.8 | 1 | 1566.2k | 36.9k | 3.3k | 1526.0k/0 | 0.0261 | 11/3 |
| deepseek-v4-flash | pi | sympy__sympy-11618 | pass | 55.1 | 1 | 19.7k | 2.4k | 1.0k | 16.3k/0 | 0.0023 | 5/2 |
| deepseek-v4-flash | pi | sympy__sympy-12096 | pass | 214.6 | 1 | 395.5k | 8.9k | 21.6k | 365.1k/0 | 0.0373 | 10/1 |
| deepseek-v4-flash | pi | sympy__sympy-12419 | pass | 192.7 | 1 | 554.5k | 27.5k | 15.9k | 511.1k/0 | 0.0402 | 4/1 |
| deepseek-v4-flash | pi | sympy__sympy-12481 | pass | 177.2 | 1 | 315.7k | 10.6k | 18.0k | 287.1k/0 | 0.0316 | 16/5 |
| deepseek-v4-flash | pi | sympy__sympy-12489 | pass | 373.7 | 1 | 1021.7k | 20.8k | 24.9k | 976.0k/0 | 0.0617 | 23/23 |
| deepseek-v4-flash | pi | sympy__sympy-13031 | pass | 694.6 | 1 | 4034.6k | 37.2k | 79.2k | 3918.2k/0 | 0.2105 | 8/6 |
| deepseek-v4-flash | pi | sympy__sympy-13091 | fail | 183.4 | 1 | 346.9k | 15.9k | 18.1k | 312.8k/0 | 0.0339 | 5/2 |
| deepseek-v4-flash | pi | sympy__sympy-13372 | pass | 87.5 | 1 | 13.1k | 2.6k | 1.0k | 9.5k/0 | 0.0021 | 4/0 |
| deepseek-v4-flash | pi | sympy__sympy-13480 | pass | 65.2 | 1 | 20.2k | 2.8k | 1.2k | 16.3k/0 | 0.0026 | 1/1 |
| deepseek-v4-flash | pi | sympy__sympy-13551 | pass | 180 | 1 | 323.6k | 14.2k | 14.2k | 295.2k/0 | 0.0285 | 10/5 |
| glm-5.3-flash | codewhale | sympy__sympy-11618 | fail | 372 | 1 | 271.4k | 150.3k | 10.7k | 110.4k/0 | 0.0000 | 6/1 |
| glm-5.3-flash | codewhale | sympy__sympy-12096 | pass | 144.4 | 1 | 144.3k | 76.5k | 2.9k | 64.9k/0 | 0.0000 | 1/1 |
| glm-5.3-flash | codewhale | sympy__sympy-12419 | pass | 1706.7 | 1 | 3214.5k | 1640.9k | 64.0k | 1509.6k/0 | 0.0000 | 2/1 |
| glm-5.3-flash | codewhale | sympy__sympy-12481 | pass | 671.6 | 1 | 1005.6k | 510.7k | 22.8k | 472.1k/0 | 0.0000 | 10/6 |
| glm-5.3-flash | codewhale | sympy__sympy-12489 | pass | 1664.3 | 1 | 8344.1k | 4224.6k | 61.8k | 4057.7k/0 | 0.0000 | 28/28 |
| glm-5.3-flash | codewhale | sympy__sympy-13031 | pass | 1728.3 | 1 | 3044.3k | 1534.9k | 57.4k | 1452.0k/0 | 0.0000 | 8/4 |
| glm-5.3-flash | codewhale | sympy__sympy-13091 | fail | 1330.9 | 1 | 2928.6k | 1496.3k | 42.6k | 1389.7k/0 | 0.0000 | 3/3 |
| glm-5.3-flash | codewhale | sympy__sympy-13372 | pass | 170.1 | 1 | 167.4k | 88.5k | 2.4k | 76.5k/0 | 0.0000 | 4/0 |
| glm-5.3-flash | codewhale | sympy__sympy-13480 | pass | 131 | 1 | 147.9k | 83.3k | 2.2k | 62.4k/0 | 0.0000 | 1/1 |
| glm-5.3-flash | codewhale | sympy__sympy-13551 | pass | 1008.5 | 1 | 2017.6k | 1020.7k | 38.2k | 958.7k/0 | 0.0000 | 13/1 |
| glm-5.3-flash | niffler | sympy__sympy-11618 | pass | 150.9 | 1 | 68.8k | 24.5k | 1.4k | 42.9k/0 | 0.0000 | 6/2 |
| glm-5.3-flash | niffler | sympy__sympy-12096 | pass | 75.8 | 1 | 17.8k | 7.9k | 294 | 9.7k/0 | 0.0000 | 1/1 |
| glm-5.3-flash | niffler | sympy__sympy-12419 | pass | 687.5 | 1 | 292.0k | 48.5k | 20.0k | 223.6k/0 | 0.0000 | 118/1 |
| glm-5.3-flash | niffler | sympy__sympy-12481 | pass | 116.4 | 1 | 49.6k | 7.1k | 1.1k | 41.5k/0 | 0.0000 | 4/2 |
| glm-5.3-flash | niffler | sympy__sympy-12489 | fail | 156.4 | 1 | 64.2k | 9.5k | 2.1k | 52.7k/0 | 0.0000 | 8/8 |
| glm-5.3-flash | niffler | sympy__sympy-13031 | pass | 849 | 1 | 1078.5k | 61.9k | 25.7k | 991.0k/0 | 0.0000 | 8/4 |
| glm-5.3-flash | niffler | sympy__sympy-13091 | fail | 80.5 | 1 | 34.8k | 6.5k | 586 | 27.7k/0 | 0.0000 | 1/1 |
| glm-5.3-flash | niffler | sympy__sympy-13372 | pass | 105.4 | 1 | 30.2k | 6.1k | 770 | 23.3k/0 | 0.0000 | 4/0 |
| glm-5.3-flash | niffler | sympy__sympy-13480 | pass | 87.6 | 1 | 22.6k | 1.9k | 493 | 20.3k/0 | 0.0000 | 1/1 |
| glm-5.3-flash | niffler | sympy__sympy-13551 | pass | 320 | 1 | 88.2k | 24.8k | 8.7k | 54.7k/0 | 0.0000 | 15/1 |
| glm-5.3-flash | opencode | sympy__sympy-11618 | pass | 468 | 1 | 393.2k | 53.0k | 1.8k | 338.4k/0 | 0.0203 | 9/2 |
| glm-5.3-flash | opencode | sympy__sympy-12096 | pass | 437.9 | 1 | 286.9k | 43.4k | 1.5k | 241.9k/0 | 0.0164 | 1/1 |
| glm-5.3-flash | opencode | sympy__sympy-12419 | pass | 3591.8 | 1 | 4062.2k | 284.8k | 4.6k | 3772.8k/0 | 0.1543 | 2/5 |
| glm-5.3-flash | opencode | sympy__sympy-12481 | pass | 286.5 | 1 | 471.9k | 48.0k | 2.7k | 421.3k/0 | 0.0195 | 10/5 |
| glm-5.3-flash | opencode | sympy__sympy-12489 | pass | 910.9 | 1 | 1288.3k | 154.7k | 7.0k | 1126.6k/0 | 0.0601 | 25/25 |
| glm-5.3-flash | opencode | sympy__sympy-13031 | pass | 1797.3 | 1 | 6370.7k | 179.2k | 17.3k | 6174.2k/0 | 0.1945 | 14/8 |
| glm-5.3-flash | opencode | sympy__sympy-13091 | pass | 1576.6 | 1 | 3078.1k | 115.2k | 7.0k | 2956.0k/0 | 0.1085 | 42/42 |
| glm-5.3-flash | opencode | sympy__sympy-13372 | pass | 159.9 | 1 | 184.8k | 37.8k | 1.4k | 145.7k/0 | 0.0094 | 4/0 |
| glm-5.3-flash | opencode | sympy__sympy-13480 | pass | 123.8 | 1 | 148.9k | 52.0k | 1.1k | 95.8k/0 | 0.0096 | 1/1 |
| glm-5.3-flash | opencode | sympy__sympy-13551 | pass | 1354.9 | 1 | 1156.1k | 116.2k | 3.8k | 1036.1k/0 | 0.0602 | 5/1 |
| glm-5.3-flash | pi | sympy__sympy-11618 | pass | 98.5 | 1 | 38.3k | 18.3k | 1.6k | 18.4k/0 | 0.0000 | 7/2 |
| glm-5.3-flash | pi | sympy__sympy-12096 | pass | 65.4 | 1 | 17.4k | 12.8k | 495 | 4.2k/0 | 0.0000 | 1/1 |
| glm-5.3-flash | pi | sympy__sympy-12419 | fail | 1896.8 | 1 | 1291.3k | 96.9k | 30.8k | 1163.5k/0 | 0.0000 | 17/4 |
| glm-5.3-flash | pi | sympy__sympy-12481 | pass | 80.9 | 1 | 24.5k | 14.5k | 1.3k | 8.7k/0 | 0.0000 | 3/5 |
| glm-5.3-flash | pi | sympy__sympy-12489 | fail | 170.9 | 1 | 58.4k | 32.3k | 4.9k | 21.3k/0 | 0.0000 | 22/22 |
| glm-5.3-flash | pi | sympy__sympy-13031 | fail | 292.2 | 1 | 306.5k | 47.1k | 7.3k | 252.1k/0 | 0.0000 | 0/0 |
| glm-5.3-flash | pi | sympy__sympy-13091 | fail | 78.7 | 1 | 27.2k | 14.6k | 1.3k | 11.3k/0 | 0.0000 | 3/1 |
| glm-5.3-flash | pi | sympy__sympy-13372 | pass | 110.3 | 1 | 30.1k | 14.5k | 1.1k | 14.5k/0 | 0.0000 | 4/0 |
| glm-5.3-flash | pi | sympy__sympy-13480 | pass | 80 | 1 | 19.7k | 3.8k | 833 | 15.1k/0 | 0.0000 | 1/1 |
| glm-5.3-flash | pi | sympy__sympy-13551 | fail | 567.2 | 1 | 169.3k | 36.3k | 20.0k | 112.9k/0 | 0.0000 | 17/12 |

## Per-combo summary

| model | harness | pass rate | avg time (s) | avg tok total | avg uncached in | avg cache read | avg tok out | avg diff (+/-) |
|---|---|---|---:|---:|---:|---:|---:|---|
| deepseek-v4-flash | codewhale | 9/10 | 309 | 2042.9k | 1017.0k | 994.4k | 31.5k | 9/6 |
| deepseek-v4-flash | niffler | 8/10 | 194 | 575.6k | 14.5k | 543.0k | 18.1k | 6/5 |
| deepseek-v4-flash | opencode | 10/10 | 443 | 2384.5k | 40.8k | 2337.2k | 6.6k | 10/7 |
| deepseek-v4-flash | pi | 9/10 | 222 | 704.5k | 14.3k | 670.7k | 19.5k | 9/5 |
| glm-5.3-flash | codewhale | 8/10 | 893 | 2128.6k | 1082.7k | 1015.4k | 30.5k | 8/5 |
| glm-5.3-flash | niffler | 8/10 | 263 | 174.7k | 19.9k | 148.7k | 6.1k | 17/2 |
| glm-5.3-flash | opencode | 10/10 | 1071 | 1744.1k | 108.4k | 1630.9k | 4.8k | 11/9 |
| glm-5.3-flash | pi | 5/10 | 344 | 198.3k | 29.1k | 162.2k | 7.0k | 8/5 |

*`invalid*` = tests pass but protected files (tests) were modified.*
