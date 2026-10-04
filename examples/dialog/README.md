# dialog — the SDK-free bash component demo

`dialog.sh` is a complete Niffler component written in **pure bash**: no SDK,
no build step — it speaks the wire protocol (docs/WIRE.md) directly with the
`nats` CLI and `jq`. It registers two tools, `dialog_show` and `dialog_ask`,
and when the agent calls them a real dialog pops up on your desktop (zenity,
falling back to notify-send).

It exists to demonstrate the component model at its thinnest: a component is
*any* process that exchanges JSON envelopes over NATS. When it moved out of
the shipped build, it was carrying three dependencies (nats CLI, jq, zenity)
for one non-autostarted demo — exactly the weight a demo should not put on
every install.

## Dependencies

- the nats CLI (`natscli`): `go install github.com/nats-io/natscli/nats@latest`
- `jq`
- `zenity` (Ubuntu) or `notify-send` for the visual effect

## Run it

Boot any Niffler harness (`niffler-tui`, or `./var/bin/niffler`), then:

```
bash examples/dialog/dialog.sh
```

It announces `dialog` on the bus and answers `dialog_show` / `dialog_ask`
calls until you Ctrl-C. Ask the agent to "show me a dialog saying hello" to
see the full loop.

## Why this is an example and not a plugin package

`niffler.json` manifests currently accept `lang: nim | go | ts` only
(`components/plugins/main.nim` rejects anything else), and manifest-v2 build
recipes are argv-based with shell wrappers refused — by design. So a pure
script component cannot ride the plugin lifecycle yet. To publish this as a
real `niffler-component` package one would either wrap it in a tiny Go/Nim
shim, or the manifest would need to grow a script/`runner` component kind.
Until then it lives here as copy-paste documentation of the protocol.
