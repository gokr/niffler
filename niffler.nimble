# Package
version       = "0.2.2"
author        = "Göran Krampe"
description   = "Niffler - AI assistant in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["niffler"]

# Dependencies

requires "nim >= 2.2.4"
requires "illwill >= 0.3.0"
requires "cligen"
requires "sunny"
requires "curly"
requires "htmlparser"
requires "https://github.com/Vindaar/JsonSchemaValidator.git >= 0.1.0"

task test, "Run all tests":
  exec "nimble install -d"
  exec "testament --colors:on pattern 'tests/test_*.nim'"

task build, "Build optimized release":
  exec "nim c -d:release -o:bin/niffler src/niffler.nim"
