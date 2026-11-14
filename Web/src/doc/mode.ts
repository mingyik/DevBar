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
  const key = [...mermaidKeywords]
    .sort((a, b) => b.length - a.length)
    .find(
      (key) =>
        first.startsWith(key) && /^(?:$|\s|[-:])/.test(first.slice(key.length)),
    );
  if (!key) return "markdown";
  const tail = first.slice(key.length);
  if (
    !/^(?:-(?:v\d+|beta))?(?:\s+(?:TB|TD|BT|RL|LR|showData))*(?:\s+(?:title|accTitle|accDescr)\b.*|\s*:.*)?\s*$/.test(
      tail,
    )
  )
    return "markdown";
  const next = lines
    .slice(i + 1)
    .map((line) => line.trim())
    .find((line) => line && !line.startsWith("%%"));
  if (
    next &&
    (/^(?:[#>]|[-*]\s|\d+\.\s|\|)/.test(next) ||
      (next.length >= 20 && /[.?!。？！]$/.test(next)))
  )
    return "markdown";
  return "mermaid";
}

export type DisplayMode = "source" | "preview" | "split";
export function nextDisplayMode(mode: DisplayMode): DisplayMode {
  if (mode === "source") return "preview";
  if (mode === "preview") return "split";
  return "source";
}
export function isDirty(text: string, savedText: string): boolean {
  return text !== savedText;
}
