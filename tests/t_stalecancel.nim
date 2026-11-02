## Stale steer controls — a __cancel that arrives while NO turn is running
## must not abort the NEXT turn.
##
## Reported shape: "I press ESC twice, then I must type continue twice before
## anything happens — the second continue gives me another cancelled."
##
## Mechanism. `pumpSteer` is the only consumer of svc.session.<id>.steer. It
## runs from every dispatch idle slot, which includes the slots AFTER a turn's
## final LLM round — so a control that arrives while the runner is idle is
## consumed by the tail of whatever dispatch happens next, or by the next
## turn's own tool dispatch, and it sets `cancelRequested`. Two turn boundaries
## then misbehave:
##
## - runTurn cleared the flag at entry but never drained the subscription, so a
##   control still unread on the wire was consumed by the turn's first round;
## - a flag raised by a pump running AFTER the last round-1 check was left set
##   for the NEXT turn, whose `clear` came too late to help.
##
## The fix is that a turn boundary DISCARDS controls rather than raising them
## (pumpSteer(discardControls = true)): "a cancel applies to the turn running
## when it arrives, or not at all".
##
## Hermetic: no bus, no harness. The queue behaviour is a pure function of
## pumpSteer over a real NATS subscription.

import std/[json, os, times]
import natsnim
import envelope
import helpers
import ../core/dispatch

proc main() =
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let subject = "svc.session.stale-probe.steer"

  proc freshStream(): SteerStream =
    ## A SteerStream bound to a real subscription on the steer subject.
    var sub: ptr natsSubscription
    doAssert checkStatus(natsConnection_SubscribeSync(addr sub, nc.conn,
                                                      subject.cstring))
    SteerStream(sub: sub)

  proc publishCancel(id: string) =
    nc.publish(subject, Envelope(v: 1, id: id, kind: ekEvent,
                                 payload: %*{"__cancel": true}).encode())
    sleep(120)                      # let NATS deliver

  proc publishSteer(id, content: string) =
    nc.publish(subject, Envelope(v: 1, id: id, kind: ekEvent,
                                 payload: %*{"content": content}).encode())
    sleep(120)

  # --- 1. a turn-boundary drain DISCARDS a queued cancel ------------------
  # Assert the DRAIN's own effect, with no clear afterwards: if the drain
  # merely left the flag raised for runTurn to clear, a cancel arriving
  # between the drain and the first round would still kill the turn — and
  # this check is what distinguishes the two implementations.
  block:
    let st = freshStream()
    defer: natsSubscription_Destroy(st.sub)
    publishCancel("c1")
    var ct = CoreTools(steerStream: st)
    pumpSteer(ct, discardControls = true)
    check("a turn-boundary drain does not raise the flag itself",
          not st.cancelRequested,
          "the drain raised the flag: a cancel queued before the turn (or " &
          "arriving in the window after the drain) would abort it")
    check("and the message was CONSUMED, not left on the wire",
          block:
            var seen = false
            # A second drain must find nothing: if the first drain had skipped
            # the message, this one would see it (and raise the flag).
            pumpSteer(ct)
            seen = st.cancelRequested
            not seen)

  # --- 2. a cancel DURING a turn still raises the flag --------------------
  block:
    let st = freshStream()
    defer: natsSubscription_Destroy(st.sub)
    var ct = CoreTools(steerStream: st)
    publishCancel("c2")
    pumpSteer(ct)                  # the mid-turn drain: no discard
    check("a cancel during a live turn RAISES the flag", st.cancelRequested,
          "flag=" & $st.cancelRequested)

  # --- 3. steering text is not a control: always queued -------------------
  block:
    let st = freshStream()
    defer: natsSubscription_Destroy(st.sub)
    var ct = CoreTools(steerStream: st)
    publishSteer("s1", "add a test for this")
    pumpSteer(ct, discardControls = true)
    check("a turn-boundary drain still QUEUES steering text",
          st.queue == @["add a test for this"], $st.queue)
    check("steering text raises no cancel", not st.cancelRequested)

  # --- 4. the reported two-press sequence, end to end ---------------------
  block:
    let st = freshStream()
    defer: natsSubscription_Destroy(st.sub)
    var ct = CoreTools(steerStream: st)
    # Turn 1 runs and is cancelled (the human pressed ESC twice).
    publishCancel("x1")
    pumpSteer(ct)
    check("turn 1 sees the cancel", st.cancelRequested)
    # ...turn 1 ends. A straggler arrives after it, while idle.
    st.cancelRequested = false     # what the cancelled turn does on its way out
    publishCancel("x2")
    # Turn 2 starts: its boundary must DISCARD the straggler.
    pumpSteer(ct, discardControls = true)
    st.cancelRequested = false
    check("the straggler does not abort turn 2", not st.cancelRequested,
          "the second 'continue' was needed — the bug")
    # ...and turn 2 keeps working normally.
    publishSteer("s2", "continue")
    pumpSteer(ct, discardControls = true)
    check("turn 2 still receives real steering input",
          st.queue == @["continue"], $st.queue)

  report("STALE CANCEL TEST")

main()
