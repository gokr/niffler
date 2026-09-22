# Jev discovery spike (Von first)

This optional `jev` component provides advisory decisions over a small list of
candidates. It does **not** alter `discover`, `skill_list`, `invoke`, the
conversation prefix, or the approval gate. The only prompt-cache effect is
append-only tool history when `jev_suggest` is explicitly called. An unavailable
backend is an error result; continue with ordinary discovery.

## Local runtime

Run [Von](https://github.com/wfzyx/von) separately on loopback:

```sh
# In a separate Python environment (model weights are downloaded by Von).
pip install 'von-sdk>=1.1.0'
von serve --model von-1.1 --host 127.0.0.1 --port 8000
```

`make build` builds only the Niffler adapter, not the Python model/runtime.
The manifest starts `jev` without loading weights; if Von is absent, only
Jev calls fail. Configure `NIF_JEV_URL` to another **loopback HTTP** server
implementing `POST /v1/systemone`; it must not redirect. Set
`NIF_JEV_BACKEND` to the backend label and `NIF_JEV_MODEL` to its model id.
Remote endpoints are intentionally excluded from this local-only spike.
Kev (`jaredpalmer/kev`) and Laya's `laya.cpp` are candidates for a later
backend, if their wire response matches the normalized contract.

Example, after `discover` has given a candidate shortlist:

```json
{"task":"Find references to the component registration in this checkout",
 "candidates":[{"name":"grep","description":"Search file contents"},
               {"name":"skill_list","description":"List workflow skills"}]}
```

Call `jev_suggest` through `discover` + `invoke`; it sends a paired `noul`
(does any capability help?) and `choice` (which one?) in one System One
request. It returns the raw answers and a suggestion (empty on no-match).
**Treat probability as an uncalibrated experimental signal**, not policy.
Never pass secrets or large file contents in `task`. The model is not an
access-control mechanism; only Niffler's dispatch/approval path executes tools.

## Evaluation before automation

`make test-jev` uses a mock backend and a private NATS bus; it proves the
contract, *not* Von accuracy or CPU latency. Build a held-out list of tasks
with expected tool/skill or no-match labels, compare top-1/top-k and false
recommendations to plain `discover`/`skill_list`, and measure p50/p95 latency
and RSS on a typical CPU laptop with real Von. Try both short and confusing
candidate descriptions, changed catalogue entries, missing backend, and
no-match. Only consider automatic shortlist surfacing after those measurements.

Expert advice is deliberately not wired to this experiment: Jev may later
triage *whether* expert review is useful but cannot draft expert guidance.

## Related harness integrations

After updating the local `../harnesses` checkouts, Hermes had plugin-catalog
entries for `jev-typesafe`, `jev-curator`, `jev-approvals`, and agent/MCP/model
routers. OpenCode has a hosted System One gateway route; no matching in-tree
Pi implementation was found in a targeted source search (external Pi plugins
are separate). These are inspiration, not dependencies of this spike.
