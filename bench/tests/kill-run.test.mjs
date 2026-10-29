import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawn, execFileSync } from "node:child_process";
import { once } from "node:events";

const script = path.resolve("scripts/kill-run.sh");

test("kill-run rejects directory traversal", { skip: process.platform !== "linux" }, () => {
  assert.throws(() => execFileSync("bash", [script, ".."], { stdio: "pipe" }),
    (error) => error.status === 2);
});

// A typo must not look like a successful kill. Before this check the script
// matched nothing and printed "sent SIGKILL to 0 process(es)", which reads as
// a clean stop of a run that never existed.
test("kill-run refuses a run id that does not exist", {
  skip: process.platform !== "linux",
}, () => {
  assert.throws(() => execFileSync("bash", [script, "no-such-run-abc123"],
    { stdio: "pipe", encoding: "utf8" }),
    (error) => error.status === 2 && /no such run directory/.test(error.stderr));
});

// The matcher once used `-lname "**"`, which matches every /proc/<pid>/cwd on
// the host: the script then SIGKILLed every process of the invoking user, and
// one `make test-bench` on a live desktop killed the GNOME session (no crash,
// no log line — a bare logout). `--list` prints the match set without killing
// anything, so the scope of the scan is now asserted directly: exactly the
// run's own processes, nothing else on the machine.
test("kill-run --list matches only processes inside the run directory", {
  skip: process.platform !== "linux",
}, async () => {
  const base = path.resolve("var/bench/results");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "kill-scope-"));
  const neighbor = root + "-other";
  fs.mkdirSync(neighbor);
  const decoys = [
    spawn("sleep", ["60"], { cwd: neighbor }), // a sibling run
    spawn("sleep", ["60"], { cwd: process.cwd() }), // anything else
  ];
  const mine = [
    spawn("sleep", ["60"], { cwd: root }),
    spawn("sleep", ["60"], { cwd: root }),
  ];
  try {
    await Promise.all([...decoys, ...mine].map((c) => once(c, "spawn")));
    const output = execFileSync("bash", [script, "--list", path.basename(root)], {
      encoding: "utf8",
    });
    const listed = output.split("\n").filter(Boolean).map(Number).sort();
    assert.deepEqual(listed, mine.map((c) => c.pid).sort());
    for (const decoy of decoys) assert.ok(!listed.includes(decoy.pid));
    assert.ok(!listed.includes(process.pid));
    // Nothing outside the run directory survives in the match set at all.
    assert.ok(listed.length <= 2, `matched ${listed.length} processes: ${output}`);
  } finally {
    for (const child of [...decoys, ...mine]) child.kill("SIGKILL");
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(neighbor, { recursive: true, force: true });
  }
});

test("kill-run kills only the exact run and counts processes", {
  skip: process.platform !== "linux",
}, async () => {
  const base = path.resolve("var/bench/results");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "kill-contract-"));
  const neighbor = root + "-other";
  fs.mkdirSync(neighbor);
  const children = [];
  try {
    for (const cwd of [root, root, neighbor]) {
      const child = spawn("sleep", ["60"], { cwd });
      children.push(child);
      await once(child, "spawn");
    }
    const exits = children.slice(0, 2).map((child) => once(child, "exit"));
    const output = execFileSync("bash", [script, path.basename(root)], { encoding: "utf8" });
    await Promise.all(exits);
    assert.match(output, /sent SIGKILL to 2 process\(es\)/);
    assert.equal(children[2].exitCode, null);
    process.kill(children[2].pid, 0);
  } finally {
    for (const child of children) child.kill("SIGKILL");
    fs.rmSync(root, { recursive: true, force: true });
    fs.rmSync(neighbor, { recursive: true, force: true });
  }
});
