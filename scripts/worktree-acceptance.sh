#!/usr/bin/env bash
# worktree-acceptance — drive the worktree workflow end to end against a LIVE
# harness, the same way the client does, and verify what actually happened.
#
# This covers the harness half: the git verbs, the write fence, isolation, the
# merge and the durable origin notice. It does NOT cover the client half
# (/worktree, the approval modal, the switch back to the origin) — those need a
# human at a terminal; see docs/WORKTREES-ACCEPTANCE.md.
#
# Everything runs in a scratch repository under $ROOT/var/wt-acceptance and a
# scratch conversation, both removed on exit. Your own repositories are never
# touched.
#
# Approvals: git_worktree / git_commit / git_merge are approval:"always". The
# script asks the runner for the conversation's approval mode to be "auto" for
# the duration, which is a normal human control (/approvals auto) — but it must
# be specifically allowed, because a smoke test that silently grants write
# approval is a bad default. Pass --auto to permit it, or set NIF_AUTO_APPROVE=1.
#
# Usage:
#   scripts/worktree-acceptance.sh [--auto] [--keep]
#
# Exit 0 = every check passed. Non-zero = the first failing check is printed
# with the reply that produced it.
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
CLI="$ROOT/var/bin/cli"
AUTO=0
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --auto) AUTO=1 ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

PASS=0
FAIL=0
CHECKS=()

