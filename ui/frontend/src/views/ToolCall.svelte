<script lang="ts">
  let { m } = $props<{
    m: {
      tool?: string;
      args?: any;
      result?: any;
      error?: string;
      content?: string;
      pending?: boolean;
    };
  }>();
</script>

<details class="tool-card" open={m.pending === true}>
  <summary>
    {m.pending ? "⚙" : "✓"} {m.tool ?? "tool"}
    {#if m.pending}<span class="ml-2 text-ink-400 animate-pulse">running…</span>{/if}
  </summary>
  <div class="mt-2 flex flex-col gap-2">
    {#if m.args && Object.keys(m.args).length > 0}
      <pre>{JSON.stringify(m.args, null, 2)}</pre>
    {/if}
    {#if m.error}
      <pre class="text-red-400">{m.error}</pre>
    {:else if m.result !== undefined}
      <pre>{JSON.stringify(m.result, null, 2)}</pre>
    {:else if m.content}
      <pre>{m.content}</pre>
    {/if}
  </div>
</details>
