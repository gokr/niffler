<script lang="ts">
  // Reasoning block rendering, controlled by the global think level
  // (web twin of the TUI's ctrl+t): full shows the whole reasoning as gray
  // italic text, brief collapses it to one dim line per block, off hides
  // it entirely. Streamed reasoning is compacted like the TUI: edge
  // newlines trimmed and blank-line runs capped at ONE blank line, so
  // paragraph breaks between thinking blocks survive without runaway
  // gaps (collapsing runs to a single newline erased those gaps).
  import { thinkLevel, type ThinkLevel } from "../lib/prefs.svelte";
  import { t } from "../lib/i18n.svelte";

  let { text, streaming = false }: { text: string; streaming?: boolean } = $props();

  const level = $derived(thinkLevel());

  const compact = $derived.by(() => {
    const trimmed = (text ?? "").replace(/^[\n\r]+|[\n\r]+$/g, "");
    // cap blank-line runs at one blank line (\n\n): keeps paragraph
    // separation between thinking blocks visible, still bounds density
    return trimmed.replace(/(?:\r?\n){3,}/g, "\n\n");
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
