import { expect, it, vi } from "vitest";
const state = vi.hoisted(() => ({
  release: () => {},
  slow: Promise.resolve(),
}));
vi.mock("../src/doc/preview", () => ({
  createMarkdownPreview: () => ({
    renderAsync: async (text: string, theme: string) => {
      if (text === "old") await state.slow;
      return text + ":" + theme;
    },
  }),
}));
vi.mock("../src/doc/mermaid", () => ({
  renderMermaidElements: async () => {},
}));
import { renderDocument } from "../src/doc/document";
it("latest content and theme survive an older pending highlight", async () => {
  state.slow = new Promise<void>((resolve) => {
    state.release = resolve;
  });
  const doc = {
    createElement: () => ({
      innerHTML: "",
      get childNodes() {
        return [this.innerHTML];
      },
    }),
  };
  const root = {
    ownerDocument: doc,
    innerHTML: "",
    replaceChildren(this: { innerHTML: string }, ...nodes: unknown[]) {
      this.innerHTML = nodes.join("");
    },
  } as unknown as HTMLElement;
  const old = renderDocument(root, "old", { theme: "light", mode: "markdown" });
  await renderDocument(root, "new", { theme: "dark", mode: "markdown" });
  expect(root.innerHTML).toBe("new:dark");
  state.release();
  await old;
  expect(root.innerHTML).toBe("new:dark");
});
