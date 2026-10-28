## Local report paging: arbitrary prose is a result, no Git artifact required.
import std/[json, strutils]
import ../components/fleet/delegation
let text = repeat("修復済み — PR https://github.com/example/repo/pull/24\n", 300)
let job = %*{"id": "job", "sessionId": "remote", "state": "settled",
  "report": text, "reportComplete": true, "notice": {"summary": summary(text)}}
var offset = 0
var rebuilt = ""
while true:
  let page = reportPage(job, %*{"offset": offset, "limit": 127})
  doAssert page["report"].getStr.len <= 127
  rebuilt.add(page["report"].getStr)
  if not page["hasMore"].getBool: break
  doAssert page["nextOffset"].getInt > offset
  offset = page["nextOffset"].getInt
  doAssert offset < text.len
doAssert rebuilt == text
doAssert publicJob(job){"report"} == nil
var refused = false
try: discard reportPage(job, %*{"offset": 1})
except ValueError: refused = true
doAssert refused
let legacy = %*{"id": "old", "sessionId": "old", "state": "settled", "notice": {"summary": "old report"}}
let page = reportPage(legacy, newJObject())
doAssert page["report"].getStr == "old report"
doAssert not page["reportComplete"].getBool
doAssert page{"detail"} != nil
echo "FLEET REPORT TEST PASSED"
