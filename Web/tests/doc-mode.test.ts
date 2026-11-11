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
it.each([
  "timeline of the project",
  "pie charts are great.",
  "journey to the west",
  "block quotes",
  "graph is useful",
  "timeline\n# 标题",
  "timeline\n- 列表",
  "timeline\n> 引用",
  "timeline\n* 列表",
  "timeline\n1. 列表",
  "timeline\n| 表格 |",
  "timeline\nThis is a long ordinary sentence.",
])("conservative prose rejection %s", (s) =>
  expect(detectDocMode(s)).toBe("markdown"),
);
it.each([
  "flowchart LR\n A-->B",
  'pie showData\n"A": 1',
  "timeline\n title 项目\n 2026 : 发布",
  "stateDiagram-v2",
  "sequenceDiagram\n accTitle: Test\n A->>B: hello",
])("valid header %s", (s) => expect(detectDocMode(s)).toBe("mermaid"));
