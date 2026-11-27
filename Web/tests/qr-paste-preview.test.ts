import { EditorSelection, EditorState } from "@codemirror/state";
import { expect, it } from "vitest";
import {
  QRPreviewRequestGate,
  shouldAutoPreviewQRPaste,
} from "../src/qr/paste";

function applyPaste(
  doc: string,
  selection: EditorSelection,
  insert: string,
  userEvent = "input.paste",
) {
  const startState = EditorState.create({
    doc,
    selection,
    extensions: [EditorState.allowMultipleSelections.of(true)],
  });
  const transaction = startState.update({
    ...startState.replaceSelection(insert),
    userEvent,
  });
  return {
    docChanged: transaction.docChanged,
    startState,
    state: transaction.state,
    transactions: [transaction],
  };
}

it("auto-previews QR on paste into an empty editor", () => {
  const update = applyPaste(
    "",
    EditorSelection.single(0),
    "https://example.com",
  );
  expect(shouldAutoPreviewQRPaste(update)).toBe(true);
});

it("auto-previews QR when paste replaces the entire document", () => {
  const doc = "https://old.example.com";
  const update = applyPaste(
    doc,
    EditorSelection.single(0, doc.length),
    "https://new.example.com",
  );
  expect(shouldAutoPreviewQRPaste(update)).toBe(true);
});

it("stays in editor on partial paste, manual typing, or empty paste", () => {
  const doc = "https://example.com";
  expect(
    shouldAutoPreviewQRPaste(
      applyPaste(doc, EditorSelection.single(doc.length), "/path"),
    ),
  ).toBe(false);
  expect(
    shouldAutoPreviewQRPaste(
      applyPaste("", EditorSelection.single(0), "a", "input.type"),
    ),
  ).toBe(false);
  expect(
    shouldAutoPreviewQRPaste(
      applyPaste(doc, EditorSelection.single(0, doc.length), ""),
    ),
  ).toBe(false);
  expect(
    shouldAutoPreviewQRPaste(
      applyPaste(
        doc,
        EditorSelection.create([
          EditorSelection.range(0, 5),
          EditorSelection.range(8, doc.length),
        ]),
        "https://multi.example.com",
      ),
    ),
  ).toBe(false);
});

it("invalidates stale QR preview requests on newer request, edit return, or page release", () => {
  const gate = new QRPreviewRequestGate();
  const pasteToken = gate.begin();
  const manualToken = gate.begin();
  expect(gate.isCurrent(pasteToken)).toBe(false);
  expect(gate.isCurrent(manualToken)).toBe(true);

  gate.invalidate();
  expect(gate.isCurrent(manualToken)).toBe(false);

  const nextToken = gate.begin();
  expect(gate.isCurrent(nextToken)).toBe(true);
  gate.invalidate();
  expect(gate.isCurrent(nextToken)).toBe(false);
});
