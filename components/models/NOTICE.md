# Source notice

This component was independently implemented in Go using patterns studied in:

- models.dev (MIT, copyright 2025 models.dev): catalog schema and the embedded
  DeepSeek seed records, fetched from `https://models.dev/api.json` on
  2026-08-24.
- Pi (MIT, copyright 2025 Mario Zechner), commit `a470b121b`: generated catalog
  layering, explicit corrections, strict model resolution, and last-known-good
  dynamic provider behavior.
- OpenCode (MIT, copyright 2025 opencode), commit `41616958`: atomic disk cache,
  cache freshness, retries, embedded fallback, periodic refresh, and provider
  plugin layering.

No source files from Pi or OpenCode are vendored. Their MIT licenses and source
trees remain available in `../pi` and `../opencode` in the development
workspace.
