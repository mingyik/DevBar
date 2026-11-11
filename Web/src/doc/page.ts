import { Compartment } from "@codemirror/state";
import { markdown } from "@codemirror/lang-markdown";
import { languages } from "@codemirror/language-data";
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
const supported = new Set([
  "JSON",
  "JavaScript",
  "TypeScript",
  "Swift",
  "Python",
  "Go",
  "Java",
  "Kotlin",
  "SQL",
  "Shell",
  "YAML",
  "HTML",
  "CSS",
  "Diff",
  "Markdown",
]);
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
    shell.addExtensions(
      this.language.of(
        markdown({
          codeLanguages: languages.filter((language) =>
            supported.has(language.name),
          ),
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
    this.modeButton.textContent = mode === "mermaid" ? "Mermaid" : "Markdown";
    this.modeButton.setAttribute("aria-label", strings.docMode);
    this.shell.view.dispatch({
      effects: this.language.reconfigure(
        mode === "markdown"
          ? markdown({
              codeLanguages: languages.filter((language) =>
                supported.has(language.name),
              ),
            })
          : [],
      ),
    });
  }
  import(text: string, fileName: string | null, mode?: DocMode) {
    this.shell.showPreview(false);
    this.shell.replace(text, "devbar.import");
    this.locked = !!mode;
    this.setMode(mode ?? detectDocMode(text));
    this.shell.fileName = fileName;
    this.shell.updateInfo();
    this.toggle.textContent = strings.preview;
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
    this.pending = renderDocument(this.shell.preview, this.shell.text, {
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
      docMode: this.mode,
      modeLocked: this.locked,
    };
  }
  async restore(state: Partial<DocumentState>) {
    this.shell.restore(state);
    this.locked = state.modeLocked === true && this.shell.text !== "";
    this.setMode(
      this.locked && state.docMode
        ? state.docMode
        : detectDocMode(this.shell.text),
    );
    if (state.view === "preview") await this.togglePreview();
  }
}
