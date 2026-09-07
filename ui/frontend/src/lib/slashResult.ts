/** An explicitly invoked slash tool may request that its rendered content
 * enter the conversation. It is always user-role text, never system/assistant
 * history. Ordinary tool calls and passive events do not use this convention. */
export function slashUserMessage(result: unknown): string | undefined {
  if (!result || typeof result !== "object") return undefined;
  const value = (result as Record<string, unknown>).userMessage;
  return typeof value === "string" && value.trim() ? value : undefined;
}
