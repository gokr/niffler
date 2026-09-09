# logrollup

`logs/` holds 36 rotated log files, one line per event:

```
2026-08-14T09:03:21Z INFO auth: session created for user u123
```

(token ISO timestamp, level, `module: message`). Produce `summary.json` at
the repository root containing, for **every** log file: the number of lines,
the count per level, and the first and last timestamps.

`summary.json` must match this canonical form byte-for-byte (it is what
`check.py` recomputes and compares):

- top-level object with a single key `files`, a list sorted by file name;
- each entry has exactly the keys `name`, `lines`, `levels`, `first`,
  `last`, in that order;
- `levels` always contains all four keys `DEBUG`, `INFO`, `WARN`, `ERROR`
  in that order — a level that never occurs is `0`;
- `first`/`last` are the raw timestamps of the first/last line;
- JSON with 2-space indentation and a single trailing newline.

Shape example (one entry — the real file has all 36):

```json
{
  "name": "app-01.log",
  "lines": 221,
  "levels": {
    "DEBUG": 98,
    "INFO": 81,
    "WARN": 24,
    "ERROR": 18
  },
  "first": "2026-08-14T09:33:44Z",
  "last": "2026-08-14T10:23:45Z"
}
```

The logs are read-only input; do not modify anything under `logs/`.
`./test.sh` runs the check and must exit 0.
