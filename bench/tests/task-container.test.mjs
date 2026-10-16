import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { taskContainerName, startTaskContainer, stopTaskContainer } from "../lib/task-container.mjs";

test("task container names are stable, path-specific and shell-safe", () => {
  const name = taskContainerName("/workspace/a repo;$HOME");
  assert.match(name, /^nif-task-[a-f0-9]{24}$/);
  assert.equal(taskContainerName("/workspace/a repo;$HOME"), name);
  assert.notEqual(taskContainerName("/workspace/other"), name);
});

test("persistent offline task environment (opt-in Docker contract)", {
  skip: !process.env.NIF_TEST_TASK_IMAGE,
}, () => {
  const dir = fs.mkdtempSync(path.resolve("var/task-container-test-"));
  const repo = path.join(dir, "repo");
  fs.mkdirSync(repo);
  execFileSync("git", ["init", "-q", repo]);
  let name;
  try {
    name = startTaskContainer(repo, process.env.NIF_TEST_TASK_IMAGE);
    const shell = path.join(dir, "container-shell");
    const call = (script) => execFileSync(shell, ["-c", script], { cwd: repo, encoding: "utf8" });
    call("echo persistent >/tmp/nif-persist; echo host-owned >owned; git add owned");
    assert.equal(call("cat /tmp/nif-persist").trim(), "persistent");
    assert.equal(fs.statSync(path.join(repo, "owned")).uid, process.getuid());
    assert.equal(fs.statSync(path.join(repo, ".git/index")).uid, process.getuid());
    assert.equal(call("cat /app/owned").trim(), "host-owned");
    assert.equal(call("git diff --cached --numstat").trim(), "1\t0\towned");
    const toolModule = process.env.NIF_TEST_PI_BASH_MODULE;
    if (toolModule) {
      // Exercise Pi's actual stock bash tool with our configured shellPath,
      // not just the wrapper executable, without calling an LLM.
      const probe = `import { createBashTool } from ${JSON.stringify(toolModule)};
        const tool = createBashTool(${JSON.stringify(repo)}, {shellPath:${JSON.stringify(shell)}});
        const a = await tool.execute('a', {command:'echo pi-persistent >/tmp/pi-persist'});
        const b = await tool.execute('b', {command:'cat /tmp/pi-persist'});
        if (!JSON.stringify(b).includes('pi-persistent')) throw new Error(JSON.stringify(b));`;
      execFileSync("node", ["--input-type=module", "-e", probe], { cwd: repo });
    }
    const inspect = JSON.parse(execFileSync("docker", ["inspect", name], { encoding: "utf8" }))[0];
    assert.equal(inspect.HostConfig.NetworkMode, "none");
    assert.equal(inspect.Mounts.every((m) => m.Source === repo), true);
  } finally {
    if (name) stopTaskContainer(name);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
