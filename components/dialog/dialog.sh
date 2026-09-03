#!/usr/bin/env bash
# dialog — a Niffler component written entirely in bash.
#
# No SDK, no compile step: the wire contract is JSON envelopes over NATS
# (docs/WIRE.md), and this script speaks it directly with the nats CLI and
# jq. When the agent calls dialog_show / dialog_ask, a real dialog pops up
# on the user's desktop (zenity), falling back to notify-send, then to a
# log line when neither display tool exists (headless).
#
# Prerequisites (demo-scope, not part of the core harness deps):
#   - nats CLI (natscli: go install github.com/nats-io/natscli/nats@latest)
#   - jq
#   - zenity (Ubuntu) or notify-send for the visual effect
#
# Install:  make build puts it in var/bin/dialog, then the agent (or you)
#           core.spawn {name: "dialog", binary: "<repo>/var/bin/dialog"}.
#           Spawning is approval-gated like every new component.
set -euo pipefail

NAME="dialog"
VERSION="0.1.0"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

# Bus discovery mirrors the SDKs: NIF_NATS_URL → ./var/nats-url → 4222.
bus_url() {
  if [[ -n "${NIF_NATS_URL:-}" ]]; then
    echo "$NIF_NATS_URL"
  elif [[ -f var/nats-url ]]; then
    head -1 var/nats-url
  else
    echo "nats://127.0.0.1:4222"
  fi
}
BUS="$(bus_url)"

# nats CLI resolution: PATH first (make setup installs natscli), then the
# default go install location, then an explicit override.
nats_cli() {
  if command -v nats >/dev/null 2>&1; then
    command -v nats
  elif [[ -x "${HOME}/go/bin/nats" ]]; then
    echo "${HOME}/go/bin/nats"
  else
    echo "${NIF_NATS_CLI:-nats}"
  fi
}
NATS="$(nats_cli)"

# Logs go to a file, never stderr: nats reply --command replies with the
# command's COMBINED output, and the reply payload must stay pure JSON.
LOG="${NIF_ROOT:-$HOME}/var/logs/dialog.log"
log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  printf 'dialog: %s\n' "$*" >>"$LOG" 2>/dev/null || true
}

# reg.publish — announce ourselves exactly the way the SDKs do:
# the BARE reg payload is the message data (no envelope wrapper — unlike
# ev.* events; docs/WIRE.md). A quoted heredoc keeps apostrophes and
# quotes in descriptions from fighting the shell.
register() {
  log "registering on $BUS (pid $$)"
  local payload
  payload=$(jq -nc --arg name "$NAME" --arg version "$VERSION" --argjson pid "$$" -f /dev/stdin <<'JQFILTER'
  {
    name: $name,
    version: $version,
    pid: $pid,
    language: "bash",
      tools: [
        {
          name: "dialog_show",
          schema: {
            type: "object",
            description: "Show a desktop dialog (or notification) on the user's screen: an info, warning or error box. Use it to make the agent visible — announce that a long task finished, flag a problem, or draw the user's attention. The call returns once the dialog is dismissed or times out (30s).",
            properties: {
              message: { type: "string", description: "Text to display" },
              title:   { type: "string", description: "Window title (default: Niffler says)" },
              kind:    { type: "string", enum: ["info", "warning", "error"], description: "Dialog flavor (default: info)" }
            },
            required: ["message"],
            "x-harness": { "timeoutMs": 45000 }
          }
        },
        {
          name: "dialog_ask",
          schema: {
            type: "object",
            description: "Ask the user a yes/no question in a desktop dialog and return their answer (yes, no or timeout). Use it when a decision genuinely belongs to the human — deploy confirmation, a breaking change, choosing between alternatives. Blocks until the user answers or the dialog times out.",
            properties: {
              message: { type: "string", description: "The question" },
              title:   { type: "string", description: "Window title (default: Niffler asks)" }
            },
            required: ["message"],
            "x-harness": { "timeoutMs": 120000 }
          }
        }
      ]
  }
JQFILTER
)
  # Payload as the message argument (nats pub skips stdin unless forced).
  "$NATS" --server "$BUS" pub reg.publish "$payload"
}

# ---------------------------------------------------------------------------
# display backends
# ---------------------------------------------------------------------------

