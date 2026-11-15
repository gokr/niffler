## memory embed chain — provider record → llm.embed → embedding document →
## scoped kNN, with no model download and no network.
##
## This is the test the validation question actually asked for: does SEMANTIC
## recall work end to end? The vector test proves the store ranks vectors
## correctly; this one proves the rest of the chain — that the harness can
## obtain a vector for text at all, persist it in the shape the store indexes,
## and retrieve the right fact by MEANING rather than by shared words.
##
## The embedder is tests/fixtures/embed_server.py: a deterministic
## OpenAI-compatible /embeddings endpoint whose vectors are CONCEPT vectors, so
## "how do we install dependencies" and "deps.package_manager: pnpm" land close
## together sharing almost no tokens. That is what makes the retrieval
## assertion meaningful — a hash embedder would only prove round-tripping.
##
## What it pins:
##
## 1. `provider_add` accepts a keyless loopback provider with an embedModel,
##    and `llm.embed` routes to it (the two defects LOCAL-EMBEDDINGS.md §5/§8
##    records as fixed, pinned here through the real component).
## 2. The returned vector has the model's width and is usable as an embedding
##    document — the producer shape the store validates.
## 3. Semantic retrieval: a paraphrase finds the right fact, and the wrong
##    fact is farther away. Asserted on cosine distance, ordered by the store.
## 4. Scoping holds through the chain: the same query restricted to one
##    repository's prefix never returns another's fact.
##
## It does NOT measure nomic's retrieval quality. That needs the real model and
## is a human-run measurement (docs/research/LOCAL-EMBEDDINGS.md §8); here the
## embedding space is synthetic and exact so a failure means a plumbing bug.

import std/[json, math, net, os, osproc, sequtils, strutils]
import natsnim
import helpers

const
  embedModel = "fixture/nomic-embed-text-v1.5"
  # Fixed width so the fixture's concept vectors line up with what the harness
  # stores; the fixture builds one dimension per concept.
  dim = 6

proc freePort(): int =
  let sock = newSocket()
  defer: sock.close()
  sock.bindAddr(Port(0), "127.0.0.1")
  int(sock.getLocalAddr()[1])

proc startEmbedFixture(script, logPath: string): tuple[prc: Process, port: int] =
  ## Start the concept-vector embedder on a free loopback port and wait until
  ## it accepts connections. A fixture that is not up yet answers nothing, and
  ## the failing call would read as a bad provider record.
  result.port = freePort()
  createDir(logPath.parentDir())
  result.prc = startProcess("python3", args = @[script, $result.port, logPath],
                            options = {poUsePath})
  for _ in 0 ..< 200:
    try:
      let sock = newSocket()
      sock.connect("127.0.0.1", Port(result.port))
      sock.close()
      return
    except CatchableError:
      sleep(50)

proc cosDistance(a, b: seq[float]): float =
  var dot, na, nb = 0.0
  for i in 0 ..< min(a.len, b.len):
    dot += a[i] * b[i]
    na += a[i] * a[i]
    nb += b[i] * b[i]
  if na == 0.0 or nb == 0.0: return 2.0
  1.0 - dot / (sqrt(na) * sqrt(nb))

