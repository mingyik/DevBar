import { isolateHistory } from "@codemirror/commands";
import { documentHistory, documentMetadata, metadataField } from "./state";
import { Compartment } from "@codemirror/state";
import { markdown } from "@codemirror/lang-markdown";
import { documentLanguages } from "./languages";
import { PageShell, iconButton, pill } from "../editor/page-shell";
import type { PageState } from "../editor/page-shell";
import { post } from "../bridge/client";
import { strings } from "../strings";
import { exportPreview } from "../preview/export";
import { renderDocument } from "./document";
import { bindPreviewLinks } from "./preview";
import { detectDocMode, type DocMode } from "./mode";
import { svgToPngBase64 } from "./mermaid";

export type DocumentState = PageState & {
  docMode?: DocMode;
  modeLocked?: boolean;
};
export class DocPage {
  private language = new Compartment();
  private mode: DocMode = "markdown";
  private locked = false;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private renderKey = "";
  private pending: Promise<void> = Promise.resolve();
  private toggle: HTMLButtonElement;
  private modeButton: HTMLButtonElement;
  readonly shell: PageShell;
  constructor(shell: PageShell) {
    this.shell = shell;
    shell.addExtensions(documentHistory);
    shell.addExtensions(
      this.language.of(
        markdown({
          codeLanguages: documentLanguages,
        }),
      ),
    );
    this.toggle = pill(strings.preview, () => {
      void this.togglePreview();
    });
    this.modeButton = pill("Markdown", () => {
      this.locked = true;
      this.setMode(this.mode === "markdown" ? "mermaid" : "markdown");
      shell.onStateChange();
      if (shell.mode === "preview") void this.render();
    });
    shell.actions.append(this.toggle, this.modeButton);
    shell.fixed.append(
      iconButton("exportImage", () => {
        void this.export();
      }),
      iconButton("clear", () => {
        shell.showPreview(false);
        shell.replace("", "devbar.clear");
        this.toggle.textContent = strings.preview;
      }),
    );
    shell.preview.classList.add("prose");
    bindPreviewLinks(shell.preview, (url) => {
      void post("link.open", { url });
    });
    shell.preview.addEventListener("click", (event) => {
      const button = (event.target as Element).closest<HTMLButtonElement>(
        ".diagram-copy",
      );
      const svg = button?.parentElement?.querySelector("svg");
      if (!button || !svg) return;
      button.disabled = true;
      void svgToPngBase64(svg.outerHTML, this.theme())
        .then(async (pngBase64) => {
          await post("clipboard.writeImage", { pngBase64 });
          button.textContent = strings.copied;
        })
        .catch(() => {
          shell.updateInfo(strings.imageFailed);
        })
        .finally(() => {
          button.disabled = false;
        });
    });
    shell.onChange = () => {
      const metadata = shell.view.state.field(metadataField);
      this.locked = metadata.locked;
      shell.fileName = metadata.fileName;
      this.setMode(metadata.mode);
      this.renderKey = "";
      clearTimeout(this.timer);
      if (shell.text === "") {
        this.locked = false;
        this.setMode("markdown");
      }
      this.timer = setTimeout(() => {
        if (!this.locked) this.setMode(detectDocMode(shell.text));
        if (shell.mode === "preview") void this.render();
      }, 400);
    };
  }
  private theme() {
    return document.documentElement.dataset.theme === "dark"
      ? ("dark" as const)
      : ("light" as const);
  }
  private setMode(mode: DocMode) {
    this.mode = mode;
    const metadata = this.shell.view.state.field(metadataField);
    this.shell.view.dispatch({
      effects: documentMetadata.of({
        ...metadata,
        mode,
        locked: this.locked,
        fileName: this.shell.fileName,
      }),
    });
    this.modeButton.textContent = mode === "mermaid" ? "Mermaid" : "Markdown";
    this.modeButton.setAttribute("aria-label", strings.docMode);
    this.shell.view.dispatch({
      effects: this.language.reconfigure(
        mode === "markdown"
          ? markdown({
              codeLanguages: documentLanguages,
            })
          : [],
      ),
    });
  }
  import(text: string, fileName: string | null, mode?: DocMode) {
    this.shell.showPreview(false);
    this.shell.view.dispatch({
      changes: { from: 0, to: this.shell.view.state.doc.length, insert: text },
      effects: documentMetadata.of({
        mode: mode ?? detectDocMode(text),
        locked: !!mode,
        fileName,
        rawText: text,
      }),
      annotations: isolateHistory.of("full"),
      userEvent: "devbar.import",
    });
    this.locked = !!mode;
    this.setMode(mode ?? detectDocMode(text));
    this.shell.fileName = fileName;
    this.shell.updateInfo();
    this.toggle.textContent = strings.preview;
  }
  private text() {
    const raw = this.shell.view.state.field(metadataField).rawText;
    return raw !== undefined &&
      raw.replace(/\r\n?|\n/g, "\n") === this.shell.text
      ? raw
      : this.shell.text;
  }
  async togglePreview() {
    const preview = this.shell.mode !== "preview";
    this.shell.showPreview(preview);
    this.toggle.textContent = preview ? strings.edit : strings.preview;
    this.shell.onStateChange();
    if (preview) await this.render();
  }
  async render() {
    if (!this.locked) this.setMode(detectDocMode(this.shell.text));
    this.shell.preview.classList.toggle(
      "large",
      document.documentElement.dataset.size === "large",
    );
    const key = `${this.theme()}:${this.mode}:${this.shell.text}`;
    if (key === this.renderKey) return this.pending;
    this.renderKey = key;
    this.pending = renderDocument(this.shell.preview, this.text(), {
      theme: this.theme(),
      mode: this.mode,
    })
      .then(() => {
        for (const diagram of Array.from(
          this.shell.preview.querySelectorAll<HTMLElement>(".mmd"),
        )) {
          if (
            !diagram.querySelector("svg") ||
            diagram.querySelector(".diagram-copy")
          )
            continue;
          const button = document.createElement("button");
          button.className = "diagram-copy";
          button.textContent = strings.copyPNG;
          diagram.append(button);
        }
      })
      .catch(() => {
        this.renderKey = "";
        this.shell.updateInfo(strings.previewFailed);
      });
    return this.pending;
  }
  refresh() {
    if (this.shell.mode === "preview") void this.render();
  }
  async export() {
    if (this.shell.mode !== "preview") await this.togglePreview();
    else await this.render();
    await this.pending;
    await exportPreview(this.shell);
  }
  state(): DocumentState {
    return {
      ...this.shell.state(),
      text: this.text(),
      docMode: this.mode,
      modeLocked: this.locked,
    };
  }
  async restore(state: Partial<DocumentState>) {
    this.shell.restore(state);
    this.shell.view.dispatch({
      effects: documentMetadata.of({
        mode: state.docMode ?? "markdown",
        locked: state.modeLocked === true && this.shell.text !== "",
        fileName: state.fileName ?? null,
        rawText: state.text,
      }),
    });
    this.locked = state.modeLocked === true && this.shell.text !== "";
    this.setMode(
      this.locked && state.docMode
        ? state.docMode
        : detectDocMode(this.shell.text),
    );
    if (state.view === "preview") await this.togglePreview();
  }
}