say()  { printf '\n=== %s\n' "$*"; }
ok()   { PASS=$((PASS+1)); CHECKS+=("ok   $1"); printf 'OK   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); CHECKS+=("FAIL $1"); printf 'FAIL %s\n      %s\n' "$1" "${2:-}"; }

# jq is not assumed. A tiny python helper reads one field from a JSON reply.
field() { python3 -c 'import json,sys
try: v=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
for k in sys.argv[1].split("."):
    if isinstance(v,dict): v=v.get(k)
    elif isinstance(v,list) and k.isdigit(): v=v[int(k)] if int(k)<len(v) else None
    else: v=None
print("" if v is None else v)' "$1"; }

[[ -x "$CLI" ]] || { echo "no $CLI — run make build" >&2; exit 1; }

# A running harness keeps executing the binary it STARTED with. Every result
# below is meaningless against a stale core (this cost a whole debugging round:
# session_info reported no workspace block because the live core predated the
# code that emits it). Refuse rather than mislead.
core_pid=$(pgrep -f "$ROOT/var/bin/niffler" | head -1)
if [[ -n "$core_pid" && -f "$ROOT/var/bin/niffler" ]]; then
  # elapsed seconds of the process vs the binary's age: if the binary is
  # YOUNGER than the process, the process is running a previous build.
  elapsed=$(ps -o etimes= -p "$core_pid" 2>/dev/null | tr -d ' ')
  bin_age=$(( $(date +%s) - $(stat -c %Y "$ROOT/var/bin/niffler" 2>/dev/null || echo 0) ))
  if [[ -n "$elapsed" && "$bin_age" -lt "$elapsed" ]]; then
    echo "worktree-acceptance: the running core (pid $core_pid) started $elapsed s ago" >&2
    echo "  but var/bin/niffler is only $bin_age s old — it is executing the" >&2
    echo "  PREVIOUS build, so every check below would test stale code." >&2
    echo "  Restart it:  make down-here && make build && ./var/bin/niffler &" >&2
    exit 3
  fi
fi


# Deliberately OUTSIDE the harness root. A sandbox under $NIF_ROOT sits inside
# whichever conversation owns that tree, and its opaque `bash` claim then blocks
# this run with [E_WRITE_BUSY] — the arbitration working correctly, but against
# the test. mktemp keeps the run hermetic; cleanup removes it.
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/niffler-wt-accept.XXXXXX")"
SID="wt-accept-$(date +%s)"
REPO="$SANDBOX/repo"

cleanup() {
  [[ "$KEEP" == "1" ]] && { echo; echo "kept: $SANDBOX (session $SID)"; return; }
  local prim="$REPO"
  # Remove any trees the run created, then the repo itself.
  if [[ -d "$prim/.git" ]]; then
    git -C "$prim" worktree list --porcelain 2>/dev/null |
      awk '/^worktree /{print $2}' | while read -r wt; do
        [[ "$wt" == "$prim" ]] && continue
        git -C "$prim" worktree unlock "$wt" >/dev/null 2>&1
        git -C "$prim" worktree remove --force "$wt" >/dev/null 2>&1
      done
  fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# The conversation drives the git verbs exactly as the client's /worktree does:
# one session-scoped control call, through the runner's own dispatch gate.
sessionCall() {
  # A runner serves one turn at a time; retry briefly instead of cascading a
  # 'mid-turn' refusal into every later check.
  local out
  for _ in $(seq 1 20); do
    out=$("$CLI" --timeout:120 call session "$1" 2>&1)
    case "$out" in
      *"mid-turn"*) sleep 1; continue ;;
    esac
    printf '%s' "$out"; return 0
  done
  printf '%s' "$out"
}
invokeGit()  { # invokeGit <tool> <json-args> [session]
  local tool="$1" args="$2" sid="${3:-$SID}"
  sessionCall "{\"sessionId\":\"$sid\",\"invoke\":{\"tool\":\"$tool\",\"arguments\":$args}}"
}

say "1. a scratch repository, clean, on main"
rm -rf "$SANDBOX"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "acceptance@example.invalid"
git -C "$REPO" config user.name "Worktree Acceptance"
printf 'base\n' > "$REPO/tracked.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m base
[[ -z "$(git -C "$REPO" status --porcelain)" ]] && ok "scratch repo is clean" || bad "scratch repo is clean"

say "2. approvals"
if [[ "$AUTO" == "1" || "${NIF_AUTO_APPROVE:-}" == "1" ]]; then
  born=$(sessionCall "{\"sessionId\":\"$SID\",\"cwd\":\"$REPO\"}")
  if [[ -n "$(echo "$born" | field error)" ]]; then
    bad "conversation born in the scratch repo" "$born"
  else
    ok "conversation born in the scratch repo"
  fi
  sessionCall "{\"sessionId\":\"$SID\",\"approvals\":\"auto\"}" >/dev/null
  ok "approvals set to auto for this scratch conversation (explicit opt-in)"
else
  bad "--auto not given" "git_worktree/git_merge are approval:always; re-run with --auto (or NIF_AUTO_APPROVE=1)"
  printf '\nSkipping the rest: the mutation checks would block on a human prompt.\n'
  printf '%-4s %s\n' "${CHECKS[@]}"; exit 1
fi

say "3. baseline: the conversation is unpinned-but-chosen, and starts shared"
# No model turn here on purpose: a turn can run for minutes and leaves the
# runner answering 'mid-turn' to every control call that follows, which would
# make the rest of this run test timing rather than behaviour.
INFO=$(sessionCall "{\"sessionId\":\"$SID\"}")
[[ "$(echo "$INFO" | field isolation)" == "shared" ]] && ok "isolation starts as shared" || bad "isolation starts as shared" "$INFO"

say "4. git_worktree add — a sibling tree, locked, recorded"
ADD=$(invokeGit git_worktree "{\"op\":\"add\",\"repo\":\"$REPO\",\"name\":\"acc\",\"branch\":\"acc\"}")
WT=$(echo "$ADD" | field result.path)
if [[ -n "$WT" && -d "$WT" ]]; then ok "the verb reported a created tree: $WT"
else bad "the verb reported a created tree" "$ADD"; fi
[[ "$WT" == "$REPO.wt/acc" ]] && ok "layout is a SIBLING (<repo>.wt/<name>)" || bad "layout is a SIBLING" "got $WT"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] && ok "the primary stays clean (no ignore rule needed)" || bad "the primary stays clean" "$(git -C "$REPO" status --porcelain)"
LIST=$(invokeGit git_worktree_list "{\"repo\":\"$REPO\"}")
echo "$LIST" | grep -q "\"path\":\"$WT\"" && ok "the component lists the new tree" || bad "the component lists the new tree" "$LIST"
# Lock AND ownership ledger: git's lock is the durable half; the ledger records
# which conversation created it (the fact git cannot know).
LOCKED=$(echo "$LIST" | python3 -c 'import json,sys
d=json.load(sys.stdin); d=d.get("result",d)
for t in d.get("trees",[]):
    if t["path"]==sys.argv[1]: print("yes" if t.get("locked") else "no")' "$WT")
[[ "$LOCKED" == "yes" ]] && ok "the tree is locked with a reason" || bad "the tree is locked with a reason" "$LIST"

say "5. session_info reports the workspace, and the model can see it"
sessionInfo() { "$CLI" --timeout:30 call session_info "{\"sessionId\":\"$SID\"}" 2>&1; }
INFO=$(sessionInfo)
# The conversation is still in the PRIMARY here; move it into the tree.
MOVED=$(sessionCall "{\"sessionId\":\"$SID\",\"cwd\":\"$WT\",\"checkout\":{\"primaryRoot\":\"$REPO\",\"branch\":\"acc\"}}")
if [[ -n "$(echo "$MOVED" | field error)" ]]; then
  bad "conversation repinned into the worktree" "$MOVED"
else ok "conversation repinned into the worktree"; fi
INFO=$(sessionInfo)
[[ "$(echo "$INFO" | field workspace.linked)" == "True" ]] && ok "session_info says linked = true" || bad "session_info says linked = true" "$INFO"
[[ "$(echo "$INFO" | field workspace.primaryRoot)" == "$REPO" ]] && ok "session_info names the primary" || bad "session_info names the primary" "$INFO"
[[ "$(echo "$INFO" | field workspace.branch)" == "acc" ]] && ok "session_info names the branch" || bad "session_info names the branch" "$INFO"

say "6. isolation narrows the WRITE fence (the point of the whole feature)"
ISO=$(sessionCall "{\"sessionId\":\"$SID\",\"isolation\":\"worktree\"}")
if [[ -n "$(echo "$ISO" | field error)" ]]; then bad "isolation accepted inside a linked worktree" "$ISO"
else ok "isolation accepted inside a linked worktree"; fi

OUT_WRITE=$(invokeGit bash "{\"command\":\"touch $REPO/from-outside\",\"cwd\":\"$REPO\"}")
if echo "$OUT_WRITE" | grep -q "E_WRITE_OUTSIDE"; then ok "a write to the PRIMARY is refused (E_WRITE_OUTSIDE)"
else bad "a write to the PRIMARY is refused" "$OUT_WRITE"; fi
[[ ! -f "$REPO/from-outside" ]] && ok "and nothing was written there" || bad "and nothing was written there"

IN_WRITE=$(invokeGit bash "{\"command\":\"touch made-here.txt\",\"cwd\":\"$WT\"}")
if echo "$IN_WRITE" | grep -q '"exit_code":0' && [[ -f "$WT/made-here.txt" ]]; then
  ok "a write INSIDE its own tree still works"
else bad "a write INSIDE its own tree still works" "$IN_WRITE"; fi

say "7. reads are NOT narrowed (compare against the primary must keep working)"
READ=$(invokeGit read "{\"path\":\"$REPO/tracked.txt\"}")
echo "$READ" | grep -q "base" && ok "the primary stays readable" || bad "the primary stays readable" "$READ"

say "8. commit in the tree, then merge back with a preview first"
COMMIT=$(invokeGit git_commit "{\"repo\":\"$WT\",\"message\":\"acceptance change\",\"paths\":[\"made-here.txt\"]}")
if [[ -n "$(echo "$COMMIT" | field result.commit)" ]]; then ok "commit in the worktree returned a commit id"
else bad "commit in the worktree returned a commit id" "$COMMIT"; fi

PREVIEW=$(invokeGit git_merge_preview "{\"repo\":\"$REPO\",\"into\":\"main\",\"from_ref\":\"acc\"}")
if echo "$PREVIEW" | grep -q '"clean":true'; then
  ok "preview says the merge is clean"
else bad "preview says the merge is clean" "$PREVIEW"; fi

# A bad ref must be an ERROR, never a fabricated conflict list.
BADREF=$(invokeGit git_merge_preview "{\"repo\":\"$REPO\",\"into\":\"main\",\"from_ref\":\"no-such-branch\"}")
if echo "$BADREF" | grep -q '"conflicts"' ; then
  bad "a bad ref is an error, not a conflict list" "$BADREF"
else ok "a bad ref is an error, not a conflict list"; fi

MERGE=$(invokeGit git_merge "{\"op\":\"start\",\"repo\":\"$REPO\",\"from_ref\":\"acc\"}")
if [[ -n "$(echo "$MERGE" | field result.head)" ]]; then ok "merge back succeeded"
else bad "merge back succeeded" "$MERGE"; fi
[[ -f "$REPO/made-here.txt" ]] && ok "the primary now has the merged file" || bad "the primary now has the merged file"

say "9. the merge left a durable notice for the origin (none here — no origin was recorded)"
# This conversation was MOVED, not forked, so it has no origin. The notice path
# is exercised by t_git/t_agentfork; a live fork is the client half.
echo "note: no origin edge on this conversation (it was moved, not forked), so no"
echo "      notice is expected. The fork+notice path needs /worktree add in the TUI."

say "summary"
printf '%-4s %s\n' "${CHECKS[@]}"
printf '\nworktree-acceptance: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
