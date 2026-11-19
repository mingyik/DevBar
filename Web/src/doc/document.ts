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
  options: {
    theme: Theme;
    mode: DocMode;
    loadImage?: (address: string) => Promise<string | undefined>;
  },
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
  if (revisions.get(root) !== revision) return;
  root.replaceChildren(...Array.from(staged.childNodes));
  if (options.loadImage) {
    const pending = Array.from(
      root.querySelectorAll<HTMLElement>("[data-image-address]"),
    );
    for (
      let start = 0;
      start < pending.length && revisions.get(root) === revision;
      start += 4
    ) {
      await Promise.all(
        pending.slice(start, start + 4).map(async (placeholder) => {
          const source = await options
            .loadImage?.(placeholder.dataset.imageAddress ?? "")
            .catch(() => undefined);
          if (!source?.startsWith("data:image/")) return;
          const image = root.ownerDocument.createElement("img");
          image.alt = placeholder.dataset.imageAlt ?? "";
          image.src = source;
          placeholder.replaceWith(image);
        }),
      );
    }
  }
}

export function releaseDocumentPreview(doc: Document): void {
  previews.get(doc)?.releaseMemory();
}