# show MESSAGE TITLE KIND → prints "via|extra" (via: zenity | notify | log)
show_dialog() {
  local message="$1" title="$2" kind="${3:-info}"
  if [[ -n "${DISPLAY:-}" ]] && command -v zenity >/dev/null 2>&1; then
    case "$kind" in
      warning|error) ;;
      *) kind="info" ;;
    esac
    zenity "--$kind" --title "$title" --text "$message" --timeout 30 >/dev/null 2>&1 || true
    echo "zenity"
    return
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u normal "$title" "$message" >/dev/null 2>&1 || true
    echo "notify"
    return
  fi
  echo "log"
}

# ask MESSAGE TITLE → prints "yes|no|timeout", side-stderr reports the backend
ask_dialog() {
  local message="$1" title="$2"
  if [[ -n "${DISPLAY:-}" ]] && command -v zenity >/dev/null 2>&1; then
    zenity --question --title "$title" --text "$message" \
      --ok-label "Yes" --cancel-label "No" --timeout 60 >/dev/null 2>&1
    local rc=$?
    case $rc in
      0) echo "yes"; return ;;
      1) echo "no";  return ;;
      *) echo "timeout"; return ;;
    esac
  fi
  # Headless: no human can answer — be honest about it.
  echo "timeout"
}

# ---------------------------------------------------------------------------
# call handler — nats reply --command spawns this per request with
# NATS_REQUEST_BODY set; our stdout IS the reply envelope.
# ---------------------------------------------------------------------------

handle() {
  local body="${NATS_REQUEST_BODY:-}"
  if [[ -z "$body" ]]; then
    body="$(cat)"
  fi
  local id tool args_json message title
  # || true: a handler exiting non-zero gets NO reply at all (nats reply
  # only responds on exit 0) — always answer, even to garbage.
  id="$(jq -r '.id // empty' <<<"$body" 2>/dev/null || true)"
  tool="$(jq -r '.tool // empty' <<<"$body" 2>/dev/null || true)"
  args_json="$(jq -c '.args // {}' <<<"$body" 2>/dev/null || echo '{}')"
  message="$(jq -r '.message // ""' <<<"$args_json" 2>/dev/null || true)"

  local result
  case "$tool" in
    dialog_show)
      title="$(jq -r '.title // "Niffler says"' <<<"$args_json" 2>/dev/null || true)"
      local kind
      kind="$(jq -r '.kind // "info"' <<<"$args_json" 2>/dev/null || true)"
      local via
      via="$(show_dialog "$message" "$title" "$kind")"
      log "dialog_show via=$via kind=$kind"
      result="$(jq -nc --arg via "$via" --arg kind "$kind" \
        '{ok: true, shown: true, via: $via, kind: $kind}')"
      ;;
    dialog_ask)
      title="$(jq -r '.title // "Niffler asks"' <<<"$args_json" 2>/dev/null || true)"
      local answer
      answer="$(ask_dialog "$message" "$title")"
      log "dialog_ask answer=$answer"
      result="$(jq -nc --arg answer "$answer" '{ok: true, answer: $answer}')"
      ;;
    *)
      result="$(jq -nc '{ok: false, error: "unknown tool", code: "no-tool"}')"
      ;;
  esac

  # Reply envelope: same id, kind "result", result object in args.
  jq -nc --arg id "$id" --arg tool "$tool" --argjson args "$result" \
    '{v: 1, id: $id, kind: "result", tool: $tool, args: $args}'
}

# ---------------------------------------------------------------------------
# main: subscribe first (no call may arrive before we can answer), then
# announce. The nats reply child is killed with us on SIGTERM.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# main: subscribe first (no call may arrive before we can answer), then
# announce. The nats reply child is killed with us on SIGTERM.
# ---------------------------------------------------------------------------

main() {
  # The handler's combined output IS the reply payload — nothing may ever
  # reach stderr inside handle() (nats reply sends CombinedOutput back).
  "$NATS" --server "$BUS" reply \
    --command "bash '$SELF' handle" "svc.$NAME.call" &
  # Script-level, not local: the EXIT trap runs after this function's scope
  # is unwound, and set -u would abort the trap on an unbound local.
  reply_pid=$!
  trap 'kill "$reply_pid" 2>/dev/null || true' EXIT TERM INT

  # Give the subscription a moment to activate server-side, then announce.
  sleep 0.5
  register

  wait "$reply_pid"
}

if [[ "${1:-}" == "handle" ]]; then
  handle
else
  main
fi
