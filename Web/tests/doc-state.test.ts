import { expect, it } from "vitest";
import { EditorState } from "@codemirror/state";
import { history, undo, redo } from "@codemirror/commands";
import {
  documentHistory,
  documentMetadata,
  metadataField,
  sourceText,
} from "../src/doc/state";
it("file import and its mode metadata undo and redo together without changing bytes", () => {
  let state = EditorState.create({
    doc: "# previous",
    extensions: [history(), documentHistory],
  });
  const text = "\r\nflowchart LR\r\n A --> B\r\n";
  state = state.update({
    changes: { from: 0, to: state.doc.length, insert: text },
    effects: documentMetadata.of({
      mode: "mermaid",
      locked: true,
      fileName: "diagram.mmd",
    }),
    userEvent: "devbar.import",
  }).state;
  // CodeMirror normalizes line endings in its document; preserving raw bytes is separately required by the page.
  expect(state.field(metadataField).locked).toBe(true);
  const target = {
    get state() {
      return state;
    },
    dispatch: (transaction: import("@codemirror/state").Transaction) => {
      state = transaction.state;
    },
  };
  expect(undo(target)).toBe(true);
  expect(state.doc.toString()).toBe("# previous");
  expect(state.field(metadataField)).toEqual({
    mode: "markdown",
    locked: false,
    fileName: null,
  });
  expect(redo(target)).toBe(true);
  expect(state.field(metadataField).mode).toBe("mermaid");
});
it("clearing unlocks imported or manually selected modes", () => {
  const state = EditorState.create({
    doc: "flowchart LR",
    extensions: documentHistory,
  });
  const imported = state.update({
    effects: documentMetadata.of({
      mode: "mermaid",
      locked: true,
      fileName: "x.mmd",
    }),
  }).state;
  expect(
    imported
      .update({ changes: { from: 0, to: imported.doc.length } })
      .state.field(metadataField),
  ).toEqual({ mode: "markdown", locked: false, fileName: "x.mmd" });
});

it.each([
  "\r\nflowchart LR\r\n A --> B\r\n",
  "flowchart LR\n A --> B\r\n",
  "flowchart LR\r A --> B",
])("untouched imports retain the original line endings: %j", (raw) => {
  expect(sourceText(raw.replace(/\r\n?|\n/g, "\n"), raw)).toBe(raw);
  expect(sourceText("modified", raw)).toBe("modified");
});
