<script lang="ts">
  // Reasoning block rendering, controlled by the global think level
  // (web twin of the TUI's ctrl+t): full shows the whole reasoning as gray
  // italic text, brief collapses it to one dim line per block, off hides
  // it entirely. Streamed reasoning is compacted like the TUI: edge
  // newlines trimmed and interior blank-line runs collapsed to a single
  // newline, so paragraph flow stays dense.
  import { thinkLevel, type ThinkLevel } from "../lib/prefs.svelte";
  import { t } from "../lib/i18n.svelte";

  let { text, streaming = false }: { text: string; streaming?: boolean } = $props();

  const level = $derived(thinkLevel());

  const compact = $derived.by(() => {
    const trimmed = (text ?? "").replace(/^[\n\r]+|[\n\r]+$/g, "");
    return trimmed.replace(/(?:\r?\n){2,}/g, "\n");
  });

  const briefText = $derived(t("chat.thinkingCollapsed"));
</script>

{#if level !== "off" && compact !== ""}
  {#if level === "brief"}
    <div class="msg-reasoning msg-reasoning-brief" title={compact}>
      {briefText}
    </div>
  {:else}
    <div class="msg-reasoning" class:streaming>{compact}</div>
  {/if}
{/if}
