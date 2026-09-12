## Pure version-tag selection for the plugins component.
##
## GitHub *releases* are the primary "what should I pin" signal, but plenty
## of component packages only push tags — gokr/niffler-tui publishes tags
## and no releases at all — so resolveTag falls back to the highest
## version-looking tag from /tags. Without that fallback a tag-pinned
## install on a release-less repo can never be updated: plugin_update sees
## "no releases", re-pulls the pinned tag, and reports updated:false
## forever.
##
## Dependency-free and side-effect-free on purpose: tests/t_plugins.nim
## imports this module directly for hermetic coverage.

import std/strutils

proc versionParts(tag: string): seq[int] =
  ## Numeric parts of a version-looking tag, after an optional leading
  ## `v`/`V`: "v1.2.3" → @[1, 2, 3], "1.2" → @[1, 2]. Empty when the tag
  ## does not start with a number ("nightly", "release-2024") — such tags
  ## are not versions and must never be chosen as a pin.
  var t = tag.strip()
  if t.len > 0 and (t[0] == 'v' or t[0] == 'V'): t = t[1 .. ^1]
  for part in t.split('.'):
    var num = ""
    for ch in part:
      if ch in {'0' .. '9'}: num.add(ch)
      else: break
    if num.len == 0: break
    try:
      result.add(parseInt(num))
    except CatchableError:
      break

proc tagSuffix(tag: string): string =
  ## What follows the numeric part of a tag: "-rc1" for "v2.0.0-rc1", ""
  ## for a plain "v2.0.0".
  var t = tag.strip()
  if t.len > 0 and (t[0] == 'v' or t[0] == 'V'): t = t[1 .. ^1]
  var i = 0
  while i < t.len and (t[i] in {'0' .. '9', '.'}): inc i
  if i >= t.len: "" else: t[i .. ^1]

proc cmpVersion(a, b: seq[int]): int =
  ## Lexicographic with zero-extension, so 1.2 == 1.2.0 and 1.2.1 > 1.2.
  for i in 0 ..< max(a.len, b.len):
    let av = if i < a.len: a[i] else: 0
    let bv = if i < b.len: b[i] else: 0
    if av != bv: return (if av > bv: 1 else: -1)
  0

proc latestVersionTag*(tags: seq[string]): string =
  ## Highest version-looking tag in `tags`; "" when none looks like a
  ## version. Ties break toward the plain tag ("v2.0.0" beats
  ## "v2.0.0-rc1"), then toward the later entry in the list, so a repo's
  ## newest tag wins between equals.
  var best: seq[int] = @[]
  var bestPlain = false
  for tag in tags:
    let parts = versionParts(tag)
    if parts.len == 0: continue
    let plain = tagSuffix(tag).len == 0
    if result.len == 0:
      result = tag
      best = parts
      bestPlain = plain
      continue
    let c = cmpVersion(parts, best)
    if c > 0 or (c == 0 and plain and not bestPlain):
      result = tag
      best = parts
      bestPlain = plain
