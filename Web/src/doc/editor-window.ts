import { markdown } from "@codemirror/lang-markdown";
import { EditorView } from "@codemirror/view";
import { decodeEnvelope, type JSONValue } from "../bridge/envelope";
import { post } from "../bridge/client";
import { createEditor, replaceAll } from "../editor/editor";
import { documentLanguages } from "./languages";
import { element, iconButton } from "../editor/page-shell";

/** Standalone Markdown input for split mode; no title bar, only a clear button. */
export function startDocumentEditor(): void {
  for (const screen of Array.from(
    document.querySelectorAll<HTMLElement>(".screen"),
  ))
    screen.hidden = true;
  const root = element("div", "doc-editor-window");
  const source = element("div", "doc-editor-source");
  const clear = iconButton("clear", () => clearText());
  clear.classList.add("doc-editor-clear");
  root.append(source, clear);
  document.body.append(root);
  let timer: ReturnType<typeof setTimeout> | undefined;
  let lastSent = "";
  let documentId: string | null = null;
  const view = createEditor(source, [
    markdown({ codeLanguages: documentLanguages }),
    EditorView.updateListener.of((update) => {
      if (update.docChanged) schedule();
    }),
  ]);
  function send() {
    const text = view.state.doc.toString();
    if (text === lastSent) return;
    lastSent = text;
    void post("doc.editorText", { text, documentId });
  }
  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(send, 120);
  }
  function clearText() {
    clearTimeout(timer);
    replaceAll(view, "", "devbar.clear");
    send();
    view.focus();
  }
  root.addEventListener("pointerdown", () => view.focus());
  const bridge = {
    async receive(raw: string): Promise<JSONValue> {
      const { type, payload } = decodeEnvelope(raw);
      switch (type) {
        case "theme.set":
          document.documentElement.dataset.theme =
            payload.theme === "dark" ? "dark" : "light";
          break;
        case "panel.size":
          document.documentElement.dataset.size =
            payload.size === "large" ? "large" : "normal";
          break;
        case "doc.editorInit": {
          const text = typeof payload.text === "string" ? payload.text : "";
          documentId =
            typeof payload.documentId === "string" ? payload.documentId : null;
          clearTimeout(timer);
          lastSent = text;
          replaceAll(view, text, "devbar.import");
          view.focus();
          break;
        }
        case "screen.show":
          root.hidden = false;
          view.focus();
          break;
        case "screen.hide":
          root.hidden = true;
          break;
        case "state.flush":
          send();
          return { ok: true };
      }
      return {};
    },
  };
  Object.assign(window, {
    __devbar: bridge,
    devbarEditorText: () => view.state.doc.toString(),
    devbarEditorFlush: () => {
      send();
      return view.state.doc.toString();
    },
  });
  void post("app.ready", { version: "1" }).then((reply) => {
    document.documentElement.dataset.theme =
      reply.theme === "dark" ? "dark" : "light";
    if (typeof reply.panelSize === "string")
      document.documentElement.dataset.size =
        reply.panelSize === "large" ? "large" : "normal";
  });
}
