import { post } from "../bridge/client";
import {
  defaultKeymap,
  history,
  historyKeymap,
  isolateHistory,
} from "@codemirror/commands";
import { searchKeymap } from "@codemirror/search";
import {
  EditorSelection,
  EditorState,
  type Extension,
} from "@codemirror/state";
import {
  drawSelection,
  EditorView,
  highlightSpecialChars,
  keymap,
} from "@codemirror/view";
import { libraryTheme } from "./library-theme";

export type EditorSnapshot = {
  text: string;
  selection: { anchor: number; head: number };
  scrollTop: number;
};

export function createEditor(
  parent: HTMLElement,
  extensions: Extension[] = [],
): EditorView {
  return new EditorView({
    parent,
    state: EditorState.create({
      doc: "",
      extensions: [...editorExtensions(), ...extensions],
    }),
  });
}

export function editorExtensions() {
  return [
    EditorView.domEventHandlers({
      paste(event, view) {
        const text = event.clipboardData?.getData("text/plain");
        if (text === undefined) return false;
        event.preventDefault();
        admitText(view, text, "input.paste");
        return true;
      },
      drop(event, view) {
        if (event.dataTransfer?.files.length) return false;
        const text = event.dataTransfer?.getData("text/plain");
        if (!text) return false;
        event.preventDefault();
        const position = view.posAtCoords({
          x: event.clientX,
          y: event.clientY,
        });
        admitText(view, text, "input.drop", position ?? undefined);
        return true;
      },
    }),
    history(),
    drawSelection(),
    highlightSpecialChars(),
    EditorView.lineWrapping,
    keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap]),
    libraryTheme(),
    EditorView.theme({
      ".cm-scroller": { fontFamily: "ui-monospace, monospace" },
      "&.cm-focused": { outline: "none" },
    }),
  ];
}

export function replaceAll(
  view: EditorView,
  text: string,
  userEvent: string,
): void {
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: text },
    userEvent,
    annotations: isolateHistory.of("full"),
  });
}

export function snapshot(view: EditorView): EditorSnapshot {
  const range = view.state.selection.main;
  return {
    text: view.state.doc.toString(),
    selection: { anchor: range.anchor, head: range.head },
    scrollTop: view.scrollDOM.scrollTop,
  };
}

export function restore(
  view: EditorView,
  state: EditorSnapshot,
  extensions: Extension[] = [],
): void {
  const next = EditorState.create({
    doc: state.text,
    selection: EditorSelection.single(
      state.selection.anchor,
      state.selection.head,
    ),
    extensions: [...editorExtensions(), ...extensions],
  });
  view.setState(next);
  view.scrollDOM.scrollTop = state.scrollTop;
}

function admitText(
  view: EditorView,
  text: string,
  event: string,
  position?: number,
): void {
  const state = view.state;
  void post("input.check", {
    bytes: text.length * 3,
  }).then((reply) => {
    if (
      reply.allowed === false ||
      view.state !== state ||
      !view.dom.isConnected
    )
      return;
    view.dispatch(
      position === undefined
        ? { ...view.state.replaceSelection(text), userEvent: event }
        : { changes: { from: position, insert: text }, userEvent: event },
    );
  });
}
