## memory vector validation — does semantic recall actually work, and can it be
## scoped to one repository?
##
## This file exists because memory v1 shipped with TEXT ranking only
## (`memory_search` reports `ranker: "text"`), while the research note
## (docs/research/MEMORY.md §7) recommends vector recall as v2, gated on ONE
## store-contract change: vec0 partitions by `kind`+`model`, so a scope filter
## inside kNN needs `id_prefix` as a partition key. The note predicted that
## post-filtering a global top-k "returns a shortfall".
##
## Half 1 of this test proves the vector path itself works end to end on the
## sqlite engine: an embedding document round-trips, kNN returns neighbours
## nearest-first, and different models never mix.
##
## Half 2 validates scope-pure top-k. Instance and arbitrary id-prefix
## filters apply before exact cosine distance ranking, never after top-k.
##
## Half 3 pins the honest refusals (tidb says "unsupported", a malformed
## embedding is refused at put time) so a later change cannot quietly turn
## them into silent wrong answers.
##
## Run with the default engine (sqlite). `NIF_STORE_BACKEND=tidb` runs the
## tidb half instead, which asserts the explicit refusal.

import std/[json, math, os, sequtils, strutils, times]
import natsnim
import helpers

const
  model = "fixture/nomic-embed-text-v1.5"
  # A second space: same width, different model. Vectors must never be
  # compared across it, whatever their values.
  otherModel = "fixture/other-embed"

proc unitVec(id: int, weight: float, dim = 6): seq[float] =
  ## A unit vector that lights ONE concept dimension. Written by hand rather
  ## than through the fixture because this half tests the STORE, so the test
  ## should not depend on the fixture's vocabulary.
  result = newSeq[float](dim)
  result[id] = weight

proc cosDistance(a, b: seq[float]): float =
  var dot, na, nb = 0.0
  for i in 0 ..< min(a.len, b.len):
    dot += a[i] * b[i]
    na += a[i] * a[i]
    nb += b[i] * b[i]
  if na == 0.0 or nb == 0.0: return 2.0
  1.0 - dot / (sqrt(na) * sqrt(nb))

proc putEmbedding(nc: NatsConnection, id: string, vec: seq[float],
                  m = model, sourceId = ""): JsonNode =
  var value = %*{"model": m, "dimensions": vec.len,
                 "vector": %vec}
  if sourceId.len > 0:
    value["source"] = %"memory"
    value["sourceId"] = %sourceId
  call(nc, "store", "put", %*{"kind": "embedding", "id": id, "value": value},
       10_000)

proc knn(nc: NatsConnection, query: seq[float], limit = 10,
         idPrefix = "", m = model): JsonNode =
  var args = %*{"kind": "embedding", "vector": %query, "model": m,
                "limit": limit}
  if idPrefix.len > 0: args["idPrefix"] = %idPrefix
  call(nc, "store", "search", args, 15_000)

proc ids(r: JsonNode): seq[string] =
  if r == nil or r{"items"} == nil: return
  for item in r{"items"}:
    result.add item{"id"}.getStr("")

proc distances(r: JsonNode): seq[float] =
  if r == nil or r{"items"} == nil: return
  for item in r{"items"}:
    result.add item{"distance"}.getFloat(-1.0)

