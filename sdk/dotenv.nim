## Tiny .env loader — KEY=VALUE lines, # comments, optional "quotes".
## Existing environment variables always win (standard dotenv behavior).

import std/[os, strutils]

proc loadDotEnv*(paths: varargs[string]) =
  for path in paths:
    if not fileExists(path): continue
    for line in lines(path):
      let trimmed = line.strip()
      if trimmed.len == 0 or trimmed.startsWith("#"): continue
      let eq = trimmed.find('=')
      if eq <= 0: continue
      let key = trimmed[0 ..< eq].strip()
      var value = trimmed[eq + 1 .. ^1].strip()
      if value.len >= 2 and value[0] == '"' and value[^1] == '"':
        value = value[1 .. ^2]
      if key.len > 0 and not existsEnv(key):
        putEnv(key, value)
