#!/usr/bin/env python3
"""Native executor/guest contract tests, no NATS or LLM required.

Build var/bin/fabric-exec first. Every run owns a temporary build directory
and a process group; the protocol peer stubs ordinary host tool replies.
"""
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(code, *, schemas=None, inputs=None, replies=None):
    with tempfile.TemporaryDirectory(prefix="fabric-native-") as work:
        with tempfile.TemporaryFile() as stderr:
            p = subprocess.Popen(
                [str(ROOT / "var/bin/fabric-exec")], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=stderr,
                env={"PATH": os.environ["PATH"], "HOME": work, "TMPDIR": work},
                cwd=work,
            )
            ctx = {"code": code, "buildDir": work, "strings": inputs or {}}
            if schemas is not None:
                ctx["schemas"] = schemas
            p.stdin.write((json.dumps(ctx) + "\n").encode())
            p.stdin.flush()
            frames = []
            pending = b""
            end = time.monotonic() + 30
            try:
                with selectors.DefaultSelector() as sel:
                    sel.register(p.stdout, selectors.EVENT_READ)
                    while time.monotonic() < end:
                        if not sel.select(0.1):
                            continue
                        chunk = os.read(p.stdout.fileno(), 65536)
                        if not chunk:
                            stderr.seek(0)
                            raise AssertionError(stderr.read().decode())
                        pending += chunk
                        while b"\n" in pending:
                            line, pending = pending.split(b"\n", 1)
                            f = json.loads(line)
                            frames.append(f)
                            if f["t"] == "req":
                                args = json.loads(f["argsJson"])
                                response = replies(f["tool"], args) if replies else {"ok": True, "value": args}
                                answer = {"t": "resp", "id": f["id"], "ok": response["ok"]}
                                if response["ok"]:
                                    answer["result"] = json.dumps(response["value"])
                                else:
                                    answer["error"] = response["error"]
                                p.stdin.write((json.dumps(answer) + "\n").encode())
                                p.stdin.flush()
                            if f["t"] == "result":
                                p.wait(timeout=5)
                                return f, frames
                raise AssertionError("executor deadline exceeded")
            finally:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                if p.poll() is None:
                    p.kill()
                p.wait()
                p.stdin.close()
                p.stdout.close()


def success(code, **kwargs):
    result, frames = run(code, **kwargs)
    assert result.get("ok"), result
    return json.loads(result["value"]), frames


def main():
    value, frames = success('''import fabricguest
echo "not a protocol frame"
let nested = %*{"a": [1, 2], "s": "quote\\\" and newline\\n"}
finish(call("echo", nested))
''')
    assert value == {"a": [1, 2], "s": 'quote" and newline\n'}
    assert any(f["t"] == "phase" and f["compileMs"] >= 0 for f in frames)
    print("OK: native compilation, structured JSON round trip, stdout isolation")

    code = '''import fabricguest
var calls: seq[FabricCall]
for i in 0 ..< 33:
  calls.add(toolCall("echo", %*{"i": i}))
let outcomes = batch(calls)
var values = newJArray()
for item in outcomes:
  if item.ok: values.add(item.value)
  else: values.add(%*{"error": item.error})
finish(values)
'''
    def replies(tool, args):
        return {"ok": False, "error": "expected failure"} if args["i"] == 16 else {"ok": True, "value": args["i"]}
    value, frames = success(code, replies=replies)
    assert value == list(range(16)) + [{"error": "expected failure"}] + list(range(17, 33))
    assert len([f for f in frames if f["t"] == "req"]) == 33
    print("OK: structured batch auto-chunks, preserves order and individual errors")

    value, _ = success('''import fabricguest
finish(jobj(jpair("input", jesc(stringArg("name"))),
  jpair("result", callTool("echo", "{\\\"n\\\":3}"))))
''', inputs={"name": "fresh input"})
    assert value == {"input": "fresh input", "result": {"n": 3}}
    print("OK: legacy serialized API and runtime inputs")

    schema = [{"name": "echo", "schema": {"type": "object", "properties": {
        "message": {"type": "string"}}, "required": ["message"]}}]
    value, _ = success('import fabricguest\nfinish(tools.echo(message = "pinned"))\n', schemas=schema)
    assert value == {"message": "pinned"}
    print("OK: generated selected-tool wrapper in compiled guest")

    result, frames = run('import fabricguest\nproc broken(x: JArray) = discard\n')
    assert not result["ok"] and result["phase"] == "compile", result
    assert "guest.nim" in result.get("firstError", ""), result
    assert not any(f["t"] == "req" for f in frames)
    print("OK: structured compilation failure before tool dispatch")

    result, _ = run('import fabricguest\ndiscard\n')
    assert not result["ok"] and "without calling finish" in result["diagnostics"]
    print("OK: missing finish is not success")
    print("fabric native PASSED")


if __name__ == "__main__":
    main()
