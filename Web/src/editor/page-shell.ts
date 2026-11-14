import captureSymbol from "../assets/icons/capture.png";
import clearSymbol from "../assets/icons/clear.png";
import copySymbol from "../assets/icons/copy.png";
import saveSymbol from "../assets/icons/save.svg";
import { EditorView } from "@codemirror/view";
import { StateEffect, type Extension } from "@codemirror/state";
import {
  createEditor,
  restore,
  snapshot,
  replaceAll,
  type EditorSnapshot,
} from "./editor";
import { strings } from "../strings";
export type PageState = EditorSnapshot & {
  view: "source" | "preview" | "split";
  fileName: string | null;
  encoding?: "url" | "base64";
  wholeURL?: boolean;
};
export const element = <K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className = "",
  text?: string,
): HTMLElementTagNameMap[K] => {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
};
const icons: Record<string, string> = {
  preview:
    '<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',
  edit: '<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/>',
  split:
    '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M12 4v16"/>',
  save: '<path d="M4 4h12l4 4v12H4V4Z"/><path d="M8 4v6h8V4M8 20v-6h8v6"/>',
  copy: '<rect x="8" y="8" width="13" height="13" rx="2"/><path d="M16 5V3H3v13h2"/>',
  exportImage:
    '<rect x="5" y="2" width="14" height="20" rx="2"/><path d="m8 16 4-4 4 4M12 6v6"/>',
  clear:
    '<path d="m13 10 6.5-6.5a1.4 1.4 0 0 1 2 2L15 12"/><path d="m10 9 5 5-4 4-5-5 4-4Z"/><path d="M6 13c-3 0-4 2-4 5v3h3c3 0 5-1 5-4M5 18l2-2"/>',
  copied: '<path d="m5 12 4 4L19 6"/>',
};
export function setIcon(button: HTMLButtonElement, name: string): void {
  button.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name] ?? ""}</svg>`;
  const symbols: Record<string, string> = {
    copy: copySymbol,
    clear: clearSymbol,
    save: saveSymbol,
    exportImage: captureSymbol,
  };
  if (symbols[name]) {
    const icon = element("span", "system-icon");
    icon.setAttribute("aria-hidden", "true");
    icon.style.maskImage = `url("${symbols[name]}")`;
    button.replaceChildren(icon);
  }
  setButtonLabel(button, String(strings[name as keyof typeof strings] ?? name));
}
export function setButtonLabel(button: HTMLButtonElement, label: string): void {
  button.setAttribute("aria-label", label);
  button.title = label;
}
export function iconButton(
  name: string,
  action: () => void,
): HTMLButtonElement {
  const button = element("button", "icon-button");
  button.classList.add(`icon-${name}`);
  setIcon(button, name);
  button.onclick = action;
  return button;
}
export function pill(label: string, action: () => void): HTMLButtonElement {
  const button = element("button", "pill", label);
  button.onclick = action;
  return button;
}
export class PageShell {
  readonly view: EditorView;
  readonly source = element("div", "source");
  readonly preview = element("div", "preview");
  readonly info = element("div", "page-info");
  readonly file = element("div", "file-label");
  readonly content = element("div", "page-content");
  readonly actions = element("div", "page-actions");
  readonly fixed = element("div", "page-fixed");
  fileName: string | null = null;
  fileDirty = false;
  mode: "source" | "preview" = "source";
  private readonly extensions: Extension[];
  onChange: () => void = () => {};
  onStateChange: () => void = () => {};
  revision = 0;
  readonly root: HTMLElement;
  readonly kind: "json" | "qr" | "doc";
  constructor(root: HTMLElement, kind: "json" | "qr" | "doc") {
    this.root = root;
    this.kind = kind;
    root.classList.add("page-shell");
    root.dataset.kind = kind;
    const toolbar = element("div", "page-toolbar");
    toolbar.append(this.actions, this.fixed);
    this.preview.hidden = true;
    this.content.append(
      this.source,
      this.preview,
      this.file,
      this.info,
      toolbar,
    );
    root.replaceChildren(this.content);
    this.extensions = [
      EditorView.updateListener.of((update) => {
        if (update.docChanged) {
          this.revision++;
          this.updateInfo();
          this.onChange();
          this.onStateChange();
        }
      }),
    ];
    this.view = createEditor(this.source, this.extensions);
    this.updateInfo();
  }
  addExtensions(extension: Extension): void {
    this.extensions.push(extension);
    this.view.dispatch({ effects: StateEffect.appendConfig.of(extension) });
  }
  get text(): string {
    return this.view.state.doc.toString();
  }
  replace(text: string, event = "devbar.transform"): void {
    replaceAll(this.view, text, event);
  }
  showPreview(show: boolean): void {
    this.mode = show ? "preview" : "source";
    this.source.hidden = show;
    this.preview.hidden = !show;
    if (!show) this.view.focus();
  }
  updateInfo(message?: string): void {
    this.info.textContent = message ?? "";
    this.info.hidden = !message;
    this.content.classList.toggle("has-info", !!message);
    this.file.textContent = this.fileName
      ? strings.fileHint(this.fileName, this.fileDirty)
      : "";
    this.file.hidden = !this.fileName;
    this.content.classList.toggle("has-file", !!this.fileName);
  }
  state(): PageState {
    return { ...snapshot(this.view), view: this.mode, fileName: this.fileName };
  }
  restore(state: Partial<PageState>): void {
    const text = typeof state.text === "string" ? state.text : "";
    const anchor = Math.max(
      0,
      Math.min(text.length, state.selection?.anchor ?? 0),
    );
    const head = Math.max(0, Math.min(text.length, state.selection?.head ?? 0));
    restore(
      this.view,
      { text, selection: { anchor, head }, scrollTop: state.scrollTop ?? 0 },
      this.extensions,
    );
    this.fileName = state.fileName ?? null;
    this.updateInfo();
  }
}
