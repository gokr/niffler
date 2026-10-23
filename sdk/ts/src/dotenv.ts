// .env loading — mirror of sdk/dotenv.nim and sdk/go/dotenv.go.
// KEY=VALUE lines (plus # comments, optional quotes); existing shell env
// always wins.

import * as fs from "fs";
import * as path from "path";

/** Absolute path with symlinks resolved where possible. */
function resolvePath(p: string): string {
  const abs = path.resolve(p);
  try {
    return fs.realpathSync(abs);
  } catch {
    return abs;
  }
}

function looksLikeClone(root: string): boolean {
  if (fs.existsSync(path.join(root, "niffler.nimble"))) return true;
  try {
    return fs.statSync(path.join(root, "var", "bin")).isDirectory();
  } catch {
    return false;
  }
}

/**
 * The directory a .env may come from, or "" when there is none.
 *
 * resolveNatsUrl's root is right for BUS discovery (a binary in <root>/var/bin
 * resolves that clone), but as a TRUST anchor it is unsound on its own: for a
 * binary outside that layout, climbing two directories lands on "/" or "/tmp",
 * which would make every path "inside the root". So an explicit NIF_ROOT is
 * trusted, and a derived root counts only when it actually looks like a clone
 * (niffler.nimble or a var/bin directory). No trusted root means no .env is
 * loaded at all: the environment is then the only source, the safe answer.
 */
export function trustedRoot(): string {
  const explicit = process.env.NIF_ROOT;
  if (explicit) return resolvePath(explicit);
  const exe = resolvePath(process.argv[1] ?? "");
  if (!exe) return "";
  // argv[1] is the file (<root>/var/bin/<bin>): three dirnames reach the clone.
  const derived = path.dirname(path.dirname(path.dirname(exe)));
  return looksLikeClone(derived) ? derived : "";
}

/**
 * True when `p` IS the harness root's own .env — <root>/.env and nothing
 * else. Containment alone would not be enough: a conversation workspace and a
 * plugin checkout both live INSIDE the root, so a committed .env in one of
 * those checkouts is precisely the file that must not be honoured.
 */
export function withinHarnessRoot(p: string): boolean {
  const root = trustedRoot();
  if (!root) return false;
  return resolvePath(p) === path.join(root, ".env");
}

/**
 * Load KEY=VALUE lines from each .env file, first wins (existing env always
 * wins too).
 *
 * Only the harness root's own .env is honoured (see trustedRoot). A .env
 * sitting in an arbitrary working directory must never be read: the harness is
 * routinely launched from inside the repositories it is working on, and a
 * committed .env there would otherwise hand that repository
 * NIF_AUTO_APPROVE=1 (approval bypass) or a NIF_NATS_URL pointing at a bus it
 * controls. A refused file is reported on stderr, so a legitimate
 * misconfiguration stays diagnosable instead of disappearing silently.
 */
export function loadDotEnv(...paths: string[]): void {
  for (const file of paths) {
    if (!file) continue;
    let text: string;
    try {
      text = fs.readFileSync(file, "utf8");
    } catch {
      continue;
    }
    if (!withinHarnessRoot(file)) {
      process.stderr.write(
        "dotenv: IGNORING .env — only <root>/.env is trusted: " +
          file +
          " (a working directory is not a trust boundary)\n"
      );
      continue;
    }
    for (const rawLine of text.split("\n")) {
      const line = rawLine.trim();
      if (line === "" || line.startsWith("#")) continue;
      const eq = line.indexOf("=");
      if (eq <= 0) continue;
      const key = line.slice(0, eq).trim();
      let value = line.slice(eq + 1).trim();
      if (value.startsWith('"') && value.endsWith('"')) {
        value = value.slice(1, -1);
      }
      if (key !== "" && process.env[key] === undefined) {
        process.env[key] = value;
      }
    }
  }
}
