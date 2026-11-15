import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { NifflerHarness, readinessDirectTools, requiredManifestComponents,
  readinessProblems, transcriptShape } from "../adapters/niffler.mjs";

const root = "/private/bench-root";
const required = ["store", "bash", "llm"];
const catalogs = () => ({
  components: { root, components: {
    store: ["get"], bash: ["bash"], llm: ["chat"], systemprompt: ["systemprompt"],
  } },
  direct: { root, tools: readinessDirectTools.map((name) => ({ name,
    schema: { type: "object" } })) },
});

test("readiness accepts only the complete private eight-tool snapshot", () => {
  const { components, direct } = catalogs();
  assert.deepEqual(readinessProblems(components, direct, required, root), []);
  direct.tools = direct.tools.filter((t) => !["read", "edit", "write", "replace_across"].includes(t.name));
  assert.match(readinessProblems(components, direct, required, root).join(";"), /missing direct tools: read, edit, write, replace_across/);
});

test("readiness rejects foreign roots, missing prompt and bad/direct-hidden schemas", () => {
  const { components, direct } = catalogs();
  components.root = "/foreign";
  components.components.systemprompt = [];
  delete components.components.store;
  direct.tools[0].schema["x-harness"] = { onDemand: true };
  direct.tools[1].schema.type = "string";
  const failures = readinessProblems(components, direct, required, root).join(";");
  assert.match(failures, /catalog root mismatch/);
  assert.match(failures, /missing components: store/);
  assert.match(failures, /missing systemprompt/);
  assert.match(failures, /missing direct tools: bash, read/);
});

test("required manifest components use the shipped autostart contract", () => {
  const manifest = fs.readFileSync(new URL("../../manifest.yaml", import.meta.url), "utf8");
  const names = requiredManifestComponents(manifest);
  assert.ok(names.includes("store") && names.includes("llm") && names.includes("builder"));
  assert.throws(() => requiredManifestComponents("components: []"), /no component entries/);
  assert.throws(() => requiredManifestComponents("  - name: store\n    required: true\n    autostart: false\n"), /not autostarted/);
});

const toolCall = (name, args) => ({ function: { name, arguments: JSON.stringify(args) } });
const message = (role, rest) => ({ value: { role, ...rest } });

test("shape records pipelines, selectors, batching, defaults and result sizes separately", () => {
  const shape = transcriptShape([
    message("assistant", { tool_calls: [
      toolCall("read", { reads: [{ glob: "*.go", pattern: "Needle", context: 2 }], save_as: "span" }),
      toolCall("edit", { path: "f.go", edits: [{ old_string: "$span", new_string: "new", replace_all: false }], resolve_vars: true }),
    ] }),
    message("tool", { name: "read", content: "five!" }),
    message("tool", { name: "edit", content: "done" }),
    message("assistant", { tool_calls: [toolCall("read", { reads: [{ glob: "*.md" }] })] }),
    message("assistant", { content: "done" }),
  ]);
  assert.equal(shape.turns, 3);
  assert.equal(shape.toolCalls, 3);
  assert.equal(shape.multiCallMessages, 1);
  assert.equal(shape.multiCallCalls, 2);
  assert.equal(shape.pipelineCalls, 2);
  assert.equal(shape.pipelineMessages, 1);
  assert.equal(shape.saveAsCalls, 1);
  assert.equal(shape.resolveVarsCalls, 1);
  assert.deepEqual(shape.readSelectors, { calls: 2, items: 2, glob: 2, pattern: 1, inventory: 1 });
  assert.equal(shape.arguments.read.defaults, 1);
  assert.equal(shape.arguments.edit.defaults, 1);
  assert.deepEqual(shape.resultChars, { read: 5, edit: 4 });
  assert.deepEqual(shape.resultAnswers, { read: 1, edit: 1 });
});

