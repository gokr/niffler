import { svelte } from "@sveltejs/vite-plugin-svelte";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";
import path from "path";
import { execSync } from "child_process";

// Build-time commit hash: BUILD_COMMIT env wins, else the live git HEAD.
// Embedded into the bundle so the UI can show which commit it was built from.
function commitHash() {
  if (process.env.BUILD_COMMIT) return process.env.BUILD_COMMIT;
  try {
    return execSync("git rev-parse --short HEAD", { cwd: process.cwd() })
      .toString()
      .trim();
  } catch {
    return "unknown";
  }
}

export default defineConfig({
  plugins: [tailwindcss(), svelte()],
  define: {
    __BUILD_COMMIT__: JSON.stringify(commitHash()),
  },
  resolve: {
    alias: {
      $lib: path.join(process.cwd(), "src/lib"),
    },
  },
});
