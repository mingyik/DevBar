import { strings } from "./strings";
export const entryName = "DevBar";
import { decodeEnvelope, type JSONValue } from "./bridge/envelope";
import { refreshTreeTheme } from "./editor/library-theme";
import { post } from "./bridge/client";
import { startTransform } from "./tools/json/client";
import { routeImport } from "./tools/json/actions";
import { DocPage } from "./doc/page";
import "./styles/prose.css";
import "./styles/code.css";
import "./styles/table.css";
import "./styles/mermaid.css";
import { QRPage } from "./qr/page";
import { JsonPage } from "./tools/json/page";
import { PageShell, type PageState } from "./editor/page-shell";
import { installReadOnlyScrollbars } from "./styles/readonly-scroll";
import { startDocumentEditor } from "./doc/editor-window";
import "./styles/app.css";
import "./styles/pages.css";
import "./styles/contrast.css";
import "./theme/tokens.css";

type Page = "json" | "qr" | "doc";
let current: Page = "json";
let transitions: Promise<void> = Promise.resolve();
let autoImport = false;
const pages = new Map<Page, PageShell>();
const importGenerations = new Map<Page, number>();
function beginImport(page: Page): number {
  const generation = (importGenerations.get(page) ?? 0) + 1;
  importGenerations.set(page, generation);
  return generation;
}
let json: JsonPage;
let qr: QRPage;
let doc: DocPage;
let saveTimer: ReturnType<typeof setTimeout> | undefined;
const bridge = {
  async receive(raw: string): Promise<JSONValue> {
    const { type, payload } = decodeEnvelope(raw);
    switch (type) {
      case "theme.set":
        document.documentElement.dataset.theme =
          payload.theme === "dark" ? "dark" : "light";
        refreshTreeTheme();
        doc?.refresh();
        break;
      case "panel.size":
        document.documentElement.dataset.size =
          payload.size === "large" ? "large" : "normal";
        doc?.refresh();
        break;
      case "settings.set":
        autoImport = payload.autoImport !== false;
        break;
      case "screen.show": {
        const value = payload.page ?? payload.screen;
        const next = value === "qr" ? "qr" : value === "doc" ? "doc" : "json";
        transitions = transitions.catch(() => {}).then(() => show(next));
        await transitions;
        break;
      }
      case "screen.hide":
        transitions = transitions
          .catch(() => {})
          .then(async () => {
            await save();
            for (const shell of pages.values()) shell.root.hidden = true;
            json.releaseMemory();
            qr.releaseMemory();
            await doc.releaseMemory();
          });
        await transitions;
        break;
      case "tools.import": {
        const page = payload.page === "qr" ? "qr" : "json";
        await importText(
          page,
          typeof payload.text === "string" ? payload.text : "",
          payload.mode === "ifEmpty",
          typeof payload.fileName === "string" ? payload.fileName : null,
        );
        break;
      }
      case "doc.toggleMode":
      case "doc.cycleMode":
        await transitions.catch(() => {});
        if (current === "doc") await doc.togglePreview();
        else if (current === "qr") await qr.togglePreview();
        break;
      case "doc.import": {
        const admission = await post("input.check", {
          bytes: new TextEncoder().encode(
            typeof payload.text === "string" ? payload.text : "",
          ).length,
        });
        if (admission.allowed === false) break;
        doc.import(
          typeof payload.text === "string" ? payload.text : "",
          typeof payload.fileName === "string" ? payload.fileName : null,
          payload.docMode === "mermaid"
            ? "mermaid"
            : payload.docMode === "markdown"
              ? "markdown"
              : undefined,
          typeof payload.documentId === "string" ? payload.documentId : null,
          typeof payload.savedText === "string" ? payload.savedText : undefined,
          payload.display === "preview" ||
            payload.display === "split" ||
            payload.display === "source"
            ? payload.display
            : undefined,
          typeof payload.modeLocked === "boolean"
            ? payload.modeLocked
            : undefined,
        );
        scheduleSave();
        break;
      }
      case "doc.display":
        doc.setDisplayMode(
          payload.mode === "preview"
            ? "preview"
            : payload.mode === "split"
              ? "split"
              : "source",
        );
        break;
      case "doc.setEditorText":
        doc.applyEditorText(
          typeof payload.text === "string" ? payload.text : "",
          typeof payload.documentId === "string" ? payload.documentId : null,
        );
        break;
      case "state.flush":
        await transitions.catch(() => {});
        await save();
        return { ok: true };
      case "memory.flush":
        transitions = transitions
          .catch(() => {})
          .then(async () => {
            await save();
            json.releaseMemory();
            qr.releaseMemory();
            await doc.releaseMemory();
          });
        await transitions;
        return { ok: true };
    }
    return {};
  },
  docStatus(text?: string | null) {
    return doc.documentStatus(text);
  },
  applyEditorText(text: string, documentId: string | null) {
    doc.applyEditorText(text, documentId);
    return { ok: true };
  },
  docText() {
    return doc.documentText();
  },
  docMode() {
    return doc.documentMode();
  },
  docState() {
    return doc.state();
  },
  docMarkSaved(
    text: string,
    fileName: string | null,
    documentId: string | null,
  ) {
    doc.markSaved(text, fileName, documentId);
    return { ok: true };
  },
};
declare global {
  interface Window {
    __devbar: typeof bridge;
  }
}
if (typeof document !== "undefined") {
  if (new URLSearchParams(location.search).has("doc-editor"))
    startDocumentEditor();
  else void start();
}
async function start(): Promise<void> {
  installReadOnlyScrollbars(document);
  for (const [page, id] of [
    ["json", "tools"],
    ["qr", "qr"],
    ["doc", "doc"],
  ] as const) {
    const root = document.getElementById(id);
    if (!root) throw new Error(`missing ${id}`);
    const shell = new PageShell(root, page);
    shell.onStateChange = scheduleSave;
    if (page === "json") json = new JsonPage(shell);
    if (page === "qr") qr = new QRPage(shell);
    if (page === "doc") doc = new DocPage(shell);
    pages.set(page, shell);
    const reply = await post("state.load", { screen: page });
    if (reply.state && typeof reply.state === "object")
      if (page === "json")
        await json.restore(reply.state as Partial<PageState>);
      else if (page === "qr")
        await qr.restore(reply.state as Partial<PageState>);
      else await doc.restore(reply.state as Partial<PageState>);
  }
  window.__devbar = bridge;
  const reply = await post("app.ready", { version: "1" });
  document.documentElement.dataset.theme =
    reply.theme === "dark" ? "dark" : "light";
  if (reply.settings && typeof reply.settings === "object")
    autoImport =
      (reply.settings as Record<string, unknown>).autoImport !== false;
}
async function show(page: Page): Promise<void> {
  if (current !== page) {
    await save();
    if (current === "json") json.releaseMemory();
    if (current === "qr") qr.releaseMemory();
    if (current === "doc") await doc.releaseMemory();
  }
  current = page;
  for (const [name, shell] of pages) shell.root.hidden = name !== page;
  const shell = pages.get(page)!;
  if (page === "doc") doc.refresh();
  if (page === "json") await json.refresh();
  if (page === "qr") await qr.refresh();
  shell.view.focus();
  if (autoImport && shell.text === "" && page !== "doc") {
    const revision = shell.revision;
    const generation = importGenerations.get(page);
    const reply = await post("clipboard.readText");
    if (
      revision === shell.revision &&
      generation === importGenerations.get(page) &&
      current === page &&
      reply.status === "ok" &&
      typeof reply.text === "string" &&
      shell.text === ""
    )
      await importText(page, reply.text, true, null);
  }
}
async function importText(
  page: Page,
  text: string,
  ifEmpty: boolean,
  fileName: string | null,
): Promise<void> {
  const shell = pages.get(page);
  if (!shell || (ifEmpty && shell.text !== "")) return;
  const admission = await post("input.check", {
    bytes: new TextEncoder().encode(text).length,
  });
  if (admission.allowed === false) return;
  const revision = shell.revision;
  const generation = beginImport(page);
  let incoming = text;
  if (page === "json") {
    const result = await startTransform("format", text).result;
    if (result.status === "success") incoming = result.text;
    if (
      revision !== shell.revision ||
      generation !== importGenerations.get(page)
    )
      return;
    json.setEncoding(routeImport(text).encoding);
  }
  shell.showPreview(false);
  shell.replace(incoming, "devbar.import");
  shell.fileName = fileName;
  shell.updateInfo();
  if (page === "json") await json.analyze();
  scheduleSave();
}
function scheduleSave(): void {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    void save().catch(() => post("ui.toast", { text: strings.saveFailed }));
  }, 1000);
}
async function save(): Promise<void> {
  for (const [screen, shell] of pages)
    if (
      (
        await post("state.save", {
          screen,
          state: (screen === "json"
            ? json.state()
            : screen === "doc"
              ? doc.state()
              : shell.state()) as unknown as JSONValue,
        })
      ).ok === false
    )
      throw new Error("state save failed");
}
export function activePage(): string {
  return current;
}
