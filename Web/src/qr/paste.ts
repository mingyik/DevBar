import type { EditorState, Transaction } from "@codemirror/state";

export type PasteUpdate = {
  docChanged: boolean;
  startState: EditorState;
  state: EditorState;
  transactions: readonly Transaction[];
};

export function shouldAutoPreviewQRPaste(update: PasteUpdate): boolean {
  if (!update.docChanged || update.state.doc.length === 0) return false;
  if (!update.transactions.some((tr) => tr.isUserEvent("input.paste"))) {
    return false;
  }
  const previousLength = update.startState.doc.length;
  if (previousLength === 0) return true;
  const { ranges, main } = update.startState.selection;
  return ranges.length === 1 && main.from === 0 && main.to === previousLength;
}
