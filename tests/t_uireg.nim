## UI registry tests — pure logic, no bus. Numbering, leases, expiry and
## conversation claims (core/uireg.nim; served by the system core as the
## hidden "ui" tool).

import std/[json, os]
import ../core/uireg
import helpers

proc reg(r: UiRegistry, ui: string): JsonNode =
  r.handleUi(%*{"op": "register", "ui": ui})

proc renew(r: UiRegistry, ui: string): JsonNode =
  r.handleUi(%*{"op": "renew", "ui": ui})

proc claim(r: UiRegistry, ui, session: string): JsonNode =
  r.handleUi(%*{"op": "claim", "ui": ui, "session": session})

proc owner(r: UiRegistry, session: string): JsonNode =
  r.handleUi(%*{"op": "owner", "session": session})

proc main =
  let r = newUiRegistry(leaseSecs = 0.3)

  # --- numbering: monotonic, reconnect keeps the number --------------------
  let a = reg(r, "tui-aaa")
  let b = reg(r, "tui-bbb")
  check("first UI gets number 1", a{"number"}.getInt(0) == 1, $a)
  check("second UI gets number 2", b{"number"}.getInt(0) == 2, $b)
  let a2 = reg(r, "tui-aaa")
  check("re-register inside the lease keeps the number",
        a2{"number"}.getInt(0) == 1, $a2)
  check("re-register needs no new count", r.nextNumber == 2)

  # --- claims ---------------------------------------------------------------
  let c1 = claim(r, "tui-aaa", "conv-1")
  check("first claim succeeds", c1{"ok"}.getBool(false), $c1)
  let c2 = claim(r, "tui-bbb", "conv-1")
  check("second UI is refused and told who owns it",
        c2{"ok"}.getBool(false) == false and
        c2{"owner"}.getStr("") == "tui-aaa" and
        c2{"number"}.getInt(0) == 1, $c2)
  let o = owner(r, "conv-1")
  check("owner query reports the live owner",
        o{"owned"}.getBool(true) and o{"number"}.getInt(0) == 1, $o)
  let c3 = claim(r, "tui-aaa", "conv-1")
  check("re-claim by the owner is idempotent", c3{"ok"}.getBool(false), $c3)

  # release_session drops only the caller's own claim
  let rel = r.handleUi(%*{"op": "release_session", "ui": "tui-bbb",
                          "session": "conv-1"})
  check("releasing someone else's claim is a no-op",
        rel{"ok"}.getBool(false) and
        owner(r, "conv-1"){"owned"}.getBool(false) == true, $rel)
  discard r.handleUi(%*{"op": "release_session", "ui": "tui-aaa",
                        "session": "conv-1"})
  check("owner releases", owner(r, "conv-1"){"owned"}.getBool(false) == false)

  # --- expiry: leases lapse, claims lapse with them -------------------------
  discard claim(r, "tui-aaa", "conv-2")
  sleep(400)  # > the 0.3s lease
  let o2 = owner(r, "conv-2")
  check("expired lease no longer owns", o2{"owned"}.getBool(false) == false, $o2)
  let rn = renew(r, "tui-aaa")
  check("renew after expiry fails", rn{"ok"}.getBool(false) == false, $rn)
  # A UI whose lease lapsed must re-register before it can claim again —
  # claim requires a live lease, and a frozen/crashed UI (both UIs lapsed
  # here) is exactly the case the lease exists to catch.
  let b2 = reg(r, "tui-bbb")
  check("re-register after expiry gets a fresh number (bbb)",
        b2{"number"}.getInt(0) == 3, $b2)
  let c4 = claim(r, "tui-bbb", "conv-2")
  check("expired owner's claim is claimable after re-register",
        c4{"ok"}.getBool(false), $c4)
  let a3 = reg(r, "tui-aaa")
  check("re-register after expiry gets a fresh number (aaa)",
        a3{"number"}.getInt(0) == 4, $a3)

  # --- graceful release drops the UI and its claims --------------------------
  discard claim(r, "tui-aaa", "conv-3")
  discard r.handleUi(%*{"op": "release", "ui": "tui-aaa"})
  check("released UI loses its claim",
        owner(r, "conv-3"){"owned"}.getBool(false) == false)

  # --- bad input ------------------------------------------------------------
  check("unknown op errors",
        r.handleUi(%*{"op": "nope"}){"error"} != nil)
  check("register without ui errors",
        r.handleUi(%*{"op": "register"}){"error"} != nil)
  check("claim without a live lease errors",
        r.handleUi(%*{"op": "claim", "ui": "tui-ghost",
                      "session": "conv-9"}){"error"} != nil)

  report("t_uireg")

when isMainModule:
  main()
