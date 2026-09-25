## Example 5 — advisory ranking with verified fallback.
##
## Ask the jev component which discoverable tool fits a fuzzy task, then
## VERIFY the suggestion with ordinary discovery before trusting it — all
## inside one program. This is where jev belongs: the candidate shortlist,
## the raw model answers and the ranking noise stay in the guest process;
## only the verified outcome reaches the conversation.
##
## jev is an ADVISOR, not a permission: no backend, no jev component, an
## empty suggestion or a low-confidence answer must all fall back to
## ordinary lexical discovery inside the SAME program — availability of a
## decision model never decides whether discovery happens at all. Tool-level
## advisories ({"ok": false, ...}) arrive as normal values; only bridge-level
## failures raise FabricCallError.
##
## Run by the model as one fabric tool call:
##   code = <the program below>,
##   strings = {"task": "start a process and watch its output",
##              "query": "spawn"}

import fabricguest
import std/json

let task = stringArg("task")
let query = stringArg("query")

var suggestion = ""
var advisor = ""

# 1. ask the advisor. A missing component or a failed bridge call is just
#    another "no advice" outcome, not an error for the program.
try:
  let advice = call("jev_recommend",
                    %*{"task": task, "query": query, "kind": "tools"})
  if advice{"ok"}.getBool(false):
    suggestion = advice{"suggestion"}.getStr("")
    advisor = if suggestion.len > 0: "ranked" else: "no-match"
  else:
    advisor = "unavailable: " & advice{"error"}.getStr("advisory failure")
except FabricCallError as e:
  advisor = "not-reachable: " & e.msg

# 2. no advice → ordinary discovery still runs, here and in the same pass
if suggestion.len == 0:
  let found = call("discover", %*{"query": query})
  let comps = found{"components"}
  let count = if comps != nil and comps.kind == JArray: comps.len else: 0
  finish(%*{"ranked": false, "suggestion": "", "advisor": advisor,
            "discovered": count > 0, "candidateComponents": count})

# 3. advice → verify the name against live discovery before trusting it
let verified = call("discover", %*{"component": suggestion})
finish(%*{"ranked": true, "suggestion": suggestion, "advisor": advisor,
          "verified": verified{"error"} == nil})
