import { marked } from "marked";

marked.setOptions({ async: false, gfm: true, breaks: true });

export function renderMarkdown(text: string): string {
  // Local harness: trusted model output, raw HTML allowed for now.
  return marked.parse(text) as string;
}
