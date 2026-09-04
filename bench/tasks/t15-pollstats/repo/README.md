# pollstats

`generator.py` prints one measurement per run; it takes a seed:

    python3 generator.py <seed>

Run it once for every seed from 1 through 12, collect the 12 values, and
write `stats.json` with the minimum, maximum and mean, each rounded to two
decimal places:

    {"min": <m>, "max": <M>, "mean": <mu>}

The test suite verifies the numbers. There are many runs to make — use
whatever your harness provides for repetitive, mechanical work.
