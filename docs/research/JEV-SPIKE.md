# Jev discovery spike (Von first)

This optional `jev` component provides advisory decisions over a small list of
candidates. It does **not** alter `discover`, `skill_list`, `invoke`, the
conversation prefix, or the approval gate. The only prompt-cache effect is
append-only tool history when `jev_suggest` or `jev_recommend` is explicitly
called. An unavailable backend is an error result for direct calls; continue
with ordinary discovery. Shadow judgments behave differently: an absent
backend leaves no store records (see "Shadow experiment").

## Local runtime

Run [Von](https://github.com/wfzyx/von) separately on loopback:

```sh
# In a separate Python environment (model weights are downloaded by Von).
pip install 'von-sdk>=1.1.0'
von serve --model von-1.1 --device cpu --host 127.0.0.1 --port 8000
```

`make build` builds only the Niffler adapter, not the Python model/runtime.
The manifest starts `jev` without loading weights; if Von is absent, direct
Jev calls fail and the shadow judge stays silent — one warning per absence
episode, no store records. Configure `NIF_JEV_URL` to another **loopback HTTP** server
implementing `POST /v1/systemone`; it must not redirect. Set
`NIF_JEV_BACKEND` to the backend label and `NIF_JEV_MODEL` to its model id.
Remote endpoints are intentionally excluded from this local-only spike.
Kev (`jaredpalmer/kev`) and Laya's `laya.cpp` are candidates for a later
backend, if their wire response matches the normalized contract.

`jev_recommend {task, query, kind: "tools"|"skills"}` is the usable one-call
path inside Niffler: it fetches fresh on-demand hints from `core.discover` or
skills from `skill_list`, limits the shortlist to 24, and asks the backend.
Use a **narrow nonempty query**; empty or overlarge lists refuse, never
silently omit candidates. It returns the shortlist and the suggestion, but
**does not call discover for schemas, load a skill, or execute anything**.
Call via `discover {component: "jev", tools: ["jev_recommend"]}` then
`invoke {tool: "jev_recommend", arguments: {task: "…", query: "…"}}`.
`jev_suggest` remains available for callers with their own shortlist.
Both are opt-in, not automatic per turn. Existing core discovery and frozen
prefix remain unchanged.

Example for callers providing their own shortlist:

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

## Shadow experiment

Shadow judging is enabled by default for both installed skills and discoverable
on-demand tools. Set `NIF_JEV_SHADOW=0` to disable it. At turn start, Jev
queues up to two independent observations using the turn's request (limited to
2,000 bytes): one uses the complete current skill list; the other searches
`core.discover` using the longest word in the request as its lexical query.
Set `NIF_JEV_SHADOW_SKILL_QUERY` or `NIF_JEV_SHADOW_TOOL_QUERY` to override;
the legacy `NIF_JEV_SHADOW_QUERY` sets both. Each candidate set is capped at
24; oversized sets are recorded as `no-candidates`, not truncated. Jev does
not load or invoke tools/skills or send its recommendation into the
conversation. The default tool query is a lexical query from the task text, so
inspect the persisted query and candidates when assessing its coverage.

A separate local judge process handles each inference, one at a time, keeping
the NATS pump responsive. Results store `sessionId`, `turnId`, candidate
snapshot, raw answers, and inference/queue timings in kind `jevshadow`; join
by `(sessionId, turnId)` with the transcript and tool-call events. The record
carries `status` (`done` when the answer parsed, `error` for a failed/timed-out
judge, `no-candidates`, `pending` while queued/in flight, `stale` when the
answer arrived after its turn closed) and `turnClosed`. An **absent backend**
is different: it writes no record at all — the in-flight `pending` marker is
deleted, one `ev.log.jev` warning marks the absence, and shadow launches
pause for a 60 s cooldown before retrying silently, so shadow resumes on its
own when Von comes up. Killing the component
mid-flight leaves its in-flight `pending` record behind; the judge process
carries PDEATHSIG and dies with it. Records contain the task and candidate
descriptions; treat them as sensitive. Tasks over 2,000 bytes and turns
skipped because the bounded queue is full are not judged.

## Evaluation before automation

CPU trial on this machine (not laptop evidence): `uv venv var/jev-venv --python
3.12 && uv pip install --python var/jev-venv/bin/python 'von-sdk>=1.1.0'`
installed the runtime (~5.4 GB including CUDA wheels). Von 1.1 in CPU mode
started on loopback; the first request, including model download/load, took
~115 s, subsequent 2-question requests took ~0.77–1.27 s with
`OMP_NUM_THREADS=4`. Four hand-written examples chose the expected option in
two relevant cases, but the `noul` was only 0.27 for one of them (Niffler
skill guidance), incorrectly suppressing the recommendation at the 0.5
threshold. A haiku task correctly returned no match. **Do not treat this as
validated ranking accuracy**; the no-match question/threshold needs a labeled
Niffler task set before automation. CPU RSS not yet measured.

`make test-jev` uses a mock backend and a private NATS bus; it proves the
contract, *not* Von accuracy or CPU latency — including the absent-backend
silence (one warning, no records) and transcript integrity. Build a held-out list of tasks
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
