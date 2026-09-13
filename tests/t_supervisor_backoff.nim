## Restart-backoff schedule for supervised children (core/supervisor.nim).
##
## Regression: startChild reset the child's restart counter on every launch,
## so pump's "restart #N" was always #1 — a child that died immediately was
## relaunched every ~500ms forever instead of backing off to 8s.

import ../core/supervisor
import helpers

proc main() =
  check("a first crash restarts after 1s", backoffMs(1) == 1000.0,
        $backoffMs(1))
  check("consecutive crashes double the delay",
        backoffMs(2) == 2000.0 and backoffMs(3) == 4000.0 and
        backoffMs(4) == 8000.0, $[backoffMs(2), backoffMs(3), backoffMs(4)])
  check("the delay saturates at 8s",
        backoffMs(5) == 8000.0 and backoffMs(9) == 8000.0 and
        backoffMs(200) == 8000.0, $[backoffMs(5), backoffMs(9), backoffMs(200)])
  check("no crash history costs no delay", backoffMs(0) == 0.0)
  report("SUPERVISOR BACKOFF")

main()
