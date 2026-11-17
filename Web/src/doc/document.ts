import { installReadOnlyScrollbars } from "../styles/readonly-scroll";
import { createMarkdownPreview } from "./preview";
import { renderMermaidElements } from "./mermaid";
import type { Theme } from "./highlight";
import type { DocMode } from "./mode";
const revisions = new WeakMap<HTMLElement, number>();
const previews = new WeakMap<
  Document,
  ReturnType<typeof createMarkdownPreview>
>();
/** Web-only entry point. Mode/lock state and clipboard actions belong to the host. */
export async function renderDocument(
  root: HTMLElement,
  text: string,
  options: { theme: Theme; mode: DocMode },
): Promise<void> {
  installReadOnlyScrollbars(root.ownerDocument);
  const revision = (revisions.get(root) ?? 0) + 1;
  revisions.set(root, revision);
  const staged = root.ownerDocument.createElement("div");
  if (options.mode === "mermaid") {
    const placeholder = root.ownerDocument.createElement("div");
    placeholder.className = "mmd";
    placeholder.dataset.src = text;
    staged.replaceChildren(placeholder);
  } else {
    let preview = previews.get(root.ownerDocument);
    if (!preview) {
      preview = createMarkdownPreview(root.ownerDocument);
      previews.set(root.ownerDocument, preview);
    }
    // Keep the current preview until highlighting and diagrams are ready.
    staged.innerHTML = await preview.renderAsync(text, options.theme);
  }
  if (revisions.get(root) !== revision) return;
  const rootStyle = root.ownerDocument.defaultView?.getComputedStyle(root);
  const parsePixels = (value: string | undefined) => {
    const parsed = Number.parseFloat(value ?? "");
    return Number.isFinite(parsed) ? parsed : 0;
  };
  const availableDiagramWidth = Math.max(
    0,
    root.clientWidth -
      parsePixels(rootStyle?.paddingLeft) -
      parsePixels(rootStyle?.paddingRight) -
      16,
  );
  await renderMermaidElements(staged, options.theme, availableDiagramWidth);
  if (revisions.get(root) === revision)
    root.replaceChildren(...Array.from(staged.childNodes));
}

export function releaseDocumentPreview(doc: Document): void {
  previews.get(doc)?.releaseMemory();
}
