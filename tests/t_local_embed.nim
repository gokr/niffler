## Optional local runtime launcher: absent is explicit; no model downloads.
import std/[json, os]
import natsnim
import helpers

proc main() =
  let repo = getEnv("NIF_REPO_ROOT", getCurrentDir())
  let root = tempRoot("local-embed")
  defer: removeDir(root)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let child = startComponent(repo / "var/bin/local-embed", url, root = root,
    extra = [("NIF_EMBED_DIR", root / "absent")])
  defer: stopProcess(child)
  var status: JsonNode
  for i in 0 ..< 50:
    status = call(nc, "local-embed", "local_embed_status", %*{}, 1000)
    if status{"state"}.getStr("") == "absent": break
    sleep(100)
  check("missing model runtime is reported without starting a child",
    status{"state"}.getStr("") == "absent" and status{"childPid"}.getInt(-1) == 0,
    $status)
  report("LOCAL EMBED TEST")

main()
