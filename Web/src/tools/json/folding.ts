import { json } from "@codemirror/lang-json";
import { foldGutter } from "@codemirror/language";
import type { Extension } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { jsonIndentation } from "./indentation";

function marker(open: boolean): HTMLElement {
  const wrapper = document.createElement("span");
  wrapper.title = open ? "折叠" : "展开";
  const chevron = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  chevron.setAttribute("viewBox", "0 0 12 12");
  chevron.setAttribute("class", "cm-fold-chevron");
  chevron.setAttribute("data-open", String(open));
  chevron.setAttribute("aria-hidden", "true");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", "M3.5 2 L9 6 L3.5 10 Z");
  path.setAttribute("fill", "currentColor");
  chevron.append(path);
  wrapper.append(chevron);
  return wrapper;
}

export function jsonFoldingExtension(): Extension {
  return [
    json(),
    jsonIndentation,
    foldGutter({ markerDOM: marker }),
    EditorView.theme({
      "& .cm-gutters.cm-gutters-before": {
        backgroundColor: "transparent",
        border: "none",
        color: "var(--text-tertiary)",
      },
      "& .cm-content": { paddingLeft: "4px" },
      ".cm-foldGutter": { width: "12px", backgroundColor: "transparent" },
      ".cm-foldGutter .cm-gutterElement": {
        display: "grid",
        placeItems: "center",
        width: "12px",
        padding: "0",
        backgroundColor: "transparent",
      },
      ".cm-fold-chevron": {
        display: "block",
        position: "relative",
        left: "2px",
        width: "12px",
        height: "12px",
        opacity: "0",
        transition: "opacity 100ms ease, transform 120ms ease",
      },
      ".cm-foldGutter .cm-gutterElement:hover .cm-fold-chevron": {
        opacity: "1",
      },
      '.cm-fold-chevron[data-open="true"]': { transform: "rotate(90deg)" },
    }),
  ];
}
