import { StateEffect, StateField } from "@codemirror/state";
import { Decoration, EditorView, type DecorationSet } from "@codemirror/view";
export type Mark = { start: number; end: number };
const setMarks = StateEffect.define<Mark[]>();
export const errorMarks = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, transaction) {
    value = value.map(transaction.changes);
    if (transaction.docChanged) value = Decoration.none;
    for (const effect of transaction.effects)
      if (effect.is(setMarks)) {
        const length = transaction.newDoc.length;
        value = Decoration.set(
          effect.value
            .flatMap(({ start, end }) => {
              if (!length) return [];
              const from = Math.max(0, Math.min(start, length - 1));
              const to = Math.max(from + 1, Math.min(end, length));
              return [Decoration.mark({ class: "page-error" }).range(from, to)];
            })
            .sort((a, b) => a.from - b.from),
        );
      }
    return value;
  },
  provide: (field) => EditorView.decorations.from(field),
});
export function markErrors(view: EditorView, marks: Mark[]): void {
  view.dispatch({ effects: setMarks.of(marks) });
}
