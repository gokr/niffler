## Embed-model wiring — a provider record's configured `embedModel` must reach
## the models catalog, and an x-embed-source declaration must supply the
## dimensions and window the model id alone cannot.
##
## The defect this exists for: updateEmbedDocumentsLocked has always read
## provider["embedModel"], but the models catalog is built from the models.dev
## baseline FILE and never read provider RECORDS at all. So `embedModel` was
## dead configuration — accepted by provider_update, echoed by provider_list,
## absent from models_list {embed:true}, models_get and models_providers, and
## reported downstream as "model not found". The Go unit test did not catch it
## and could not: it is a legitimate test of the projection, and it supplies the
## field by writing it into state.base. This test drives the real tools, so it
## covers the wiring — a stored record, not a fixture, is the source.
##
## Three parts, all asserted here:
##   - a stored record's embedModel appears in the embedding view, in
##     models_providers and in models_get (and never in the chat list),
##     including for a provider the baseline has never heard of (a local
##     runtime);
##   - an x-embed-source declaration merges dimensions + context over it, which
##     is the only way a caller learns 384/512 for a model id;
##   - the keyless-loopback rule: a local runtime has no API key, and requiring
##     one forced a made-up string into a credential field.

import std/[json, os, strutils, times]
import natsnim
import helpers

