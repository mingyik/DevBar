import { EditorState } from "@codemirror/state";
import { foldState, foldable } from "@codemirror/language";
import { expect, test } from "vitest";
import { jsonFoldingExtension } from "../src/tools/json/folding";

test("JSON editor exposes fold ranges and registers CodeMirror fold state", () => {
  const text = '{\n  "items": [\n    1,\n    2\n  ]\n}';
  const state = EditorState.create({
    doc: text,
    extensions: [jsonFoldingExtension()],
  });
  const rootLine = state.doc.line(1);

  expect(foldable(state, rootLine.from, rootLine.to)).toEqual({
    from: 1,
    to: text.lastIndexOf("}"),
  });
  expect(state.field(foldState, false)).toBeDefined();
});
