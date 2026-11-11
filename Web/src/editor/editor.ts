import {
  defaultKeymap,
  history,
  historyKeymap,
  isolateHistory,
} from "@codemirror/commands";
import { syntaxHighlighting } from "@codemirror/language";
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
import { devbarHighlightStyle } from "../theme/cm-highlight.ts";

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
    history(),
    drawSelection(),
    highlightSpecialChars(),
    EditorView.lineWrapping,
    keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap]),
    syntaxHighlighting(devbarHighlightStyle),
    EditorView.theme({
      "&": { backgroundColor: "transparent", color: "var(--text-primary)" },
      ".cm-scroller": { fontFamily: "ui-monospace, monospace" },
      ".cm-content": { caretColor: "var(--text-primary)" },
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
