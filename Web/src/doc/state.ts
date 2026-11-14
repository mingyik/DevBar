import { StateEffect, StateField } from "@codemirror/state";
import { invertedEffects } from "@codemirror/commands";
import type { DocMode } from "./mode";
export type DocumentMetadata = {
  mode: DocMode;
  locked: boolean;
  fileName: string | null;
  rawText?: string;
};
export const documentMetadata = StateEffect.define<DocumentMetadata>();
export const metadataField = StateField.define<DocumentMetadata>({
  create: () => ({ mode: "markdown", locked: false, fileName: null }),
  update(value, transaction) {
    for (const effect of transaction.effects)
      if (effect.is(documentMetadata)) value = effect.value;
    if (transaction.docChanged && transaction.newDoc.length === 0)
      return { ...value, mode: "markdown", locked: false };
    return value;
  },
});
export const documentHistory = [
  metadataField,
  invertedEffects.of((transaction) =>
    (transaction.docChanged && transaction.newDoc.length === 0) ||
    transaction.effects.some((effect) => effect.is(documentMetadata))
      ? [documentMetadata.of(transaction.startState.field(metadataField))]
      : [],
  ),
];

/** CodeMirror uses LF internally; untouched imports retain their exact line endings. */
export function sourceText(normalized: string, raw?: string): string {
  return raw !== undefined && raw.replace(/\r\n?|\n/g, "\n") === normalized
    ? raw
    : normalized;
}

export function isCurrentDocumentMessage(
  currentID: string | null,
  incomingID: string | null,
): boolean {
  return currentID === incomingID;
}
