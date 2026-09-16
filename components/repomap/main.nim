## repomap component — the ranked repo map (docs/research/REPOMAP.md).
##
## Two surfaces, one job: orient a conversation in a workspace.
##
## - tool `repo_map {workspace?, focus?, mentionedIdents?, budget?}`:
##   onDemand, read-effect. The ranked, budget-capped map — the model's
##   explicit pull, and the only surface on by default.
## - auto-append (**opt-in**, NIF_REPOMAP_AUTOAPPEND=1): core announces every
##   conversation workspace on ev.workspace.opened (already carries the
##   conversation id). We build the map and publish it to
##   svc.session.<id>.map, where the session runner drains it
##   (core/dispatch.nim pumpMap) and appends it to history once. The map
##   arrives rather than being sought, because onDemand tools never activate
##   on their own (zero discover calls in 58 Multi10 cells) — but the A/B says
##   paying for it up front is net-negative, hence opt-in: see
##   bench/reports/repomap-ab-{full30,multi10}.md.
##
## Every failure is silent or a structured error: no language server, no
## grammars for the languages present, an unreadable file — none of it may
## fail a conversation. Cache: per-file JSON under var/repomap-tags/
## (mtime-keyed, the aider pattern); a cache failure degrades to in-memory.

import std/[json, os, sequtils, strutils, tables, times]

import checksums/sha1
import natsnim
import niffler/sdk
import tags, score, repomap

const
  MAP_DEFAULT_BUDGET = 1024    # ~4KB of map; aider's default
  MAP_MAX_BUDGET = 4096
  WALK_MAX_FILES = 5000        # census cap (same as lsp warmup)
  WALK_BUDGET_SECS = 5.0       # census wall-clock budget
  BUILD_TIMEOUT_MS = 90_000    # per-build cap inside the tool's 120s
  TAGS_CACHE_DIR = "var" / "repomap-tags"   # CACHE_VERSION lives in the dir
                                             # name when the format changes

const skipDirs = ["node_modules", "vendor", "dist", "build", "target",
                  "__pycache__", ".venv", "venv", "nimcache", "obj",
                  ".gradle", ".next", ".cache", ".tox", "site-packages",
                  ".git", "var", "logs", "scratch", ".worktrees", "docs",
                  "website"]

func cachePath(absFile: string): string =
  rootDir() / TAGS_CACHE_DIR / ($secureHash(absFile)) & ".json"

proc loadCachedTags(absFile: string, mtime: float): seq[Tag] =
  ## mtime-keyed per-file cache; a corrupt or stale entry is a miss. Any
  ## error degrades to a miss (the cache doctrine: never correctness).
  let cp = cachePath(absFile)
  if not fileExists(cp): return
  try:
    let doc = parseJson(readFile(cp))
    if doc{"mtime"}.getFloat(0.0) == mtime and doc{"tags"}.kind == JArray:
      for t in doc{"tags"}:
        result.add(Tag(relFname: t{"rel"}.getStr(""),
                       fname: absFile,
                       line: t{"line"}.getInt(-1),
                       col: t{"col"}.getInt(-1),
                       name: t{"name"}.getStr(""),
                       kind: (if t{"kind"}.getStr("") == "def": kDef else: kRef),
                       symKind: t{"symKind"}.getStr("")))
  except CatchableError:
    return

proc saveCachedTags(absFile: string, mtime: float, rel: string,
                    tags: seq[Tag]) =
  try:
    let arr = newJArray()
    for t in tags:
      arr.add(%*{"line": t.line, "col": t.col, "name": t.name,
                 "kind": (if t.kind == kDef: "def" else: "ref"),
                 "symKind": t.symKind, "rel": rel})
    let doc = %*{"mtime": mtime, "tags": arr}
    let cp = cachePath(absFile)
    createDir(cp.parentDir)
    let tmp = cp & ".tmp-" & $secureHash(cp & $epochTime())
    writeFile(tmp, $doc)
    moveFile(tmp, cp)
  except CatchableError:
    discard  # in-memory only

