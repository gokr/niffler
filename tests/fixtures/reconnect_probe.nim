## reconnect_probe — SDK reconnect regression fixture (issue #3).
##
## A minimal component: one tool, one event binding, one tap. The test kills
## the bus under it, restarts the bus on a DIFFERENT port (discovery file
## updated), and asserts this process re-attaches, resubscribes, re-announces
## and answers calls again — without a process restart.

import std/json
import niffler/sdk

let comp = newComponent("reconnect-probe", "0.1.0")

comp.tool:
  proc ping(): JsonNode =
    ## Probe tool: answers pong. Empty args by design.
    %*{"ok": true, "pong": true}

discard comp.on("ev.recon.*", proc(c: Component, subject: string,
                                   payload: JsonNode) =
  discard)  # passive binding; exists only so re-attach rebuilds >0 event subs

discard comp.tap("ev.recon.tap", proc(c: Component, subject: string,
                                      data: string) =
  discard)

comp.run()