proc main() =
  let sandbox = newCoreSandbox("embedchain", ["store", "models", "provider", "llm"])
  let keep = getEnv("NIF_KEEP_SANDBOX", "").len > 0
  echo "sandbox: ", sandbox.root
  defer:
    if not keep: removeDir(sandbox.root)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let core = startComponent(sandbox.sandboxBin("niffler"), url,
    root = sandbox.root, extra = [("NIF_AUTO_APPROVE", "1")])
  defer: stopProcess(core)
  var ready = false
  for _ in 0 ..< 100:
    let c = call(nc, "core", "catalog", %*{"op": "components"}, 2000)
    if c{"components"}{"models"} != nil and c{"components"}{"provider"} != nil and
        c{"components"}{"llm"} != nil:
      ready = true
      break
    sleep(200)
  check("core, models and provider are up", ready)
  if not ready: report("EMBED CHAIN TEST")

  # --- a configured embed model on a known provider ------------------------
  let put = call(nc, "provider", "provider_add", %*{
    "nickname": "synthetic", "apiKey": "test-key",
    "baseUrl": "https://api.synthetic.new/openai/v1",
    "model": "syn:small:text",
    "embedModel": "hf:nomic-ai/nomic-embed-text-v1.5"}, 30_000)
  check("provider_add accepts a separate embed model",
        put{"ok"}.getBool(false), (if put{"error"} != nil: put{"error"}.getStr("") else: ""))

  # --- a keyless LOCAL runtime (the gap provider_add used to refuse) -------
  let local = call(nc, "provider", "provider_add", %*{
    "nickname": "localtest", "baseUrl": "http://127.0.0.1:8080/v1",
    "embedModel": "nomic-embed-text"}, 30_000)
  check("a loopback provider registers WITHOUT an apiKey",
        local{"ok"}.getBool(false),
        (if local{"error"} != nil: local{"error"}.getStr("") else: ""))
  # A provider the models.dev baseline has never heard of, whose declaration
  # comes from the fixture plugin (dimensions/window have no other source).
  let fixtureProvider = call(nc, "provider", "provider_add", %*{
    "nickname": "fixture-embed", "baseUrl": "http://127.0.0.1:8080/v1",
    "embedModel": "fixture/embed-small"}, 30_000)
  check("a keyless LOCAL provider with a declared embed model registers",
        fixtureProvider{"ok"}.getBool(false), $fixtureProvider)
  # The same omission must still be refused for a remote endpoint.
  let remote = call(nc, "provider", "provider_add", %*{
    "nickname": "remotetest", "baseUrl": "https://api.example.com/v1",
    "embedModel": "text-embedding-3-small"}, 30_000)
  check("but a REMOTE provider without a key is still refused",
        remote{"error"} != nil, $remote)

  # --- a metadata provider declaring x-embed-source ------------------------
  # Spawned as a fixture: the shipped declaration lives in an external plugin
  # repo, but "a declaration's dimensions merge over a configured embed model,
  # in the embedding view only" is a property of the models catalog.
  let fixture = sandbox.fixtureBin("fixture-embed-source",
                                   sandbox.repoRoot / "tests" / "fixtures" / "embed_source.nim")
  let spawned = call(nc, "core", "spawn", %*{"name": "fixture-embed-source",
    "binary": fixture}, 60_000)
  check("the embedding-metadata fixture spawned", spawned{"ok"}.getBool(false), $spawned)
  sleep(1500)

  # --- assert the embedding view ------------------------------------------
  var rows: seq[JsonNode]
  let deadline = epochTime() + 40.0
  while epochTime() < deadline:
    discard call(nc, "models", "models_refresh", %*{"force": false}, 20_000)
    sleep(800)
    let listed = call(nc, "models", "models_list", %*{"embed": true}, 20_000)
    rows = @[]
    if listed{"models"} != nil and listed{"models"}.kind == JArray:
      for m in listed{"models"}: rows.add m
    if rows.len > 0: break

  proc row(provider, model: string): JsonNode =
    for m in rows:
      if m{"provider"}.getStr("") == provider and m{"id"}.getStr("") == model:
        return m
    nil

  let synth = row("synthetic", "hf:nomic-ai/nomic-embed-text-v1.5")
  check("a stored record's embedModel reaches the embedding view",
        synth != nil, "rows: " & $rows)
  check("a LOCAL provider the baseline has never heard of is listed too",
        row("localtest", "nomic-embed-text") != nil, "rows: " & $rows)
  check("every listed entry is marked embedding: true",
        rows.len > 0 and (block:
          var all = true
          for m in rows:
            if not m{"embedding"}.getBool(false): all = false
          all))

  let declared = row("fixture-embed", "fixture/embed-small")
  check("a provider unknown to the baseline is listed in the embedding view",
        declared != nil, "rows: " & $rows)
  check("x-embed-source supplies the dimensions a bare id cannot",
        declared != nil and declared{"dimensions"}.getInt(0) == 384, $declared)
  check("x-embed-source supplies the context window",
        declared != nil and declared{"limit"}{"context"}.getInt(0) == 512, $declared)

  # --- an embed model must never become a chat choice ----------------------
  let chat = call(nc, "models", "models_list", %*{"provider": "synthetic",
                                                   "embed": false}, 20_000)
  var leaked = false
  if chat{"models"} != nil and chat{"models"}.kind == JArray:
    for m in chat{"models"}:
      if m{"id"}.getStr("").contains("nomic"): leaked = true
  check("the embed model never enters the chat list", not leaked, $chat)

  # --- models_providers reports the configured model too -------------------
  # Same defect, third surface: this field is projected from the same
  # embedEffective document as the view above, so it was equally empty.
  let providers = call(nc, "models", "models_providers", %*{"query": "fixture"},
                       10_000)
  var reported = ""
  if providers{"providers"} != nil and providers{"providers"}.kind == JArray:
    for m in providers{"providers"}:
      if m{"id"}.getStr("") == "fixture-embed":
        reported = m{"embedModel"}.getStr("")
  check("models_providers reports the configured embedModel",
        reported == "fixture/embed-small", "reported: " & reported & " in " & $providers)

  # --- and it is fetchable by reference -----------------------------------
  let got = call(nc, "models", "models_get", %*{
    "provider": "synthetic", "model": "hf:nomic-ai/nomic-embed-text-v1.5"}, 10_000)
  check("models_get resolves the configured embed model",
        got{"model"} != nil and got{"embedding"}.getBool(false), $got)

  # --- provider_get must state whether the record is USABLE ----------------
  # The key field is omitted when empty, and an empty key is legitimate for a
  # loopback endpoint. llm inferred "usable" from the key alone and therefore
  # refused every keyless local provider as not found — which is precisely the
  # local llama-server configuration. hasKey is the provider component's own
  # verdict (hasCredential), so the decision stays in one place.
  let record = call(nc, "provider", "provider_get", %*{"nickname": "localtest"},
                    10_000)
  check("provider_get reports a keyless loopback record as usable (hasKey)",
        record{"hasKey"}.getBool(false), $record)
  # The field is ABSENT when empty (apiKey,omitempty) — that absence is the
  # observation, so never index it directly: a missing key here is a nil node,
  # and `.getStr` on nil is a segfault, not an empty string.
  let providerNode = record{"provider"}
  let keyNode = providerNode{"apiKey"}
  check("and confirms no key was invented for it",
        keyNode == nil or keyNode.kind == JNull or keyNode.getStr("") == "",
        "apiKey present: " & (if keyNode == nil: "<absent>" else: $keyNode))

  # A keyless loopback provider must be ROUTABLE, not just stored: llm must
  # find it (this is the not-found the credential check used to produce).
  # Nothing is listening on the port in the gate, so a CONNECTION error is the
  # pass condition — the failure to avoid is `unknown provider "localtest"`.
  let routed = call(nc, "llm", "embed", %*{
    "provider": "localtest", "input": ["search_document: probe"]}, 30_000)
  let routeError = routed{"error"}.getStr("")
  check("llm routes a keyless loopback provider instead of reporting it unknown",
        not routeError.contains("unknown provider"),
        routeError)

  report("EMBED CHAIN TEST")

main()
