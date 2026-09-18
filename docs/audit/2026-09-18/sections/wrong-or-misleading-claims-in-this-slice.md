# Worklist slice: Wrong or misleading claims (in this slice)

From `worklist.tsv` (2 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A207 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL 2320 — "orphaned `nats-server` … only possible when its core was SIGKILLed" is wrong on Linux: PDEATHSIG covers SIGKILL (`components/nats/main.go:15-18`, `sdk/go/pdeathsig_linux.go:17`). The realistic causes are a manually started server, a non-Linux host, or a stale pid file.

## A208 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL 2253-2257 — client counting (`reg.publish client: true`, `core/catalog.nim:794-798`) and the UI registry's leases (`core/uireg.nim:1-59`, 20 s) are two different mechanisms; the text reads as though they are one.

