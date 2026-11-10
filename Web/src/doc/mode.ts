import { mermaidKeywords } from "./mermaid-keywords";
export type DocMode = "markdown" | "mermaid";
export function detectDocMode(text: string): DocMode {
  const lines = text.split(/\r?\n/);
  if (lines.some((line) => /^\s*(?:```|~~~)/.test(line))) return "markdown";
  let i = 0;
  while (i < lines.length && !lines[i].trim()) i++;
  if (lines[i]?.trim() === "---") {
    i++;
    while (i < lines.length && lines[i].trim() !== "---") i++;
    if (i === lines.length) return "markdown";
    i++;
  }
  while (
    i < lines.length &&
    (!lines[i].trim() || lines[i].trimStart().startsWith("%%"))
  )
    i++;
  const first = lines[i]?.trimStart() ?? "";
  return mermaidKeywords.some(
    (key) =>
      first.startsWith(key) && /^(?:$|\s|[-:])/.test(first.slice(key.length)),
  )
    ? "mermaid"
    : "markdown";
}
