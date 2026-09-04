# logsum

A tiny command-line tool that summarizes a log file. The implementation in
`src/logsum/cli.py` is missing — implement it per this spec:

    python3 -m logsum <file> [--level LEVEL] [--top N] [--after "YYYY-MM-DD HH:MM:SS"]

Input lines have the form `YYYY-MM-DD HH:MM:SS LEVEL message` (LEVEL is one
of DEBUG, INFO, WARN, ERROR; the message is the rest of the line and may
contain spaces).

The output is plain text, in this exact order:

1. `total N` — number of lines considered.
2. For every level that appears, in the order DEBUG, INFO, WARN, ERROR:
   `LEVEL count` (skip levels with zero lines).
3. `top:` followed by the N most frequent exact messages (default N=3),
   one per line, as `  M message`, ordered by count descending, ties broken
   alphabetically.

Options:
- `--level LEVEL`: consider only lines of that level.
- `--top N`: report the top N messages instead of 3.
- `--after TS`: consider only lines at or after that timestamp
  (string comparison is fine; timestamps are zero-padded).

Run `./test.sh` to test.
