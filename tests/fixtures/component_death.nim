## component_death — issue #116 regression fixture.
##
## One tool whose handler blocks forever, so a test can kill this process with
## the call still in flight and observe what the caller is told. The component
## is disposable by design: it exists to die.
##
## The blocking sleep is a poll loop rather than `sleep(forever)` so the
## process still responds to SIGTERM (a graceful kill must be distinguishable
## from the SIGKILL the fast-fail path is about).

import std/[json, os, times]
import niffler/sdk

let comp = newComponent("compdeath", "0.1.0")

comp.tool:
  proc hang(): JsonNode =
    ## Blocks until this process is killed. Empty args by design.
    while true:
      sleep(50)
    %*{"unreachable": true}   # never returned: the component is killed first

comp.tool:
  proc quick(): JsonNode =
    ## Answers immediately — the control for "a live component is unaffected".
    %*{"ok": true, "alive": true}

comp.run()
