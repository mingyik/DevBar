import { Compartment, type Extension } from "@codemirror/state";
import {
  defaultHighlightStyle,
  syntaxHighlighting,
} from "@codemirror/language";
import { oneDark, oneDarkHighlightStyle } from "@codemirror/theme-one-dark";
import { ViewPlugin } from "@codemirror/view";
import { tags } from "@lezer/highlight";
export type Token = "key" | "string" | "number" | "constant" | "container";
const tokenTags = {
  key: [tags.definition(tags.propertyName)],
  string: [tags.string],
  number: [tags.number],
  constant: [tags.bool, tags.null],
  container: [tags.punctuation],
};
export function tokenClass(
  token: Token,
  dark = document.documentElement.dataset.theme === "dark",
): string {
  return (
    (dark ? oneDarkHighlightStyle : defaultHighlightStyle).style(
      tokenTags[token],
    ) ?? ""
  );
}
export function refreshTreeTheme(root: ParentNode = document): void {
  for (const node of Array.from(
    root.querySelectorAll<HTMLElement>("[data-library-token]"),
  )) {
    if (node.dataset.libraryClass)
      node.classList.remove(...node.dataset.libraryClass.split(" "));
    const names = tokenClass(node.dataset.libraryToken as Token);
    if (names) node.classList.add(...names.split(" "));
    node.dataset.libraryClass = names;
  }
}
export function libraryTheme(): Extension {
  const compartment = new Compartment();
  const current = () =>
    document.documentElement.dataset.theme === "dark"
      ? oneDark
      : syntaxHighlighting(defaultHighlightStyle);
  return [
    compartment.of(current()),
    ViewPlugin.fromClass(
      class {
        private readonly observer: MutationObserver;
        constructor(view: import("@codemirror/view").EditorView) {
          this.observer = new MutationObserver(() =>
            view.dispatch({ effects: compartment.reconfigure(current()) }),
          );
          this.observer.observe(document.documentElement, {
            attributes: true,
            attributeFilter: ["data-theme"],
          });
        }
        destroy(): void {
          this.observer.disconnect();
        }
      },
    ),
  ];
}
