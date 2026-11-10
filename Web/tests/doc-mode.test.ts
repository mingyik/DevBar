import { expect, it } from "vitest";
import { detectDocMode } from "../src/doc/mode";
import { mermaidKeywords } from "../src/doc/mermaid-keywords";
it.each(mermaidKeywords)("keyword %s", (key) =>
  expect(detectDocMode(key + "\n A --> B")).toBe("mermaid"),
);
it.each([
  "graphs are useful",
  "# flowchart",
  "```mermaid\nflowchart LR\n```",
  "~~~\ngraph LR\n~~~",
  "---\nunclosed",
  "plain text",
])("markdown %s", (s) => expect(detectDocMode(s)).toBe("markdown"));
it("skips frontmatter and comments", () =>
  expect(
    detectDocMode(
      "---\ntitle: diagram\n---\n\n%% comment\nstateDiagram-v2\n A --> B",
    ),
  ).toBe("mermaid"));
it("does not mutate source", () => {
  const s = "%%x\n graph LR";
  detectDocMode(s);
  expect(s).toBe("%%x\n graph LR");
});
