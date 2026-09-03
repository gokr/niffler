# hooks — event-driven shell commands

Runs a shell command when a selected bus event fires. The event payload
arrives as **pretty JSON on stdin**; the firing subject is in
`$NIF_HOOK_SUBJECT`... actually just stdin — the command itself never sees
interpolation, which is what keeps it argv-safe. Output of a failing hook
goes to the supervisor log (`var/logs/hooks.log`); a failing hook never
affects the harness.

This is the observe-only subset of CodeWhale's hooks
(docs/research/CODEWHALE.md): no steering/veto — Niffler's approval gate is
in core dispatch, and hook-based veto would be a separate design.

## Configure

Hooks are env-configured at boot (a hookless boot stays up; change config
by `core.kill` + `core.spawn`, the harness's hot-change idiom):

```bash
NIF_HOOKS_EVENTS="ev.session.turn,ev.log.error"   # subjects to watch
NIF_HOOKS_EV_SESSION_TURN='your-command-here'      # subject → command
NIF_HOOKS_EV_LOG_ERROR='your-command-here'
NIF_HOOKS_TIMEOUT_MS=10000                         # per-hook, 100..60000
```

Subject→env mapping: dots and `>` become `_`, uppercased —
`ev.session.turn` → `NIF_HOOKS_EV_SESSION_TURN`, `ev.log.>` →
`NIF_HOOKS_EV_LOG_`.

## Event payloads you'll receive

| Subject | Fires | Payload highlights |
|---|---|---|
| `ev.session.turn` | finished user turn | `sessionId`, `turnId`, `phase: "done"`, `reply` |
| `ev.session.status` | per LLM round | `model`, `provider`, `promptTokens`, `usedTokens`, `usage`, `cacheHitTokens`, `cacheHitRatio` |
| `ev.session.context` | warn/trim | `reason` (`"reset:trim"`), `trimmed`, `warning` |
| `ev.log.error` (via `ev.log.>`) | component logged error | `level`, `msg`, `component` |

## Examples

### Desktop notification when a turn finishes (Linux)

```bash
NIF_HOOKS_EV_SESSION_TURN='notify-send "Niffler" "turn finished"'
```

macOS:

```bash
NIF_HOOKS_EV_SESSION_TURN='osascript -e "display notification \"turn finished\" with title \"Niffler\""'
```

### Sound alert

```bash
# Linux (PulseAudio):
NIF_HOOKS_EV_SESSION_TURN='paplay /usr/share/sounds/freedesktop/stereo/complete.oga'
# macOS:
NIF_HOOKS_EV_SESSION_TURN='afplay /System/Library/Sounds/Glass.aiff'
```

Turn the sound off again by removing the env and respawning — or gate it on
the session so long agent runs ping but quick chats don't:

```bash
# Only ping for replies longer than 200 chars (jq does the JSON parsing):
NIF_HOOKS_EV_SESSION_TURN='jq -r ".payload.reply // empty" | awk "length(\$0) > 200 { exit 0 } /^[[:space:]]*$/ { exit 1 }" && paplay /usr/share/sounds/freedesktop/stereo/complete.oga'
```

### Email on error (sendmail or msmtp)

```bash
NIF_HOOKS_EVENTS="ev.log.error"
NIF_HOOKS_EV_LOG_ERROR='{ jq -r ".payload.msg // \"(no message)\"" | mail -s "Niffler error" you@example.com ; }'
```

The subshell braces keep the pipeline together when `sh -c` wraps the
command. For msmtp, substitute `msmtp -t` with a To: header in the body.

### Email a session summary when a turn completes

```bash
NIF_HOOKS_EV_SESSION_TURN='jq -r "\"Session: \" + .payload.sessionId + \"\n\n\" + (.payload.reply // \"\")" | mail -s "Niffler turn done" you@example.com'
```

### Webhook (curl) — pipe into Slack/Discord/generic

```bash
NIF_HOOKS_EV_SESSION_TURN='jq -cn --arg t "$(cat)" "{text: \$t}" | curl -sf -X POST -H "Content-Type: application/json" -d @- https://hooks.example.com/TOKEN'
```

Discord wants `{"content": "..."}`; Slack wants `{"text": "..."}` — same
shape either way. The `-d @-` reads the JSON from stdin's pipe.

### Keep a private error tail

```bash
NIF_HOOKS_EVENTS="ev.log.>"
NIF_HOOKS_EV_LOG_='tee -a /tmp/niffler-errors.jsonl >/dev/null'
```

(Also a good smoke test: run this, trigger a turn, `cat /tmp/niffler-errors.jsonl`.)

## Testing a hook without the harness

The hook contract is trivial — JSON on stdin, exit code noted:

```bash
echo '{"payload":{"reply":"hello"}}' | sh -c 'jq -r .payload.reply'   # → hello
```

## Manifest

Ships disabled-by-default in `manifest.yaml` (`autostart: false`): add the
env vars to your harness environment and flip autostart, or spawn it
yourself after boot.
