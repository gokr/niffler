# logfilter — mini query language for structured logs

Grammar (case-sensitive keywords, whitespace-separated):

```
or_expr   := and_expr ("or" and_expr)*
and_expr  := not_expr ("and" not_expr)*
not_expr  := "not" not_expr | primary
primary   := "(" or_expr ")" | comparison
comparison:= field op value
op        := "=" | "!=" | "~=" | ">=" | "<=" | ">" | "<"
field     := bareword  (letters, digits, "_", ".", "-")
value     := number | quoted string | bareword
```

- Numbers: optional leading `-`, digits, optional `.digits`. Barewords are
  strings, except `true`/`false` which become booleans.
- Quoted strings use single quotes; `\'` and `\\` are the only escapes.
- **Precedence**: `not` > `and` > `or`. Parentheses group.
- Matching:
  - Missing fields NEVER match any comparison — not even `!=`.
  - `=`/`!=` are type-sensitive: `1` does not equal `true` or `"1"`.
    (`3` vs `3.0`: int vs float — use `==` on parsed numbers, so equal.)
  - `~=`: regex **fullmatch** against `str(field_value)`. The pattern is
    compiled at parse time; a bad regex raises `QueryError` immediately.
  - `> >= < <=`: numeric only — False if either side is not an int/float
    (booleans are not numbers).
- Errors raise `QueryError(msg, pos)` with the 0-based character offset in
  the original query string: unterminated string, unexpected character,
  trailing tokens, unbalanced parentheses, missing operands, bad regex.
