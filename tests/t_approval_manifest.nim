## Unit tests for program-shaped approval manifests (docs/MANUAL.md, "Fabric and subagents").

import std/[json, os, strutils]
import ../core/approval
import helpers

proc main() =
  # source artifacts must land under a private NIF_ROOT, never the repo
  let root = getTempDir() / "niffler-approval-test"
  removeDir(root)
  putEnv("NIF_ROOT", root)

  let code = "import fabricguest\nfinish(\"ok\")\n"
  let program = %*{"code": code, "tools": ["bash", "grep"],
                   "maxCalls": 200}

  check("non-program args carry no manifest", approvalManifest(%*{
    "name": "lifec"}) == nil)

  let manifest = approvalManifest(program)
  check("program args produce a manifest", manifest != nil)
  check("manifest digest is stable",
        manifest{"digest"}.getStr("") == programDigest(program),
        $manifest)
  check("manifest points at the full source",
        manifest{"source"}.getStr("").endsWith(".nim") and
        fileExists(manifest{"source"}.getStr("")), $manifest)
  let artifact = readFile(manifest{"source"}.getStr(""))
  check("source artifact holds the whole program", artifact == code)
  check("source artifact is mode 0600",
        getFilePermissions(manifest{"source"}.getStr("")) ==
          {fpUserRead, fpUserWrite})
  check("manifest lists selected tools verbatim",
        manifest{"tools"} == program{"tools"}, $manifest)
  check("manifest carries the declared budget",
        manifest{"maxCalls"}.getInt(0) == 200, $manifest)

  let modified = %*{"code": code & "# changed\n", "tools": ["bash", "grep"],
                    "maxCalls": 200}
  check("changed source changes the digest",
        programDigest(program) != programDigest(modified))

  let reordered = %*{"code": code, "tools": ["grep", "bash"],
                     "maxCalls": 200}
  check("tool order does not change the digest",
        programDigest(program) == programDigest(reordered))

  let tighter = %*{"code": code, "tools": ["bash", "grep"], "maxCalls": 5}
  check("changed budget changes the digest",
        programDigest(program) != programDigest(tighter))

  check("plain tool auto key is the tool name",
        autoKey("bash", %*{"command": "ls"}) == "bash")
  check("program auto key is tool plus digest",
        autoKey("fabric", program) == "fabric:" & programDigest(program))
  check("different programs never share an auto key",
        autoKey("fabric", program) != autoKey("fabric", modified))

  report("approval manifest")

main()
