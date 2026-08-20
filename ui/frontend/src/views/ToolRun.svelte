<script lang="ts">
  // One card for a run of consecutive tool calls. Collapsed it shows the
  // call count and one chip per call; expanding reveals a row per call,
  // each expandable in turn to show its args and result (two levels).
  interface Item {
    tool?: string;
    args?: any;
    result?: any;
    error?: string;
    content?: string;
    pending?: boolean;
  }

  let { items } = $props<{ items: Item[] }>();

  const anyPending = $derived(items.some((m) => m.pending));
  const failed = $derived(items.some((m) => m.error));

  let openIdx = $state<number | null>(null);

  function status(m: Item): "ok" | "err" | "run" {
    if (m.pending) return "run";
    if (m.error) return "err";
    return "ok";
  }

  function glyph(m: Item): string {
    if (m.pending) return "⚙";
    if (m.error) return "⚠";
    return "✓";
  }

  // A one-line preview of the call: the command/path for the common tools,
  // otherwise a truncated JSON dump.
  function preview(m: Item): string {
    if (m.error) return m.error;
    const a = m.args;
    if (typeof a?.command === "string") return a.command;
    if (typeof a?.path === "string") return a.path;
    if (typeof a?.filePath === "string") return a.filePath;
    const j = JSON.stringify(a ?? m.result ?? m.content ?? "");
    return j.length > 160 ? j.slice(0, 160) + "…" : j;
  }

  function toggle(i: number) {
    openIdx = openIdx === i ? null : i;
  }
</script>

<details class="tool-run" open={anyPending}>
  <summary>
    <span class="tool-run-chevron">▸</span>
    {#if items.length === 1}
      <span class="tool-run-summary">
        {glyph(items[0])} {items[0].tool ?? "tool"}
        {#if anyPending}<span class="animate-pulse text-accent">running…</span>{/if}
      </span>
    {:else}
      <span class="tool-run-summary">
        {failed ? "⚠" : anyPending ? "⚙" : "✓"} {items.length} tool calls
      </span>
    {/if}
    {#each items.slice(0, 8) as m, i (i)}
      <span class="tool-chip" class:errored={m.error} class:running={m.pending}>
        {m.tool ?? "tool"}{m.pending ? "…" : ""}
      </span>
    {/each}
    {#if items.length > 8}
      <span class="tool-chip">+{items.length - 8}</span>
    {/if}
  </summary>
  {#each items as m, i (i)}
    <details class="tool-run-item" open={openIdx === i || m.pending}>
      <summary onclick={(e) => {
        e.preventDefault();
        toggle(i);
      }}>
        <span class="tool-run-glyph" class:ok={status(m) === "ok"} class:err={status(m) === "err"} class:run={status(m) === "run"}>
          {glyph(m)}
        </span>
        <span class="tool-run-name">{m.tool ?? "tool"}</span>
        {#if m.pending}<span class="text-[11px] text-accent animate-pulse">running…</span>{/if}
        <span class="tool-run-preview">{preview(m)}</span>
      </summary>
      <div class="tool-run-detail">
        {#if m.args && Object.keys(m.args).length > 0}
          <span class="tool-run-label">args</span>
          <pre>{JSON.stringify(m.args, null, 2)}</pre>
        {/if}
        {#if m.error}
          <span class="tool-run-label">error</span>
          <pre class="text-danger">{m.error}</pre>
        {:else if m.result !== undefined}
          <span class="tool-run-label">result</span>
          <pre>{JSON.stringify(m.result, null, 2)}</pre>
        {:else if m.content}
          <span class="tool-run-label">result</span>
          <pre>{m.content}</pre>
        {/if}
      </div>
    </details>
  {/each}
</details>