test("malformed assistant arguments count as invalid, never as result calls", () => {
  const shape = transcriptShape([
    message("assistant", { tool_calls: [{ function: { name: "read", arguments: "[broken" } }] }),
    message("tool", { name: "read", content: "error" }),
  ]);
  assert.equal(shape.toolCalls, 1);
  assert.equal(shape.arguments.read.invalid, 1);
  assert.equal(shape.arguments.read.chars, 7);
  assert.deepEqual(transcriptShape([]).tools, {});
});

test("readiness waits for catalogs instead of accepting the initial four-tool race", async () => {
  const tmp = fs.mkdtempSync(path.join(process.cwd(), "var", "readiness-test-"));
  const h = new NifflerHarness({ benchRoot: tmp, runRoot: tmp, model: "fixture" });
  fs.mkdirSync(h.root, { recursive: true });
  fs.writeFileSync(path.join(h.root, "manifest.yaml"), "components:\n  - name: store\n    autostart: true\n    required: true\n");
  let attempts = 0;
  h.readinessCatalog = async (op) => {
    const { components, direct } = catalogs();
    components.root = direct.root = h.root;
    for (const name of ["edit", "grep", "systemprompt"]) components.components[name] ??= [name];
    if (op === "components") return components;
    attempts++;
    if (attempts === 1) direct.tools = direct.tools.slice(0, 4);
    return direct;
  };
  try {
    const ready = await h.waitUntilReady(2000);
    assert.equal(attempts, 2);
    assert.deepEqual(ready.directTools, [...readinessDirectTools].sort());
    h.readinessCatalog = async () => { throw new Error("fixture offline"); };
    await assert.rejects(h.waitUntilReady(20), /readiness deadline.*fixture offline/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

// The sandbox maps are env text handed to a DIFFERENT process tree, so a
// wrong spelling is silent at write time and fatal at run time: bash matches
// cwd against the map, finds nothing and answers `exit 125` to every command
// (deepswe pilot10: 83/83 calls). These pin the spelling contract.
test("sandbox map names each cell's session workspace, not the prepared path", () => {
  const tmp = fs.mkdtempSync(path.resolve("var/niffler-sandboxmap-test-"));
  try {
    const h = new NifflerHarness({ benchRoot: tmp, runRoot: path.join(tmp, "run"),
      baseUrl: "http://x", apiKey: "k", model: "m" });
    const repo = path.join(tmp, "var", "bench", "results", "R", "niffler__m__t01", "repo");
    h.addWorkspace(repo, "img-a");
    // The entry must use workspaceFor's spelling (under the harness root),
    // because that is the cwd the session is actually given.
    const map = h.sandboxMap();
    assert.equal(map, `${h.workspaceFor(repo)}=img-a`);
    assert.ok(!map.includes(repo), "the prepared path must not be the map key");
    // One line per cell, same image namespace as the container name.
    h.addWorkspace(repo, "img-a"); // idempotent: a repeated round must not duplicate
    assert.equal(h.sandboxMap().split("\n").length, 1);
    assert.match(h.containerMap(), /^.+=nif-task-[0-9a-f]{24}$/);
    // No registered cells: fall through to whatever the caller exported, so a
    // non-container run keeps an operator-provided map.
    const bare = new NifflerHarness({ benchRoot: tmp, runRoot: path.join(tmp, "run2"),
      baseUrl: "http://x", apiKey: "k", model: "m" });
    const prev = process.env.NIF_BASH_SANDBOX_MAP;
    process.env.NIF_BASH_SANDBOX_MAP = "/work/task-a=img";
    try {
      assert.equal(bare.sandboxMap(), "/work/task-a=img");
    } finally {
      if (prev === undefined) delete process.env.NIF_BASH_SANDBOX_MAP;
      else process.env.NIF_BASH_SANDBOX_MAP = prev;
    }
    // A path outside the mirrored subtree cannot be spelled under the harness
    // root; it must fall back to its own path rather than become "null".
    const outside = new NifflerHarness({ benchRoot: tmp, runRoot: path.join(tmp, "run3"),
      baseUrl: "http://x", apiKey: "k", model: "m" });
    outside.addWorkspace("/elsewhere/repo", "img-b");
    assert.equal(outside.sandboxMap(), "/elsewhere/repo=img-b");
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
