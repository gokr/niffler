# Package

version       = "0.1.0"
author        = "Göran Krampe"
description   = "Niffler — minimal self-extending agent harness (NATS + processes)"
license       = "MIT"
bin           = @[]

# Dependencies — deliberately tiny: the envelope is std/json runtime data,
# yaml for the bootstrap manifest, natswrapper for the bus, bitbarrel for
# the store component's embedded KV (which brings its own transitive deps).

requires "nim >= 2.2.10"
requires "yaml"
requires "https://github.com/gokr/natswrapper"
requires "https://github.com/gokr/bitbarrel"

# Tasks

task all, "Build core and all shipped components":
  exec "nim c --hints:off -o:var/bin/niffler core/core.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/store components/store/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/bash components/bash/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/builder components/builder/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/plugins components/plugins/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/console components/console/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/cli components/cli/main.nim"
  exec "cd components/llm-openai && go build -o ../../var/bin/llm-openai ."
  exec "cd components/llm && go build -o ../../var/bin/llm ."

task run, "Build and run the harness":
  exec "nimble all"
  exec "./var/bin/niffler"

task smoke, "SDK smoke test (needs a NATS server; core spawns one if NATS_URL unset)":
  exec "nim c --hints:off --path:sdk -r tests/smoke.nim"
