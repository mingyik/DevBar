import { isolateHistory } from "@codemirror/commands";
import {
  documentHistory,
  documentMetadata,
  isCurrentDocumentMessage,
  metadataField,
  sourceText,
} from "./state";
import { Compartment, Transaction } from "@codemirror/state";
import { markdown } from "@codemirror/lang-markdown";
import { documentLanguages } from "./languages";
import {
  PageShell,
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
  private saveInProgress = false;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private previewTimer: ReturnType<typeof setTimeout> | undefined;
  private infoTimer: ReturnType<typeof setTimeout> | undefined;
  private renderKey = "";
  private pending: Promise<void> = Promise.resolve();
  private toggle: HTMLButtonElement;
  private saveButton: HTMLButtonElement;
  private contextAction: HTMLButtonElement;
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
    this.toggle = iconButton("preview", () => {
      void this.cycleDisplayMode();
    });
    shell.actions.append(this.toggle);
    this.saveButton = iconButton("save", () => {
      void this.save();
    });
    this.saveButton.classList.add("save-button");
    this.contextAction = iconButton("clear", () => {
      if (shell.mode === "preview") {
        void this.export();
      } else {
        shell.replace("", "devbar.clear");
        this.locked = false;
        this.setMode("markdown");
      }
    });
    shell.fixed.append(this.saveButton, this.contextAction);
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
  ) {
    this.shell.view.dispatch({
      changes: { from: 0, to: this.shell.view.state.doc.length, insert: text },
      effects: documentMetadata.of({
        mode: mode ?? detectDocMode(text),
        locked: !!mode && text !== "",
        fileName,
        rawText: text,
      }),
      annotations: isolateHistory.of("full"),
      userEvent: "devbar.import",
    });
    this.locked = !!mode && text !== "";
    this.setMode(text === "" ? "markdown" : (mode ?? detectDocMode(text)));
    this.shell.fileName = fileName;
    this.savedText = text;
    this.documentID = documentId;
    this.updateControls();
    this.emitMode();
    this.shell.showPreview(
      this.display === "preview" || this.display === "split",
    );
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
    setIcon(
      this.contextAction,
      this.display === "preview" || this.display === "split"
        ? "exportImage"
        : "clear",
    );
    setButtonLabel(
      this.contextAction,
      this.display === "preview" || this.display === "split"
        ? strings.exportImage
        : strings.clear,
    );
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
    if (mode === this.display) return;
    this.display = mode;
    this.shell.showPreview(mode === "preview" || mode === "split");
    this.updateControls();
    this.shell.onStateChange();
    this.emitMode();
    if (mode === "preview" || mode === "split") void this.render();
    else this.shell.view.focus();
  }
  private async cycleDisplayMode() {
    if (this.display === "split") {
      const reply = await post("doc.flushEditor", {
        documentId: this.documentID,
      });
      if (
        reply.ok !== true ||
        typeof reply.text !== "string" ||
        (reply.documentId ?? null) !== this.documentID
      )
        return;
      this.applyEditorText(reply.text, this.documentID);
    }
    this.display = nextDisplayMode(this.display);
    this.shell.showPreview(
      this.display === "preview" || this.display === "split",
    );
    this.updateControls();
    this.shell.onStateChange();
    this.emitMode();
    if (this.display === "preview" || this.display === "split") {
      void this.render();
    } else {
      this.shell.view.focus();
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
  applyEditorText(text: string, documentId: string | null = null) {
    if (!isCurrentDocumentMessage(this.documentID, documentId)) return;
    if (this.text() === text) return;
    this.shell.view.dispatch({
      changes: { from: 0, to: this.shell.view.state.doc.length, insert: text },
      annotations: Transaction.addToHistory.of(false),
      userEvent: "devbar.sync",
    });
    this.renderKey = "";
    if (this.display === "split") void this.render();
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
        if (
          typeof reply.currentText === "string" &&
          reply.currentText !== this.text()
        )
          this.applyEditorText(reply.currentText, this.documentID);
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
  async togglePreview() {
    await this.cycleDisplayMode();
  }
  async render() {
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
    clearTimeout(this.timer);
    clearTimeout(this.previewTimer);
    clearTimeout(this.infoTimer);
    await this.pending;
    this.shell.preview.replaceChildren();
    this.renderKey = "";
    releaseDocumentPreview(this.shell.preview.ownerDocument);
    releaseMermaidCache();
    await releaseHighlighter();
  }
  async export() {
    const restoreSource = this.display === "source";
    if (restoreSource) this.shell.showPreview(true);
    await this.render();
    await this.pending;
    await exportPreview(this.shell);
    if (restoreSource) {
      this.shell.showPreview(false);
      this.shell.view.focus();
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
    this.display =
      state.display ??
      (state.view === "preview"
        ? "preview"
        : state.view === "split"
          ? "split"
          : "source");
    this.savedText =
      typeof state.savedText === "string"
        ? state.savedText
        : typeof state.text === "string"
          ? state.text
          : "";
    this.documentID =
      typeof state.documentId === "string" ? state.documentId : null;
    this.shell.showPreview(
      this.display === "preview" || this.display === "split",
    );
    this.updateControls();
    this.emitMode();
    if (this.display === "preview" || this.display === "split")
      await this.render();
  }
}
