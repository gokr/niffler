import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";

export function taskContainerName(repo) {
  return "nif-task-" + crypto.createHash("sha256").update(repo).digest("hex").slice(0, 24);
}

// One offline container per live cell, shared by all commands in that cell.
// /app and the host spelling are the same bind mount, not two copies.
export function startTaskContainer(repo, image, aliases = []) {
  const name = taskContainerName(repo);
  const docker = (args) => execFileSync("docker", args, { encoding: "utf8", timeout: 540000 });
  docker(["run", "-d", "--name", name, "--network", "none", "--entrypoint", "sleep",
    "-v", `${repo}:/app`, "-v", `${repo}:${repo}`,
    ...aliases.flatMap((alias) => ["-v", `${repo}:${alias}`]), image, "infinity"]);
  try {
    // Preserve image-installed caches/toolchains, while making their home
    // writable for the host UID. No host home or credentials are mounted.
    docker(["exec", name, "bash", "-c",
      `chmod o+x /root; find /root -type d -exec chown ${process.getuid()}:${process.getgid()} {} +`]);
    docker(["exec", "--user", `${process.getuid()}:${process.getgid()}`, "-e", "HOME=/root",
      "-w", "/app", name, "bash", "-c", "set -e; git status --porcelain >/dev/null; echo readiness-ok"]);
    const shell = path.join(repo, "..", "container-shell");
    fs.writeFileSync(shell, `#!/bin/bash\nexec docker exec --user ${process.getuid()}:${process.getgid()} -e HOME=/root -w "$PWD" ${name} bash "$@"\n`, { mode: 0o755 });
    return name;
  } catch (error) {
    stopTaskContainer(name);
    throw error;
  }
}

export function stopTaskContainer(name) {
  execFileSync("docker", ["rm", "-f", name], { stdio: "ignore", timeout: 30000 });
}