proc census(ws: string): seq[string] =
  ## Bounded source-file census of the workspace (extension coverage of the
  ## tags tiers: .nim/.nims/.go/.py/.ts). Hidden dirs and known junk are
  ## skipped; caps keep huge trees O(budget).
  var deadline = epochTime() + WALK_BUDGET_SECS
  var stack = @[ws]
  while stack.len > 0 and result.len < WALK_MAX_FILES and
      epochTime() < deadline:
    let dir = stack.pop()
    for kind, path in walkDir(dir, checkDir = true):
      if result.len >= WALK_MAX_FILES or epochTime() >= deadline: break
      case kind
      of pcDir:
        let name = splitFile(path).name
        if name.len > 0 and name[0] == '.': continue
        if name in skipDirs: continue
        stack.add(path)
      of pcFile:
        let ext = splitFile(path).ext.toLowerAscii()
        if ext in [".nim", ".nims", ".go", ".py", ".ts", ".js", ".c", ".h",
                   ".cpp", ".hpp", ".cc", ".hh", ".cxx", ".hxx", ".rs", ".rb"]:
          result.add(path)
        elif splitFile(path).name in ["README", "README.md", "Makefile",
            "package.json", "Cargo.toml", "go.mod", "config.nims"]:
          # special files ride along as bare map entries
          result.add(path)
      else: discard

proc relTo(ws, p: string): string =
  ## workspace-relative render path (forward slashes; the model's view)
  let r = if p.startsWith(ws): p[ws.len ..< p.len] else: p
  return r.strip(chars = {'/'}).replace('\\', '/')

proc buildFor(ws: string, opts: ScoreOptions): string =
  ## Census + cached tags + scored map. Deterministic for identical repo
  ## state (sorted census, stable scoring), so the same workspace yields a
  ## byte-identical map — the append's cache-stability requirement.
  let wsAbs = absolutePath(ws)
  let srcFiles = census(wsAbs)
  if srcFiles.len == 0: return ""
  var tagsOf = proc(rel: string): seq[Tag] =
    let abs = wsAbs / rel
    if not fileExists(abs): return
    let mtime = getLastModificationTime(abs).toUnixFloat()
    var t = loadCachedTags(abs, mtime)
    if t.len == 0:
      # parse on miss; never cache an empty result — a transient failure
      # (unreadable file, missing queries dir) must not poison the cache
      # until the file's mtime changes
      try:
        t = extractTags(rel, abs, readFile(abs))
        if t.len > 0: saveCachedTags(abs, mtime, rel, t)
      except CatchableError:
        return
    return t
  # score.nim sorts; give it workspace-relative paths
  let rels = srcFiles.mapIt(relTo(wsAbs, it))
  var opts2 = opts
  # focus paths arrive relative to the workspace already
  return buildMap(rels, opts2, tagsOf)

proc resolveFocus(ws: string, args: JsonNode): seq[string] =
  if args{"focus"} == nil or args{"focus"}.kind != JArray: return
  for f in args{"focus"}:
    if f.kind != JString: continue
    var p = f.getStr("")
    if p.len == 0: continue
    if not p.isAbsolute(): p = ws / p
    result.add(relTo(absolutePath(ws), absolutePath(p)))

proc hRepoMap(c: Component, args: JsonNode): JsonNode =
  if args == nil or args.kind != JObject:
    raise newException(ValueError, "[E_BAD_SHAPE] repo_map request must be an object.")
  var ws = args{"workspace"}.getStr("")
  if ws.len == 0: ws = rootDir()
  if not ws.isAbsolute(): ws = rootDir() / ws
  if not dirExists(ws):
    raise newException(ValueError,
      "[E_NOT_FOUND] workspace directory not found: " & ws)
  if args{"focus"} != nil and args{"focus"}.kind != JArray:
    raise newException(ValueError,
      "[E_BAD_SHAPE] \"focus\" must be an array of file paths.")
  var budget = args{"budget"}.getInt(MAP_DEFAULT_BUDGET)
  if budget > MAP_MAX_BUDGET: budget = MAP_MAX_BUDGET
  var mentioned: seq[string]
  if args{"mentionedIdents"} != nil and args{"mentionedIdents"}.kind == JArray:
    for i in args{"mentionedIdents"}:
      if i.kind == JString and i.getStr("").len > 0:
        mentioned.add(i.getStr(""))
  let opts = ScoreOptions(focus: resolveFocus(ws, args),
                          mentionedIdents: mentioned,
                          budgetTokens: budget)
  let t0 = epochTime()
  let map = buildFor(absolutePath(ws), opts)
  let ms = ((epochTime() - t0) * 1000).int
  if map.len == 0:
    return %*{"ok": true,
              "text": "No map: no supported source files found in " &
                      ws & " (tiers cover .nim/.nims/.go/.py/.ts).",
              "files": 0}
  return %*{"ok": true, "text": map, "budget": budget, "buildMs": ms,
            "note": "snapshot of the workspace now — files you edit change it; call again for a fresh one"}

# ---------------------------------------------------------------------------
# component

let comp = newComponent("repomap", "0.1.0")

