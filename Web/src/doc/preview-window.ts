import { decodeEnvelope, type JSONValue } from "../bridge/envelope";
import { post } from "../bridge/client";
import { element, iconButton, setIcon } from "../editor/page-shell";
import { exportPreview } from "../preview/export";
import { strings } from "../strings";
import { renderDocument } from "./document";
import { bindPreviewLinks } from "./preview";
import type { DocMode } from "./mode";
import { svgToPngBase64 } from "./mermaid";

/** Standalone renderer for the split-view window; no editor or state files. */
export function startDocumentPreview(): void {
  for (const screen of Array.from(
    document.querySelectorAll<HTMLElement>(".screen"),
  ))
    screen.hidden = true;
  const root = element("div", "doc-preview-window");
  const content = element("div", "preview prose doc-preview-content");
  const status = element("div", "doc-preview-status");
  status.hidden = true;
  const exportButton = iconButton("exportImage", () => {
    void runExport();
  });
  exportButton.classList.add("doc-preview-export");
  root.append(content, status, exportButton);
  document.body.append(root);
  let theme: "light" | "dark" =
    document.documentElement.dataset.theme === "dark" ? "dark" : "light";
  let text = "";
  let mode: DocMode = "markdown";
  let pending: Promise<void> = Promise.resolve();
  let generation = 0;
  bindPreviewLinks(content, (url) => {
    void post("link.open", { url });
  });
  content.addEventListener("click", (event) => {
    const button = (event.target as Element).closest<HTMLButtonElement>(
      ".diagram-copy",
    );
    const svg = button?.parentElement?.querySelector("svg");
    if (!button || !svg) return;
    button.disabled = true;
    void svgToPngBase64(svg.outerHTML, theme)
      .then(async (pngBase64) => {
        await post("clipboard.writeImage", { pngBase64 });
        setIcon(button, "copied");
        setTimeout(() => setIcon(button, "copy"), 1000);
      })
      .catch(() => showStatus(strings.imageFailed))
      .finally(() => {
        button.disabled = false;
      });
  });
  function showStatus(message: string) {
    status.textContent = message;
    status.hidden = !message;
  }
  function render() {
    const current = ++generation;
    pending = pending
      .catch(() => {})
      .then(async () => {
        if (current !== generation) return;
        await renderDocument(content, text, { theme, mode });
        if (current !== generation) return;
        for (const diagram of Array.from(
          content.querySelectorAll<HTMLElement>(".mmd"),
        )) {
          if (
            !diagram.querySelector("svg") ||
            diagram.querySelector(".diagram-copy")
          )
            continue;
          const button = iconButton("copy", () => {});
          button.classList.add("diagram-copy");
          diagram.append(button);
        }
      })
      .catch(() => showStatus(strings.previewFailed)) as Promise<void>;
  }
  async function runExport() {
    await pending.catch(() => {});
    await exportPreview({
      kind: "doc",
      preview: content,
      content,
      info: status,
      updateInfo: showStatus,
    });
  }
  const bridge = {
    async receive(raw: string): Promise<JSONValue> {
      const { type, payload } = decodeEnvelope(raw);
      switch (type) {
        case "theme.set": {
          theme = payload.theme === "dark" ? "dark" : "light";
          document.documentElement.dataset.theme = theme;
          render();
          break;
        }
        case "panel.size":
          document.documentElement.dataset.size =
            payload.size === "large" ? "large" : "normal";
          render();
          break;
        case "doc.preview":
          text = typeof payload.text === "string" ? payload.text : "";
          mode = payload.mode === "mermaid" ? "mermaid" : "markdown";
          content.classList.toggle("pure-mermaid", mode === "mermaid");
          render();
          break;
        case "screen.show":
          root.hidden = false;
          render();
          break;
        case "screen.hide":
          root.hidden = true;
          break;
        case "state.flush":
          return { ok: true };
      }
      return {};
    },
  };
  // The main app declares a richer bridge on Window; the preview page can
  // publish only receive() without disturbing that global declaration.
  Object.assign(window, { __devbar: bridge });
  void post("app.ready", { version: "1" }).then((reply) => {
    theme = reply.theme === "dark" ? "dark" : "light";
    document.documentElement.dataset.theme = theme;
    if (typeof reply.panelSize === "string")
      document.documentElement.dataset.size =
        reply.panelSize === "large" ? "large" : "normal";
  });
}
