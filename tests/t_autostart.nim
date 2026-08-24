## Autostart harness lifecycle: an interactive client (ensureHarness +
## reg.publish "client": true) keeps an ensure-spawned core alive, the last
## departure stops it (and its spawned bus), while a manually started core
## ignores client churn entirely.

import std/[json, os, osproc, strutils, times]
import natswrapper
import helpers
import niffler/sdk

proc waitCoreGone(url: string, secs: float): bool =
  ## Core exits → its spawned bus exits with it → the probe stops answering.
  let deadline = epochTime() + secs
  while epochTime() < deadline:
    if not coreAnswers(url, 400):
      return true
    sleep(200)
  false

proc waitBusGone(url: string, secs: float): bool =
  ## The bus outlives its core's last probe answer by the teardown window
  ## (core closes its connection, then stops the bus) — poll for real death.
  let deadline = epochTime() + secs
  while epochTime() < deadline:
    try:
      var bus = natswrapper.connect(url)
      bus.close()
    except CatchableError:
      return true
    sleep(200)
  false

proc waitCoreUp(sandboxRoot: string, secs: float): string =
  ## Discovery-file + probe loop for a directly spawned core.
  let deadline = epochTime() + secs
  while epochTime() < deadline:
    let disc = sandboxRoot / "var" / "nats-url"
    if fileExists(disc):
      let u = readFile(disc).strip()
      if u.len > 0 and coreAnswers(u):
        return u
    sleep(200)
  ""

const fakeUi = """{"name":"fake-ui","version":"0.0.0","client":true,"tools":[]}"""
const fakeUiGone = """{"name":"fake-ui"}"""

proc main() =
  # Core spawned by ensureHarness must claim its own private bus: the dev
  # harness may be live on 4222, and neither the probe nor the spawned core
  # may touch it.
  putEnv("NIF_ENSURE_ATTACH", "0")
  putEnv("NIF_NATS_SPAWN", "1")
  putEnv("NIF_AUTOSTART_BOOT_S", "3")
  putEnv("NIF_AUTOSTART_IDLE_S", "2")
  defer:
    delEnv("NIF_ENSURE_ATTACH")
    delEnv("NIF_NATS_SPAWN")
    delEnv("NIF_AUTOSTART_BOOT_S")
    delEnv("NIF_AUTOSTART_IDLE_S")
  delEnv("NIF_NATS_URL")

  # --- A: no interactive client ever registers → boot grace exit ----------
  block phaseA:
    let sandbox = newCoreSandbox("autosta", ["bash"])
    defer: removeDir(sandbox.root)
    let url = ensureHarness(sandbox.root)
    check("ensureHarness spawns core when nothing answers",
          url.len > 0 and coreAnswers(url), url)
    check("ensure wrote the sandbox discovery file",
          fileExists(sandbox.root / "var" / "nats-url"))
    check("no interactive client → core exits at boot grace",
          waitCoreGone(url, 8))
    delEnv("NIF_NATS_URL")

  # --- B: last interactive client departs → core + bus stop ---------------
  block phaseB:
    let sandbox = newCoreSandbox("autostb", ["bash"])
    defer: removeDir(sandbox.root)
    let url = ensureHarness(sandbox.root)
    check("core up for client test", coreAnswers(url), url)
    var nc = waitConnect(url)
    nc.publish("reg.publish", fakeUi)
    sleep(400)
    check("core alive while an interactive client is registered",
          coreAnswers(url))
    nc.publish("reg.depart", fakeUiGone)
    check("last interactive departure stops the autostarted core",
          waitCoreGone(url, 8))
    check("spawned bus stops with its core", waitBusGone(url, 5))
    nc.close()

  # --- C: a manually started core ignores client churn --------------------
  block phaseC:
    let sandbox = newCoreSandbox("autostc", ["bash"])
    defer: removeDir(sandbox.root)
    let coreProc = startComponent(sandbox.sandboxBin("niffler"), "",
                                  sandbox.root, [("NIF_NATS_SPAWN", "1")])
    defer:
      if coreProc.running():
        coreProc.terminate()
      coreProc.close()
    let url = waitCoreUp(sandbox.root, 15)
    check("manual core boots and answers", url.len > 0, url)
    if url.len > 0:
      var nc = waitConnect(url)
      nc.publish("reg.publish", fakeUi)
      sleep(400)
      nc.publish("reg.depart", fakeUiGone)
      sleep(3000)  # past the idle window an autostarted core would honor
      check("manual core stays up after interactive departure",
            coreAnswers(url))
      nc.close()

  report("AUTOSTART TEST")

main()