discard comp.tool("repo_map", toolSchema(%*{
  "workspace": {"type": "string",
           "description": "Directory to map (inside the conversation workspace); defaults to it"},
  "focus": {"type": "array", "items": {"type": "string"},
           "description": "Files the conversation is working on, relative to the workspace (the map ranks around them — their own definitions are omitted, you have them open)"},
  "mentionedIdents": {"type": "array", "items": {"type": "string"},
           "description": "Symbol names the task mentions — boosted in the ranking"},
  "budget": {"type": "integer", "minimum": 32, "maximum": 4096,
           "description": "Map size in tokens (default 1024, max 4096)"}
}, @[],
  "A ranked map of a workspace: the load-bearing files and their key definitions, in ~1KB. Use it to orient in an unfamiliar repo or to re-orient after a big refactor — it answers what the repo contains and what matters, before any grep or read. Pass focus (files you are working on) to rank around your work; pass mentionedIdents for symbols the task names. The map is a snapshot: it does not track your edits — call again for a fresh one. It is also appended to the conversation automatically at start when available."), hRepoMap,
  %*{"timeoutMs": 300000, "onDemand": true, "effect": "read",
     "workspace": {"pathFields": ["workspace"]}})

# ---------------------------------------------------------------------------
# auto-append: ev.workspace.opened -> svc.session.<id>.map

discard comp.on("ev.workspace.opened") do (c: Component, subject: string,
                                           payload: JsonNode):
  # Fire-and-forget from core's side, silent on our side: a map that never
  # arrives must never fail a conversation. The map goes to the session
  # runner's private .map subject; the runner drains it and appends once
  # (core/dispatch.nim pumpMap -> conversation drainMap).
  #
  # OFF BY DEFAULT: the A/B did not clear the bar in either suite. full30
  # (the regression gate) stayed 30/30 but cost ~40% more tokens; Multi10 on
  # real OSS repos (the value probe) scored 8/10 with the map against 9/10
  # without, at 3.7x the tokens (252k vs 68k per cell) — the one flipped cell
  # was a redis timeout at 7.0M tokens. See bench/reports/repomap-ab-full30.md
  # and repomap-ab-multi10.md.
  #
  # Set NIF_REPOMAP_AUTOAPPEND=1 to turn the append back on. Nothing about the
  # component is disabled either way: repo_map stays registered, onDemand and
  # read-effect, so the map is a tool the model discovers when a large
  # unfamiliar repo warrants it rather than context injected into every
  # conversation (the model asks, nothing is injected).
  if getEnv("NIF_REPOMAP_AUTOAPPEND", "0") notin ["1", "true", "yes"]:
    return
  let ws = payload{"workspace"}.getStr("")
  let convId = payload{"conversationId"}.getStr("")
  if ws.len == 0 or convId.len == 0 or not dirExists(ws): return
  try:
    let map = buildFor(absolutePath(ws), ScoreOptions(
        budgetTokens: MAP_DEFAULT_BUDGET))
    if map.len == 0: return
    publish(c.nc, "svc.session." & sanitizeSessionId(convId) & ".map",
      Envelope(v: 1, id: newId(), kind: ekEvent,
               payload: %*{"workspace": ws, "conversationId": convId,
                           "map": map}).encode())
    c.log("info", "repo map published for " & convId & " (" &
          $map.len & " bytes)")
  except CatchableError as e:
    c.log("info", "repo map build failed: " & e.msg)

discard comp.selfTest(proc(c: Component, args: JsonNode): JsonNode =
  ## /doctor deep: map a tiny temp workspace and require real defs.
  var ok = true
  var checks = newJArray()
  proc check(name: string, cond: bool, detail = "") =
    checks.add(%*{"name": name, "ok": cond,
                  "detail": (if cond: "" else: detail)})
    if not cond: ok = false
  try:
    let dir = getTempDir() / ("niffler-repomap-selftest-" & $secureHash(
        $epochTime()))
    createDir(dir)
    writeFile(dir / "a.nim", "proc alpha(x: int): int =\n  x\n\n" &
        "proc beta(): int =\n  alpha(2)\n")
    writeFile(dir / "b.py", "class Alpha:\n    def walk(self):\n        pass\n")
    let m = buildFor(absolutePath(dir), ScoreOptions(budgetTokens: 512))
    check("nim+py map has defs", m.contains("alpha") and
          m.contains("walk"), m)
    check("map mentions both files", m.contains("a.nim") and
          m.contains("b.py"), m)
    removeDir(dir)
  except CatchableError as e:
    check("selftest build", false, e.msg)
  return %*{"ok": ok,
            "summary": (if ok: "repo map green" else: "repo map failures above"),
            "checks": checks})

comp.run()
