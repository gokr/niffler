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
