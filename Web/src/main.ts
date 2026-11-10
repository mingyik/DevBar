import type { EditorView } from "@codemirror/view";
import { decodeEnvelope, encodeEnvelope, type Envelope, type JSONValue } from "./bridge/envelope.ts";
import { createEditor, replaceAll, restore, snapshot, type EditorSnapshot } from "./editor/editor.ts";
import "./styles/app.css";
import "./styles/contrast.css";
import "./theme/tokens.css";

type ScreenName = "tools" | "doc";

type ToolsState = EditorSnapshot & {
  view: "source" | "preview";
  lockedType: string | null;
};

type DocState = EditorSnapshot & {
  view: "source" | "preview";
  docMode: "markdown" | "mermaid";
  modeLocked: boolean;
  fileName: string | null;
};

type ReadyReply = {
  theme?: string;
  panelSize?: string;
};

type LoadReply = {
  state?: JSONValue;
};

const toolsView = createEditor(requiredElement("tools"));
const docView = createEditor(requiredElement("doc"));
let toolsState = emptyTools();
let docState = emptyDoc();
let saveTimer: ReturnType<typeof setTimeout> | undefined;

const bridge = {
  async receive(raw: string): Promise<JSONValue> {
    return handleNative(decodeEnvelope(raw));
  },
};

declare global {
  interface Window {
    __devbar: typeof bridge;
    webkit?: {
      messageHandlers: {
        devbar: { postMessage: (body: string) => Promise<string> };
      };
    };
  }
}

window.__devbar = bridge;
for (const view of [toolsView, docView]) {
  view.contentDOM.addEventListener("keyup", scheduleSave);
}

void post("app.ready", { version: "1" }).then((reply) => {
  applyReady(reply);
  void loadScreen("tools");
  void loadScreen("doc");
});

function handleNative(envelope: Envelope): JSONValue {
  const payload = envelope.payload;
  switch (envelope.type) {
    case "theme.set":
      document.documentElement.dataset.theme = stringField(payload, "theme") ?? "light";
      return {};
    case "screen.show":
      showScreen(stringField(payload, "screen") === "doc" ? "doc" : "tools");
      return {};
    case "panel.size":
      document.documentElement.dataset.size =
        stringField(payload, "size") === "large" ? "large" : "normal";
      return {};
    case "settings.set":
      return {};
    case "tools.import":
      importText(toolsView, stringField(payload, "text") ?? "", stringField(payload, "mode") ?? "replace");
      scheduleSave();
      return {};
    case "doc.import":
      importText(docView, stringField(payload, "text") ?? "", "replace");
      if (stringField(payload, "docMode") === "mermaid") docState.docMode = "mermaid";
      if (typeof payload.fileName === "string") docState.fileName = payload.fileName;
      scheduleSave();
      return {};
    case "memory.flush":
      void saveNow();
      return { ok: true };
    default:
      return {};
  }
}

function showScreen(screen: ScreenName): void {
  requiredElement("tools").hidden = screen !== "tools";
  requiredElement("doc").hidden = screen !== "doc";
  (screen === "doc" ? docView : toolsView).focus();
}

function importText(view: EditorView, text: string, mode: string): void {
  if (mode === "ifEmpty" && view.state.doc.length > 0) return;
  replaceAll(view, text, "devbar.import");
}

async function loadScreen(screen: ScreenName): Promise<void> {
  const reply = await post("state.load", { screen });
  const state = reply.state;
  if (state === null || state === undefined || typeof state !== "object" || Array.isArray(state)) return;
  const text = typeof state.text === "string" ? state.text : "";
  const selection = selectionOf(state.selection);
  const scrollTop = typeof state.scrollTop === "number" ? state.scrollTop : 0;
  if (screen === "tools") {
    toolsState = { ...emptyTools(), text, selection, scrollTop };
    restore(toolsView, { text, selection, scrollTop });
    return;
  }
  docState = {
    ...emptyDoc(),
    text,
    selection,
    scrollTop,
    docMode: state.docMode === "mermaid" ? "mermaid" : "markdown",
    modeLocked: state.modeLocked === true,
    fileName: typeof state.fileName === "string" ? state.fileName : null,
  };
  restore(docView, { text, selection, scrollTop });
}

function scheduleSave(): void {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    void saveNow();
  }, 1000);
}

async function saveNow(): Promise<void> {
  toolsState = { ...toolsState, ...snapshot(toolsView), view: "source" };
  docState = { ...docState, ...snapshot(docView), view: "source" };
  await post("state.save", { screen: "tools", state: toolsState });
  await post("state.save", { screen: "doc", state: docState });
}

async function post(type: string, payload: { [key: string]: JSONValue }): Promise<LoadReply & ReadyReply> {
  const envelope: Envelope = { v: 1, id: crypto.randomUUID(), type, payload };
  const raw = await window.webkit?.messageHandlers.devbar.postMessage(encodeEnvelope(envelope));
  if (!raw) return {};
  const parsed: unknown = JSON.parse(raw);
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return {};
  return parsed as LoadReply & ReadyReply;
}

function applyReady(reply: ReadyReply): void {
  if (typeof reply.theme === "string") document.documentElement.dataset.theme = reply.theme;
  if (reply.panelSize === "large") document.documentElement.dataset.size = "large";
}

function selectionOf(value: JSONValue | undefined): { anchor: number; head: number } {
  if (value === null || value === undefined || typeof value !== "object" || Array.isArray(value)) {
    return { anchor: 0, head: 0 };
  }
  return {
    anchor: typeof value.anchor === "number" ? value.anchor : 0,
    head: typeof value.head === "number" ? value.head : 0,
  };
}

function stringField(payload: Envelope["payload"], key: string): string | undefined {
  const value = payload[key];
  return typeof value === "string" ? value : undefined;
}

function requiredElement(id: string): HTMLElement {
  const element = document.getElementById(id);
  if (!element) throw new Error(`missing ${id}`);
  return element;
}

function emptyTools(): ToolsState {
  return { text: "", view: "source", lockedType: null, selection: { anchor: 0, head: 0 }, scrollTop: 0 };
}

function emptyDoc(): DocState {
  return {
    text: "",
    view: "source",
    docMode: "markdown",
    modeLocked: false,
    fileName: null,
    selection: { anchor: 0, head: 0 },
    scrollTop: 0,
  };
}
