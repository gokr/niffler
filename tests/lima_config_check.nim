## Optional non-VM Lima CLI compatibility probe. Requires limactl >=2.2.1.
## nim c --path:sdk -o:var/lima-config-check tests/lima_config_check.nim
## var/lima-config-check
import std/[json, os]
import yaml/tojson
import ../components/fleet/provision

let dir = getCurrentDir() / "var" / "lima-config-evidence"
createDir(dir)
let templatePath = dir / "fleet.yaml"
writeFile(templatePath, $limaConfig(2, "4G", "20G"))
let filled = nativeRunner(@["limactl", "validate", "--fill", templatePath], "", 30000)
doAssert filled.code == 0, "limactl validate failed: " & filled.logPath
writeFile(dir / "filled.yaml", filled.output)
let config = loadToJson(filled.output)[0]
validateLimaConfig(config)
# Detect configuration inherited during Lima's real default-fill operation.
let home = dir / "lima-home"
createDir(home / "_config")
writeFile(home / "_config/default.yaml", "mounts:\n- location: '~'\n")
let inherited = nativeRunner(@["env", "LIMA_HOME=" & home, "limactl", "validate", "--fill", templatePath], "", 30000)
doAssert inherited.code == 0, "inherited fill failed: " & inherited.logPath
var refused = false
try: validateLimaConfig(loadToJson(inherited.output)[0])
except Refusal: refused = true
doAssert refused, "inherited host mount was accepted"
echo "LIMA CONFIG CHECK PASSED (no VM created/started)"
