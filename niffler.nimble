# Package
version       = "0.2.0"
author        = "Göran Krampe"
description   = "Niffler - AI assistant in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["niffler"]

# Dependencies

requires "nim >= 2.2.4"
requires "illwill >= 0.3.0"
requires "cligen >= 1.7.0"

#requires "openaiclient >= 0.1.0"
#requires "jsony >= 1.1.0"
#requires "httpclient >= 0.1.0"
#requires "json"

task test, "Runs the test suite":
  exec "nim c -r tests/test_all.nim"

task build, "Build optimized release":
  exec "nim c -d:release -o:bin/niffler src/niffler.nim"
