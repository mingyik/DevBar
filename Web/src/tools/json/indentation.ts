import { countColumn } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  EditorView,
  ViewPlugin,
  type ViewUpdate,
} from "@codemirror/view";

function decorations(view: EditorView): DecorationSet {
  const lines = [];
  let previous = -1;
  for (const range of view.visibleRanges) {
    for (let position = range.from; position <= range.to;) {
      const line = view.state.doc.lineAt(position);
      if (line.from !== previous) {
        previous = line.from;
        const whitespace = /^[\t ]*/.exec(line.text)?.[0] ?? "";
        // Bound visual indentation so deeply nested content still has room to wrap.
        const columns = Math.min(
          countColumn(whitespace, view.state.tabSize),
          24,
        );
        if (columns > 0) {
          const positions = [];
          const images = [];
          for (let column = 0; column < columns; column += 2) {
            positions.push(`${column + 0.1}ch 0`);
            images.push(
              "repeating-linear-gradient(to bottom, var(--line-divider) 0 1px, transparent 1px 4px)",
            );
          }
          lines.push(
            Decoration.line({
              attributes: {
                class: "cm-json-indent",
                style: `padding-left:${columns}ch;text-indent:-${columns}ch;background-image:${images.join(",")};background-position:${positions.join(",")}`,
              },
            }).range(line.from),
          );
        }
      }
      position = line.to + 1;
    }
  }
  return Decoration.set(lines);
}

export const jsonIndentation = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = decorations(view);
    }
    update(update: ViewUpdate) {
      if (update.docChanged || update.viewportChanged)
        this.decorations = decorations(update.view);
    }
  },
  { decorations: (plugin) => plugin.decorations },
);