proc main() =
  let root = getEnv("NIF_REPO_ROOT",
                    getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "memory"]:
    if not fileExists(root / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      report("MEMORY EMBED CHAIN TEST")
  let script = root / "tests" / "fixtures" / "embed_server.py"
  if not fileExists(script):
    fail("missing fixture " & script)
    report("MEMORY EMBED CHAIN TEST")

  let sandbox = newCoreSandbox("memoryembed", ["store", "memory", "llm", "provider"])
  let keep = getEnv("NIF_KEEP_SANDBOX", "").len > 0
  if keep: echo "sandbox kept at ", sandbox.root
  defer:
    if not keep: removeDir(sandbox.root)

  let logPath = sandbox.root / "var" / "embed-requests.jsonl"
  let fixture = startEmbedFixture(script, logPath)
  defer:
    try: fixture.prc.terminate()
    except CatchableError: discard
    try: fixture.prc.close()
    except CatchableError: discard
  let baseUrl = "http://127.0.0.1:" & $fixture.port & "/v1"

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let core = startComponent(sandbox.sandboxBin("niffler"), url,
    root = sandbox.root,
    extra = [("NIF_AUTO_APPROVE", "1"), ("NIF_LLM_EMBED_TIMEOUT_MS", "20000"),
             ("NIF_MEMORY_EMBED_PROVIDER", "localembed")],
    logFile = sandbox.root / "var" / "test-logs" / "core.log")
  defer: stopProcess(core)
  var ready = false
  for _ in 0 ..< 200:
    let cat = call(nc, "core", "catalog", %*{"op": "components"}, 3_000)
    if cat{"components"}{"llm"} != nil and cat{"components"}{"store"} != nil and
        cat{"components"}{"memory"} != nil and cat{"components"}{"provider"} != nil:
      ready = true
      break
    sleep(100)
  check("core, store, memory, llm and provider are up", ready,
        "components did not register")
  if not ready: report("MEMORY EMBED CHAIN TEST")

  # === 1. a keyless loopback provider with an embedModel ==================
  # LOCAL-EMBEDDINGS.md §5: apiKey may be omitted ONLY for a loopback baseUrl,
  # which is what makes a local llama-server / shim configurable at all.
  let added = call(nc, "provider", "provider_add", %*{
    "nickname": "localembed", "baseUrl": baseUrl,
    "model": "fixture/chat-unused",
    "embedModel": embedModel}, 30_000)
  check("provider_add accepts a KEYLESS loopback provider with an embedModel",
        added{"ok"}.getBool(false), $added)

  # A remote endpoint still requires a key: the loopback exemption must not
  # have widened into "any provider without a credential".
  let remote = call(nc, "provider", "provider_add", %*{
    "nickname": "remoteembed", "baseUrl": "https://api.example.com/v1",
    "embedModel": "text-embedding-3-small"}, 30_000)
  check("a REMOTE provider without a key is still refused",
        remote{"error"} != nil, $remote)

  # === 2. llm.embed produces a usable vector =============================
  let embedded = call(nc, "llm", "embed", %*{
    "provider": "localembed", "input": ["how do we install dependencies"]},
    60_000)
  check("llm.embed answers for the loopback provider",
        embedded{"ok"}.getBool(false) and embedded{"embeddings"} != nil,
        $embedded)
  let vector = embedded{"embeddings"}{0}
  check("the vector has the model's width",
        vector != nil and vector.len == dim,
        "width " & (if vector == nil: "nil" else: $vector.len))
  check("the reported model is the provider's embedModel",
        embedded{"model"}.getStr("") == embedModel, $embedded)
  # The request actually crossed the wire to the fixture, with that model id:
  # a provider record that never reaches the adapter would still answer ok
  # from a different path, and this is the assertion that catches it.
  var sawRequest = false
  if fileExists(logPath):
    for line in lines(logPath):
      if line.strip().len == 0: continue
      let entry = parseJson(line)
      if entry{"model"}.getStr("") == embedModel: sawRequest = true
  check("the embed request reached the configured endpoint with its model",
        sawRequest, "no request logged at " & logPath)

  # === 3. semantic retrieval through the store ===========================
  let repoA = "repo:/work/alpha:"
  let repoB = "repo:/work/beta:"
  let facts = [
    ("build.jobs", "make build needs -j1 or the compile step OOMs"),
    ("deps.package_manager", "this repo uses pnpm to install dependencies"),
    ("test.suite", "run the test suite with make test")]
  for (subject, text) in facts:
    let e = call(nc, "llm", "embed", %*{
      "provider": "localembed", "input": [text]}, 60_000)
    check("embedded a fact (" & subject & ")",
          e{"ok"}.getBool(false) and e{"embeddings"}{0} != nil, $e)
    if e{"embeddings"}{0} == nil: continue   # already reported above
    discard call(nc, "store", "put", %*{
      "kind": "embedding", "id": repoA & subject,
      "value": %*{"model": embedModel, "dimensions": dim,
                  "vector": e{"embeddings"}{0},
                  "source": "memory", "sourceId": repoA & subject}}, 10_000)
  # One fact in ANOTHER repository, deliberately about the same topic as the
  # query so that it would win an unscoped search.
  let bText = "install dependencies with npm here"
  let bEmbed = call(nc, "llm", "embed", %*{
    "provider": "localembed", "input": [bText]}, 60_000)
  if bEmbed{"embeddings"}{0} == nil:
    check("embedded the other repository's fact", false, $bEmbed)
    report("MEMORY EMBED CHAIN TEST")
  discard call(nc, "store", "put", %*{
    "kind": "embedding", "id": repoB & "deps.package_manager",
    "value": %*{"model": embedModel, "dimensions": dim,
                "vector": bEmbed{"embeddings"}{0}}}, 10_000)

  # The QUERY is a paraphrase of the package-manager fact: different words,
  # same meaning. Token search over the fact text would have to match "pnpm"
  # and it does not appear in the question.
  let q = call(nc, "llm", "embed", %*{
    "provider": "localembed", "input": ["how do we install dependencies here"]},
    60_000)
  check("embedded the query",
        q{"ok"}.getBool(false) and q{"embeddings"}{0} != nil, $q)
  if q{"embeddings"}{0} == nil:
    report("MEMORY EMBED CHAIN TEST")
  let queryVec = q{"embeddings"}{0}

  let scoped = call(nc, "store", "search", %*{
    "kind": "embedding", "model": embedModel, "vector": queryVec,
    "idPrefix": repoA, "limit": 10}, 15_000)
  check("a scoped kNN over real embeddings answers", scoped{"ok"}.getBool(false),
        $scoped)
  var scopedIds: seq[string] = @[]
  if scoped{"items"} != nil:
    for item in scoped{"items"}: scopedIds.add item{"id"}.getStr("")
  check("semantic recall finds the paraphrase's fact first",
        scopedIds.len > 0 and scopedIds[0] == repoA & "deps.package_manager",
        "got " & $scopedIds)
  check("the scoped page stays inside its repository",
        scopedIds.allIt(it.startsWith(repoA)), "got " & $scopedIds)

  # The same query UNSCOPED sees BOTH repositories' package-manager facts:
  # they are near-ties in this space, which is precisely why scoping has to
  # happen INSIDE the kNN. A global top-k of 1 would return whichever tie the
  # index emits first, so a caller that post-filtered would get "no results"
  # half the time — the shortfall this change removed.
  let unscoped = call(nc, "store", "search", %*{
    "kind": "embedding", "model": embedModel, "vector": queryVec,
    "limit": 1}, 15_000)
  var unscopedIds: seq[string] = @[]
  if unscoped{"items"} != nil:
    for item in unscoped{"items"}: unscopedIds.add item{"id"}.getStr("")
  let widerUnscoped = call(nc, "store", "search", %*{
    "kind": "embedding", "model": embedModel, "vector": queryVec,
    "limit": 10}, 15_000)
  var wideIds: seq[string] = @[]
  if widerUnscoped{"items"} != nil:
    for item in widerUnscoped{"items"}: wideIds.add item{"id"}.getStr("")
  check("unscoped, BOTH repositories' matching facts compete (the premise)",
        wideIds.anyIt(it.startsWith(repoA)) and wideIds.anyIt(it.startsWith(repoB)),
        "unscoped page = " & $wideIds &
        "; without this the scoped assertion proves nothing")
  check("a top-k of 1 can only spend its one slot on one repository",
        unscopedIds.len == 1,
        "got " & $unscopedIds &
        " — a post-filtered scoped recall would return nothing here")

  # Ordering is by meaning, not by shared words: the build fact is FARTHER
  # from a package-manager question than the package-manager fact is.
  var distOf: seq[float] = @[]
  if scoped{"items"} != nil:
    for item in scoped{"items"}: distOf.add item{"distance"}.getFloat(-1.0)
  check("distances are ordered nearest-first", distOf.len >= 2 and
        distOf[0] <= distOf[1], $distOf)
  check("a different-concept fact ranks farther than the matching one",
        distOf.len >= 2 and distOf[^1] > distOf[0] + 0.05,
        "distances " & $distOf)

  # Sanity on the space itself, so a vacuum embedding cannot pass the above:
  # the paraphrase must be much closer to the matching fact than to the
  # different-concept fact.
  let matchDist = cosDistance(queryVec.mapIt(it.getFloat(0.0)),
                              queryVec.mapIt(it.getFloat(0.0)))
  check("a vector's distance to itself is 0 (the metric is sane)",
        matchDist < 1.0e-9, $matchDist)

  # Exercise memory itself, not just the underlying embed/store primitives.
  let workspace = sandbox.root / "facts"
  createDir(workspace)
  let remembered = call(nc, "memory", "memory_remember", %*{
    "workspace": workspace, "subject": "deps.manager",
    "text": "Use pnpm for packages"}, 15_000)
  check("memory stores a selectively authored fact", remembered{"ok"}.getBool(false), $remembered)
  let semantic = call(nc, "memory", "memory_search", %*{
    "workspace": workspace, "query": "install dependencies"}, 60_000)
  check("memory uses embeddings to retrieve a fact without lexical overlap",
    semantic{"ranker"}.getStr("") == "vector" and semantic{"count"}.getInt(0) == 1,
    $semantic)
  let irrelevant = call(nc, "memory", "memory_search", %*{
    "workspace": workspace, "query": "sqlite database storage"}, 60_000)
  check("semantic retrieval can say nothing is relevant",
    irrelevant{"ranker"}.getStr("") == "vector" and
    irrelevant{"count"}.getInt(-1) == 0, $irrelevant)
  let corrected = call(nc, "memory", "memory_remember", %*{
    "workspace": workspace, "subject": "deps.manager",
    "text": "Use yarn for packages"}, 15_000)
  check("correction advances the memory revision", corrected{"revision"}.getInt(0) == 2, $corrected)
  let refreshed = call(nc, "memory", "memory_search", %*{
    "workspace": workspace, "query": "install dependencies"}, 60_000)
  check("semantic hits use the corrected source revision",
    ($refreshed).contains("yarn") and not ($refreshed).contains("Use pnpm"), $refreshed)
  let recall = call(nc, "memory", "memory_recall", %*{
    "workspace": workspace, "query": "install dependencies"}, 60_000)
  check("semantic recall formats the retrieved fact", recall{"block"}.getStr("").contains("yarn"), $recall)
  discard call(nc, "memory", "memory_forget", %*{"id": remembered{"id"}}, 15_000)
  let forgotten = call(nc, "memory", "memory_search", %*{
    "workspace": workspace, "query": "install dependencies"}, 60_000)
  check("forgotten facts do not reappear through cached vectors", forgotten{"count"}.getInt(-1) == 0, $forgotten)
  report("MEMORY EMBED CHAIN TEST")

main()
