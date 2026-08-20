// .env loading — mirror of sdk/dotenv.nim and sdk/go/dotenv.go.
// KEY=VALUE lines (plus # comments, optional quotes); existing shell env
// always wins.

import * as fs from "fs";

export function loadDotEnv(...paths: string[]): void {
  for (const path of paths) {
    if (!path) continue;
    let text: string;
    try {
      text = fs.readFileSync(path, "utf8");
    } catch {
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
