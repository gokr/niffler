# cronnext — cron expression parser + next-run calculator

Grammar (5 fields, whitespace-separated): `minute hour day-of-month month day-of-week`

- Ranges `a-b`, steps `*/n` and `a-b/n`, lists `a,b,c` (mixable:
  `1-5,35`), names `jan..dec` / `sun..sat` (case-insensitive, usable in
  ranges: `mon-wed`).
- Ranges are inclusive; `a-b` with `a > b` is a `CronError`; step 0 is an
  error; out-of-range values are errors (minute 0-59, hour 0-23, dom 1-31,
  month 1-12, dow 0-7 with **7 normalised to 0 = Sunday**).
- **Day matching rule (vixie cron):** if BOTH day-of-month and day-of-week
  are restricted (i.e. the field is not exactly `*`), the day matches when
  EITHER matches. If only one is restricted (or both are `*`), both fields
  must match.
- `matches(dt)`: minute-precision equality against all five fields.
- `next_after(dt)`: strictly after `dt`. Search forward day by day (apply
  the day rule + month), then pick the smallest allowed hour/minute after
  the search start. If nothing matches within 4 years, raise `NoNext`
  (subclass of `CronError`). Parse errors raise `CronError`.
