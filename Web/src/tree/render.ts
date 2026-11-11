import { refreshTreeTheme } from "../editor/library-theme";
import { isLosslessNumber } from "lossless-json";
import { container, copyValue, childPath, summary } from "./model";
import { element } from "../editor/page-shell";
import { strings } from "../strings";
export function renderTree(
  root: HTMLElement,
  value: unknown,
  copy: (text: string) => Promise<unknown>,
): void {
  function node(
    value: unknown,
    path: string,
    key: string | number | null,
    depth: number,
  ): HTMLElement {
    const block = element(
      "div",
      depth === 0 ? "tree-node tree-root" : "tree-node",
    );
    const row = element("div", "tree-row");
    const toggle = element(
      "button",
      "tree-toggle",
      container(value) ? "▸" : "",
    );
    toggle.disabled = !container(value);
    const keyNode = element("span", "tree-key", key === null ? "" : `${key}:`);
    keyNode.dataset.libraryToken = "key";
    const type = container(value)
      ? "container"
      : isLosslessNumber(value)
        ? "number"
        : typeof value === "string"
          ? "string"
          : "constant";
    const label = element(
      "span",
      `tree-value ${type}`,
      summary(value) + (container(value) ? ` ${strings.items}` : ""),
    );
    label.dataset.libraryToken = type;
    const actions = element("span", "tree-buttons");
    for (const [title, text] of [
      [strings.copyValue, () => copyValue(value)],
      [strings.copyPath, () => path],
    ] as const) {
      const button = element("button", "", title);
      button.onclick = () => {
        void copy(text()).then(() => {
          button.textContent = strings.copied;
          setTimeout(() => {
            button.textContent = title;
          }, 1000);
        });
      };
      actions.append(button);
    }
    row.append(toggle, keyNode, label, actions);
    block.append(row);
    let children: HTMLElement | undefined;
    function expand(): void {
      if (!container(value)) return;
      if (children) {
        children.hidden = !children.hidden;
        toggle.textContent = children.hidden ? "▸" : "▾";
        return;
      }
      children = element("div", "tree-children");
      block.append(children);
      toggle.textContent = "▾";
      const keys = Object.keys(value);
      let loaded = 0;
      const batch = () => {
        const fragment = document.createDocumentFragment();
        const end = Math.min(loaded + 200, keys.length);
        for (; loaded < end; loaded++) {
          const key = Array.isArray(value)
            ? Number(keys[loaded])
            : keys[loaded];
          fragment.append(
            node(
              (value as Record<string, unknown>)[String(key)],
              childPath(path, key),
              key,
              depth + 1,
            ),
          );
        }
        children!.append(fragment);
        refreshTreeTheme(children!);
        if (loaded < keys.length) {
          const more = element(
            "button",
            "tree-more",
            strings.more(keys.length - loaded),
          );
          more.onclick = () => {
            more.remove();
            batch();
          };
          children!.append(more);
        }
      };
      batch();
    }
    toggle.onclick = expand;
    if (container(value) && depth < 2) expand();
    return block;
  }
  root.replaceChildren(node(value, "$", null, 0));
  refreshTreeTheme(root);
}
