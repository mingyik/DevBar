import type { PageShell } from "../editor/page-shell";
import { post } from "../bridge/client";
import { strings } from "../strings";

export type PreviewExportTarget = Pick<
  PageShell,
  "kind" | "preview" | "content" | "info" | "updateInfo"
>;
export function imageDimensions(
  width: number,
  height: number,
  scale = 2,
): { width: number; height: number } | null {
  const w = Math.ceil(width * scale),
    h = Math.ceil(height * scale);
  return w > 0 && h > 0 && w <= 16384 && h <= 16384 && w * h <= 64000000
    ? { width: w, height: h }
    : null;
}
export function collectCSS(): string {
  const parts: string[] = [];
  const sheets = document.styleSheets;
  for (let sheetIndex = 0; sheetIndex < sheets.length; sheetIndex += 1) {
    try {
      const rules = sheets[sheetIndex]?.cssRules;
      if (!rules) continue;
      for (let ruleIndex = 0; ruleIndex < rules.length; ruleIndex += 1) {
        const text = rules[ruleIndex]?.cssText;
        if (text) parts.push(text);
      }
    } catch {
      // Stylesheets from another origin are not readable. DevBar's own sheets are.
    }
  }
  return parts.join("\n");
}
export async function exportPreview(
  shell: PreviewExportTarget,
  content?: Node,
): Promise<void> {
  const root = document.createElement("div");
  root.className = "snapshot-root snapshot-measure";
  if (shell.kind === "doc") {
    root.classList.add("prose");
    root.classList.toggle(
      "large",
      document.documentElement.dataset.size === "large",
    );
  }
  // A4 width at 96 CSS dpi; PNG is still rendered at 2x.
  root.style.width = `${shell.kind === "doc" ? 794 : shell.content.clientWidth}px`;
  root.append(
    ...(content
      ? [content.cloneNode(true)]
      : Array.from(shell.preview.childNodes, (node) => node.cloneNode(true))),
  );
  for (const button of Array.from(root.querySelectorAll(".diagram-copy")))
    button.remove();
  document.body.append(root);
  try {
    await document.fonts.ready;
    const width = root.getBoundingClientRect().width,
      height = root.scrollHeight;
    if (!imageDimensions(width, height)) {
      shell.updateInfo(strings.imageTooLarge);
      return;
    }
    root.classList.remove("snapshot-measure");
    const result = await post("preview.exportImage", {
      page: shell.kind,
      width,
      height,
      html: root.outerHTML,
      css: collectCSS(),
      theme:
        document.documentElement.dataset.theme === "dark" ? "dark" : "light",
      background: getComputedStyle(document.documentElement)
        .getPropertyValue("--snapshot-background")
        .trim(),
    });
    if (result.status === "saved" && typeof result.path === "string") {
      shell.updateInfo();
    } else
      shell.updateInfo(
        result.status === "tooLarge"
          ? strings.imageTooLarge
          : strings.imageFailed,
      );
  } finally {
    root.remove();
  }
}
