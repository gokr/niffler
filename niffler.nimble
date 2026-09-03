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
requires "htmlparser"
requires "checksums"
requires "https://github.com/gokr/natswrapper"
requires "https://github.com/gokr/bitbarrel"

# Tasks

task all_internal, "Unlocked internal build — invoke through all (or the Makefile)":
  exec "nim c --hints:off -o:var/bin/niffler core/niffler.nim"
  exec "nim c --hints:off -o:var/bin/session core/session.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/store components/store/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/bash components/bash/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/builder components/builder/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/plugins components/plugins/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/skills components/skills/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/systemprompt components/systemprompt/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/fetch components/fetch/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/edit components/edit/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/grep components/grep/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/git components/git/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/observe components/observe/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/logfile components/logfile/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/hooks components/hooks/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/console components/console/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/cli components/cli/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/agent components/agent/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/expert components/expert/main.nim"
  exec "nim c --hints:off --path:sdk -o:var/bin/fabric components/fabric/fabric.nim"
  exec "nim c --hints:off --path:sdk --path:\"$$(nim --verbosity:0 --hints:off --eval:'import std/os; echo getCurrentCompilerExe().parentDir.parentDir / \"compiler\"' 2>/dev/null | tail -1)\" -o:var/bin/fabric-exec components/fabric/executor.nim"
  exec "cd components/llm-openai && go build -o ../../var/bin/llm-openai ."
  exec "cd components/models && go build -o ../../var/bin/models ."
  exec "cd components/provider && go build -o ../../var/bin/provider ."
  exec "cd components/llm && go build -o ../../var/bin/llm ."

task all, "Build core and all shipped components (whole generation under the shared build lock)":
  exec "bash scripts/with-build-lock.sh nimble all_internal"

task run, "Build and run the harness":
  exec "nimble all"
  exec "./var/bin/niffler"

task smoke, "SDK smoke test (needs a NATS server; core spawns one if NATS_URL unset)":
  exec "bash scripts/with-build-lock.sh nim c --hints:off --path:sdk -r tests/smoke.nim"
