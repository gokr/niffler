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
import hashlib

ROOT = Path(__file__).resolve().parents[1]


def run(code, *, schemas=None, inputs=None, replies=None, cache_dir=None,
        compile_ms_budget=None):
    with tempfile.TemporaryDirectory(prefix="fabric-native-") as work:
        with tempfile.TemporaryFile() as stderr:
            env = {"PATH": os.environ["PATH"], "HOME": work, "TMPDIR": work}
            if cache_dir is not None:
                env["FABRIC_CACHE_DIR"] = str(cache_dir)
            p = subprocess.Popen(
                [str(ROOT / "var/bin/fabric-exec")], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=stderr, env=env, cwd=work,
            )
            ctx = {"code": code, "buildDir": work, "strings": inputs or {}}
            if schemas is not None:
                ctx["schemas"] = schemas
            p.stdin.write((json.dumps(ctx) + "\n").encode())
            p.stdin.flush()
            frames = []
            pending = b""
            end = time.monotonic() + (compile_ms_budget or 30)
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

    # ---- content-addressed executable cache: a second identical run hits ----
    code = '''import fabricguest\nfinish(%*{"v": 1})\n'''
    with tempfile.TemporaryDirectory(prefix="fabric-cache-") as cache:
        cache_path = Path(cache)
        first, f1 = run(code, cache_dir=cache)
        assert first.get("ok"), first
        phase1 = [f for f in f1 if f["t"] == "phase"]
        assert phase1 and phase1[-1].get("cacheHit") is False, phase1
        cold = phase1[-1].get("compileMs", 0)
        second, f2 = run(code, cache_dir=cache)
        assert second.get("ok"), second
        phase2 = [f for f in f2 if f["t"] == "phase"]
        assert phase2 and phase2[-1].get("cacheHit") is True, phase2
        assert len(list(cache_path.iterdir())) == 1
        print(f"OK: executable cache (cold {cold}ms, hit {phase2[-1].get('compileMs')}ms)")

        # a DIFFERENT program is a distinct cache entry (correct keying)
        other, _ = run('import fabricguest\nfinish(%*{"v": 2})\n', cache_dir=cache)
        assert other.get("ok"), other
        assert len(list(cache_path.iterdir())) == 2
        print("OK: cache key distinguishes distinct programs")

    # ---- process-group reaping: a hung guest and its children die on kill ----
    with tempfile.TemporaryDirectory(prefix="fabric-hang-") as work:
        pidfile = Path(work) / "child.pid"
        # the guest spawns a child that outlives it, records the pid, then hangs
        code = f'''import fabricguest, std/osproc, std/os, std/strutils
let p = startProcess("/bin/sleep", args = ["600"])
writeFile("{pidfile}", $p.processID)
while true: sleep(1000)
'''
        ctx = {"code": code, "buildDir": work, "strings": {}}
        env = {"PATH": os.environ["PATH"], "HOME": work, "TMPDIR": work}
        p = subprocess.Popen([str(ROOT / "var/bin/fabric-exec")],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, cwd=work, env=env)
        p.stdin.write((json.dumps(ctx) + "\n").encode()); p.stdin.flush()
        # wait until the child records its pid (compile + spawn)
        for _ in range(60):
            if pidfile.exists() and pidfile.read_text().strip():
                break
            time.sleep(0.2)
        assert pidfile.exists(), "guest never spawned its child"
        child_pid = int(pidfile.read_text().strip())
        # the executor is its own process group leader (setsid); kill the group
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait(timeout=5)
        time.sleep(0.3)
        alive = os.path.exists(f"/proc/{child_pid}")
        if not alive:  # non-procfs fallback
            try:
                os.kill(child_pid, 0); alive = True
            except ProcessLookupError:
                alive = False
        if alive:
            os.kill(child_pid, signal.SIGKILL)
        assert not alive, f"orphaned descendant {child_pid} survived the group kill"
        print("OK: process-group kill reaps the guest and its descendants")

    # ---- compile timeout: a non-terminating compile-time loop is bounded ----
    hang = 'import fabricguest\nstatic:\n  while true: discard\nfinish(%*{})\n'
    result, frames = run(hang, compile_ms_budget=40)
    # The executor must not return success for a program that never ran. Either
    # the compile is killed (deadline) or the compiler itself aborts it.
    assert not result.get("ok"), result
    print("OK: non-terminating program never reports success")

    print("fabric native PASSED")


if __name__ == "__main__":
    main()
