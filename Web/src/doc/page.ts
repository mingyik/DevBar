import { isolateHistory } from "@codemirror/commands";
import {
  documentHistory,
  documentMetadata,
  metadataField,
  sourceText,
} from "./state";
import { Compartment, Transaction } from "@codemirror/state";
import { syntaxHighlighting } from "@codemirror/language";
import { markdown } from "@codemirror/lang-markdown";
import { documentLanguages } from "./languages";
import { devbarMarkdownHighlightStyle } from "../theme/cm-highlight";
import {
  PageShell,
  element,
  iconButton,
  setButtonLabel,
  setIcon,
} from "../editor/page-shell";
import type { PageState } from "../editor/page-shell";
import { post } from "../bridge/client";
import { strings } from "../strings";
import { exportPreview } from "../preview/export";
import { releaseDocumentPreview, renderDocument } from "./document";
import { bindPreviewLinks } from "./preview";
import {
  detectDocMode,
  isDirty,
  nextDisplayMode,
  type DisplayMode,
  type DocMode,
} from "./mode";
import { releaseMermaidCache, svgToPngBase64 } from "./mermaid";
import { releaseHighlighter } from "./highlight";

export type DocumentState = PageState & {
  docMode?: DocMode;
  modeLocked?: boolean;
  display?: DisplayMode;
  savedText?: string;
  documentId?: string | null;
};
export class DocPage {
  private language = new Compartment();
  private mode: DocMode = "markdown";
  private languageMode: DocMode = "markdown";
  private locked = false;
  private display: DisplayMode = "source";
  private savedText = "";
  private documentID: string | null = null;
  private previewAllowed = true;
  private saveInProgress = false;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private previewTimer: ReturnType<typeof setTimeout> | undefined;
  private resizeTimer: ReturnType<typeof setTimeout> | undefined;
  private infoTimer: ReturnType<typeof setTimeout> | undefined;
  private renderKey = "";
  private released = false;
  private layoutReadyAt = 0;
  private scrollSource: "editor" | "preview" | null = null;
  private pending: Promise<void> = Promise.resolve();
  private toggle: HTMLButtonElement;
  private saveButton: HTMLButtonElement;
  private clearButton: HTMLButtonElement;
  private exportButton: HTMLButtonElement;
  private editingActions = element(
    "div",
    "doc-floating-actions doc-editing-actions",
  );
  private previewActions = element(
    "div",
    "doc-floating-actions doc-preview-actions",
  );
  readonly shell: PageShell;
  constructor(shell: PageShell) {
    this.shell = shell;
    shell.addExtensions(documentHistory);
    shell.addExtensions(syntaxHighlighting(devbarMarkdownHighlightStyle));
    shell.addExtensions(
      this.language.of(
        markdown({
          codeLanguages: documentLanguages,
        }),
      ),
    );
    this.toggle = iconButton("preview", () => {
      this.cycleDisplayMode();
    });
    shell.actions.append(this.toggle);
    this.saveButton = iconButton("save", () => {
      void this.save();
    });
    this.saveButton.classList.add("save-button");
    this.clearButton = iconButton("clear", () => {
      shell.replace("", "devbar.clear");
      this.locked = false;
      this.setMode("markdown");
    });
    this.exportButton = iconButton("exportImage", () => {
      void this.export();
    });
    shell.content.append(this.editingActions, this.previewActions);
    shell.preview.classList.add("prose");
    if (typeof ResizeObserver !== "undefined") {
      new ResizeObserver(() => {
        if (
          !this.released &&
          (this.display === "preview" || this.display === "split") &&
          !this.shell.root.hidden &&
          this.shell.preview.clientWidth > 0
        ) {
          clearTimeout(this.resizeTimer);
          this.resizeTimer = setTimeout(() => {
            if (
              !this.released &&
              (this.display === "preview" || this.display === "split") &&
              !this.shell.root.hidden &&
              this.shell.preview.clientWidth > 0
            )
              void this.render();
          }, 260);
        }
      }).observe(shell.preview);
    }
    bindPreviewLinks(shell.preview, (url) => {
      void post("link.open", { url });
    });
    shell.view.scrollDOM.addEventListener("scroll", () => {
      this.syncSplitScroll("editor");
    });
    shell.preview.addEventListener("scroll", () => {
      this.syncSplitScroll("preview");
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
          setIcon(button, "copied");
          setTimeout(() => setIcon(button, "copy"), 1000);
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
      this.mode = metadata.mode;
      queueMicrotask(() => this.setMode(this.mode));
      this.renderKey = "";
      clearTimeout(this.timer);
      if (shell.text === "") {
        this.locked = false;
        queueMicrotask(() => this.setMode("markdown"));
      }
      this.timer = setTimeout(() => {
        if (!this.locked) this.setMode(detectDocMode(shell.text));
        if (this.display === "preview" || this.display === "split")
          void this.render();
      }, 400);
      this.afterEdit();
    };
    this.updateControls();
  }
  private theme() {
    return document.documentElement.dataset.theme === "dark"
      ? ("dark" as const)
      : ("light" as const);
  }
  private syncSplitScroll(origin: "editor" | "preview") {
    if (this.display !== "split") return;
    if (this.scrollSource && this.scrollSource !== origin) return;
    const from =
      origin === "editor" ? this.shell.view.scrollDOM : this.shell.preview;
    const to =
      origin === "editor" ? this.shell.preview : this.shell.view.scrollDOM;
    const fromMax = from.scrollHeight - from.clientHeight;
    const toMax = to.scrollHeight - to.clientHeight;
    if (fromMax <= 0 || toMax <= 0) return;
    this.scrollSource = origin;
    to.scrollTop = Math.round((from.scrollTop / fromMax) * toMax);
    requestAnimationFrame(() => {
      if (this.scrollSource === origin) this.scrollSource = null;
    });
  }
  private setMode(mode: DocMode) {
    this.mode = mode;
    const metadata = this.shell.view.state.field(metadataField);
    this.shell.view.dispatch({
      annotations: Transaction.addToHistory.of(false),
      effects: documentMetadata.of({
        ...metadata,
        mode,
        locked: this.locked,
        fileName: this.shell.fileName,
      }),
    });
    if (this.languageMode === mode) return;
    this.languageMode = mode;
    this.shell.view.dispatch({
      effects: this.language.reconfigure(
        mode === "markdown"
          ? markdown({
              codeLanguages: documentLanguages,
            })
          : [],
      ),
    });
    if (this.display === "split") void this.render();
  }
  import(
    text: string,
    fileName: string | null,
    mode?: DocMode,
    documentId: string | null = null,
    savedText?: string,
    display?: DisplayMode,
    modeLocked?: boolean,
  ) {
    const extension = fileName?.split(".").pop()?.toLowerCase();
    this.previewAllowed =
      fileName === null ||
      ["md", "markdown", "mmd", "mermaid"].includes(extension ?? "");
    if (!this.previewAllowed) this.display = "source";
    else if (display) this.display = display;
    this.shell.view.dispatch({
      changes: { from: 0, to: this.shell.view.state.doc.length, insert: text },
      effects: documentMetadata.of({
        mode: mode ?? detectDocMode(text),
        locked: (modeLocked ?? !!mode) && text !== "",
        fileName,
        rawText: text,
      }),
      annotations: isolateHistory.of("full"),
      userEvent: "devbar.import",
    });
    this.locked = (modeLocked ?? !!mode) && text !== "";
    this.setMode(text === "" ? "markdown" : (mode ?? detectDocMode(text)));
    this.languageMode = this.mode;
    this.shell.view.dispatch({
      effects: this.language.reconfigure(
        this.mode === "markdown"
          ? markdown({ codeLanguages: documentLanguages })
          : [],
      ),
    });
    this.shell.fileName = fileName;
    this.savedText = savedText ?? text;
    this.documentID = documentId;
    this.updateControls();
    this.emitMode();
    this.shell.setDisplay(this.display);
    if (this.display === "preview" || this.display === "split")
      void this.render();
  }
  private updateControls() {
    this.shell.fileDirty = this.dirty();
    this.shell.updateInfo();
    const next = nextDisplayMode(this.display);
    setIcon(
      this.toggle,
      next === "preview" ? "preview" : next === "split" ? "split" : "edit",
    );
    setButtonLabel(
      this.toggle,
      next === "preview"
        ? strings.modePreview
        : next === "split"
          ? strings.modeSplit
          : strings.modeEdit,
    );
    this.toggle.hidden = true; // Mode control lives in the native title bar.
    if (this.display === "source") {
      this.editingActions.append(this.saveButton, this.clearButton);
    } else {
      this.previewActions.append(this.saveButton, this.exportButton);
      this.editingActions.append(this.clearButton);
    }
    this.editingActions.hidden = this.display === "preview";
    this.previewActions.hidden = this.display === "source";
    this.clearButton.hidden = this.display === "preview";
    this.exportButton.hidden =
      this.display === "source" || !this.previewAllowed;
    setButtonLabel(this.clearButton, strings.clear);
    setButtonLabel(this.exportButton, strings.exportImage);
    const dirty = this.dirty();
    this.saveButton.disabled = !dirty || this.saveInProgress;
    setButtonLabel(this.saveButton, strings.saveDocument);
  }
  private dirty() {
    return isDirty(this.text(), this.savedText);
  }
  private afterEdit() {
    this.updateControls();
    if (this.display === "split" || this.display === "preview")
      this.schedulePreview();
  }
  private text() {
    const raw = this.shell.view.state.field(metadataField).rawText;
    return sourceText(this.shell.text, raw);
  }
  private updateMetadata() {
    const metadata = this.shell.view.state.field(metadataField);
    this.shell.view.dispatch({
      annotations: Transaction.addToHistory.of(false),
      effects: documentMetadata.of({
        ...metadata,
        mode: this.mode,
        locked: this.locked,
        fileName: this.shell.fileName,
      }),
    });
  }
  setDisplayMode(mode: DisplayMode) {
    if (!this.previewAllowed && mode !== "source") return;
    if (mode === this.display) return;
    this.display = mode;
    this.layoutReadyAt = performance.now() + 260;
    this.shell.setDisplay(mode);
    this.updateControls();
    this.shell.onStateChange();
    this.emitMode();
    if (mode === "preview" || mode === "split") void this.render();
  }
  private cycleDisplayMode() {
    if (!this.previewAllowed) return;
    this.display = nextDisplayMode(this.display);
    this.layoutReadyAt = performance.now() + 260;
    this.shell.setDisplay(this.display);
    this.updateControls();
    this.shell.onStateChange();
    this.emitMode();
    if (this.display === "preview" || this.display === "split") {
      void this.render();
    }
  }
  private emitMode() {
    void post("doc.mode", {
      mode: this.display,
      text: this.text(),
      docMode: this.mode,
      documentId: this.documentID,
    });
  }
  private schedulePreview() {
    clearTimeout(this.previewTimer);
    this.previewTimer = setTimeout(() => {
      if (this.display === "preview" || this.display === "split")
        void this.render();
    }, 140);
  }
  documentMode() {
    return this.mode;
  }
  private showMessage(message: string) {
    this.shell.updateInfo(message);
    clearTimeout(this.infoTimer);
    this.infoTimer = setTimeout(() => {
      this.shell.updateInfo();
    }, 2600);
  }
  async save() {
    if (this.saveInProgress || !this.dirty()) return;
    const snapshot = this.text();
    this.saveInProgress = true;
    this.updateControls();
    try {
      const reply = await post("doc.save", {
        text: snapshot,
        documentId: this.documentID,
      });
      if (reply.status === "saved") {
        this.savedText = typeof reply.text === "string" ? reply.text : snapshot;
        if (typeof reply.documentId === "string")
          this.documentID = reply.documentId;
        if (typeof reply.fileName === "string")
          this.shell.fileName = reply.fileName;
        this.updateMetadata();
        this.shell.updateInfo();
      } else if (reply.status === "externalChanged") {
        this.showMessage(strings.saveExternalChanged);
      } else if (reply.status === "missing") {
        this.showMessage(strings.saveMissing);
      } else if (reply.status === "failed") {
        this.showMessage(strings.saveFailedDocument);
      }
    } catch {
      this.showMessage(strings.saveFailedDocument);
    } finally {
      this.saveInProgress = false;
      this.updateControls();
    }
  }
  togglePreview() {
    this.cycleDisplayMode();
  }
  async render() {
    this.released = false;
    while (performance.now() < this.layoutReadyAt) {
      await new Promise<void>((resolve) =>
        setTimeout(resolve, this.layoutReadyAt - performance.now()),
      );
      if (this.released) return;
    }
    if (!this.previewAllowed) return;
    if (!this.locked) this.setMode(detectDocMode(this.shell.text));
    this.shell.preview.classList.toggle(
      "large",
      document.documentElement.dataset.size === "large",
    );
    this.shell.preview.classList.toggle(
      "pure-mermaid",
      this.mode === "mermaid",
    );
    const key = `${this.theme()}:${this.mode}:${this.shell.preview.clientWidth}:${this.shell.text}`;
    if (
      key === this.renderKey &&
      (this.shell.preview.childElementCount > 0 || this.text() === "")
    )
      return this.pending;
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
          const button = iconButton("copy", () => {});
          button.classList.add("diagram-copy");
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
    if (
      (this.display === "preview" || this.display === "split") &&
      !this.shell.root.hidden
    )
      void this.render();
  }
  async releaseMemory(): Promise<void> {
    this.released = true;
    clearTimeout(this.timer);
    clearTimeout(this.previewTimer);
    clearTimeout(this.resizeTimer);
    clearTimeout(this.infoTimer);
    await this.pending;
    this.shell.preview.replaceChildren();
    clearTimeout(this.resizeTimer);
    this.renderKey = "";
    releaseDocumentPreview(this.shell.preview.ownerDocument);
    releaseMermaidCache();
    await releaseHighlighter();
  }
  async export() {
    if (!this.previewAllowed) return;
    const restoreSource = this.display === "source";
    if (restoreSource) this.shell.setDisplay("preview");
    await this.render();
    await this.pending;
    await exportPreview(this.shell);
    if (restoreSource) {
      this.shell.setDisplay("source");
    }
  }
  documentStatus(textOverride?: string | null) {
    return {
      dirty: isDirty(textOverride ?? this.text(), this.savedText),
      documentId: this.documentID,
      fileName: this.shell.fileName,
    };
  }
  documentText() {
    return this.text();
  }
  markSaved(text: string, fileName: string | null, documentId: string | null) {
    this.savedText = text;
    if (fileName !== null) this.shell.fileName = fileName;
    this.documentID = documentId;
    this.updateMetadata();
    this.updateControls();
  }
  state(): DocumentState {
    return {
      ...this.shell.state(),
      view: this.display,
      text: this.text(),
      docMode: this.mode,
      modeLocked: this.locked,
      display: this.display,
      savedText: this.savedText,
      documentId: this.documentID,
    };
  }
  async restore(state: Partial<DocumentState>) {
    this.shell.restore(state);
    const restoredName = state.fileName ?? null;
    const extension = restoredName?.split(".").pop()?.toLowerCase();
    this.previewAllowed =
      restoredName === null ||
      ["md", "markdown", "mmd", "mermaid"].includes(extension ?? "");
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
    this.shell.view.dispatch({
      effects: this.language.reconfigure(
        this.mode === "markdown"
          ? markdown({ codeLanguages: documentLanguages })
          : [],
      ),
    });
    this.display = !this.previewAllowed
      ? "source"
      : (state.display ??
        (state.view === "preview"
          ? "preview"
          : state.view === "split"
            ? "split"
            : "source"));
    this.savedText =
      typeof state.savedText === "string"
        ? state.savedText
        : typeof state.text === "string"
          ? state.text
          : "";
    this.documentID =
      typeof state.documentId === "string" ? state.documentId : null;
    this.shell.setDisplay(this.previewAllowed ? this.display : "source");
    this.updateControls();
    this.emitMode();
    if (
      this.previewAllowed &&
      (this.display === "preview" || this.display === "split")
    )
      await this.render();
  }
}