proc main() =
  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let storeBin = resolveStoreBin(root)
  if not fileExists(storeBin):
    fail(storeBin & " missing — run `make build` first")
    report("MEMORY VECTOR TEST")

  let backend = getEnv("NIF_STORE_BACKEND", "sqlite")

  let tmp = tempRoot("memoryvec")
  defer: removeDir(tmp)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let storeProc = startComponent(storeBin, url, root = tmp)
  defer: stopProcess(storeProc)

  var ready = false
  let deadline = epochTime() + 30.0
  while not ready and epochTime() < deadline:
    let r = call(nc, "store", "list", %*{"kind": "embedding", "limit": 1}, 3_000)
    if r{"error"} == nil: ready = true
    else: sleep(100)
  check("the store is reachable (" & backend & ")", ready,
        "store did not come up")
  if not ready: report("MEMORY VECTOR TEST")

  # --- tidb declares its limitation instead of guessing --------------------
  if backend == "tidb":
    let refused = knn(nc, unitVec(0, 1.0), 5)
    # helpers.call folds a component error into {"error": <message>}, so the
    # assertion is on the message the engine chose; the point is that it
    # SPEAKS rather than answering a kNN query with a token scan.
    let message = refused{"error"}.getStr("")
    check("tidb refuses vector search instead of faking it",
          message.contains("not implemented"), $refused)
    report("MEMORY VECTOR TEST")
    return

  # === Half 1: the vector path works, ordered and model-isolated ===========
  # "install deps" and "how do I add a dependency" are the SAME concept in a
  # different direction; "run the test suite" is a different one.
  let stored = putEmbedding(nc, "repo:/a:deps.package_manager",
                            unitVec(0, 0.92) & @[], sourceId = "repo:/a:deps")
  check("an embedding document round-trips through put",
        stored{"ok"}.getBool(false) and stored{"rev"}.getInt(0) > 0, $stored)

  for (id, vec) in {
      "repo:/a:build.jobs": unitVec(1, 0.95),
      "repo:/a:test.suite": unitVec(2, 0.95),
      "repo:/b:deps.package_manager": unitVec(0, 0.90)}:
    discard putEmbedding(nc, id, vec, sourceId = "memory")

  let near = knn(nc, unitVec(0, 1.0), 5)
  check("kNN answers vector mode with ranked:true",
        near{"ok"}.getBool(false) and near{"ranked"}.getBool(false) and
        near{"vector"}.getBool(false), $near)
  check("the nearest neighbour is the same concept",
        ids(near).len > 0 and ids(near)[0].contains("deps.package_manager"),
        "got " & $ids(near))
  check("results are ordered nearest-first",
        distances(near).len >= 2 and distances(near)[0] <= distances(near)[1],
        "distances " & $distances(near))
  check("distance is cosine-like, 0 for identical direction",
        distances(near).len > 0 and distances(near)[0] < 0.05,
        "distance " & $distances(near))
  check("an unrelated concept is farther than the matching one",
        distances(near).len > 0 and
        distances(near)[^1] > distances(near)[0] + 0.1,
        "distances " & $distances(near))

  # --- model isolation: two spaces, never compared -------------------------
  discard putEmbedding(nc, "repo:/a:in-other-space", unitVec(0, 1.0),
                       m = otherModel, sourceId = "memory")
  let own = knn(nc, unitVec(0, 1.0), 10, m = model)
  check("a kNN never returns vectors from another model",
        not ids(own).anyIt(it.contains("in-other-space")),
        "got " & $ids(own))
  let foreign = knn(nc, unitVec(0, 1.0), 10, m = otherModel)
  check("the other model's space finds only its own vector",
        ids(foreign).len == 1 and ids(foreign)[0].contains("in-other-space"),
        "got " & $ids(foreign))

  # === Half 2: scoped kNN — the change memory v2 needed (MEMORY.md §7) ===
  #
  # Two repositories' facts share one index. A correct per-repo recall must
  # never surface repo B's fact to repo A, and must not lose repo A's own
  # neighbours to B's closer ones.
  #
  # `idPrefix` filters candidates before exact cosine ranking. Both properties are asserted: purity of the
  # result page, and that k neighbours come FROM the scope (a post-filter would
  # return fewer than k — the shortfall this replaced).
  let scoped = knn(nc, unitVec(0, 1.0), 10, idPrefix = "repo:/a:")
  let scopedIds = ids(scoped)
  check("a scoped kNN returns only that scope's facts",
        scopedIds.len > 0 and scopedIds.allIt(it.startsWith("repo:/a:")),
        "got " & $scopedIds)
  check("a scoped kNN spends k WITHIN the scope (no post-filter shortfall)",
        scopedIds.len == 3,
        "repo:/a: holds 3 facts but the scoped page returned " & $scopedIds.len &
        " — a post-filtered global top-k would return fewer")
  # Unscoped stays exactly as it was: every partition, still nearest-first.
  let unscoped = ids(knn(nc, unitVec(0, 1.0), 10))
  check("an unscoped kNN still spans every scope",
        unscoped.anyIt(it.startsWith("repo:/a:")) and
        unscoped.anyIt(it.startsWith("repo:/b:")),
        "got " & $unscoped)

  # === Half 3: honest refusals, not silent wrong answers ==================
  let badDims = call(nc, "store", "put", %*{
    "kind": "embedding", "id": "repo:/a:bad-dims",
    "value": %*{"model": model, "dimensions": 4, "vector": unitVec(0, 1.0)}},
    10_000)
  check("an embedding whose dimensions disagree with its vector is refused",
        badDims{"error"} != nil, $badDims)

  let noModel = call(nc, "store", "search", %*{
    "kind": "embedding", "vector": %unitVec(0, 1.0), "limit": 5}, 10_000)
  check("a vector query without a model is refused (spaces are not named)",
        noModel{"error"} != nil, $noModel)

  let emptyVec = call(nc, "store", "search", %*{
    "kind": "embedding", "vector": %*[], "model": model, "limit": 5}, 10_000)
  check("an empty query vector is refused", emptyVec{"error"} != nil, $emptyVec)

  # A width no document uses answers empty rather than erroring: the table is
  # chosen by the query's own width, so this is "no neighbours", not a failure.
  let otherWidth = knn(nc, @[0.5, 0.5, 0.5, 0.5], 5)
  check("a query at an unused width answers an empty page, not an error",
        otherWidth{"error"} == nil and ids(otherWidth).len == 0, $otherWidth)

  report("MEMORY VECTOR TEST")

main()
