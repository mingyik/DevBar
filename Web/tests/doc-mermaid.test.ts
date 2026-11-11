import { expect, it } from "vitest";
import { mermaidOptions, pngDimensions } from "../src/doc/mermaid";
it.each(["light", "dark"] as const)(
  "%s keeps strict security and the library theme",
  (theme) => {
    const options = mermaidOptions(theme);
    expect(options.securityLevel).toBe("strict");
    expect(options.htmlLabels).toBe(false);
    expect(options.theme).toBe(theme === "dark" ? "dark" : "default");
    for (const key of [
      "secure",
      "securityLevel",
      "startOnLoad",
      "maxTextSize",
      "suppressErrorRendering",
      "maxEdges",
      "theme",
      "themeVariables",
      "themeCSS",
      "look",
      "fontFamily",
      "darkMode",
      "htmlLabels",
    ])
      expect(options.secure).toContain(key);
    expect(options.journey?.textPlacement).toBe("tspan");
    expect(options.themeVariables).toBeUndefined();
  },
);
it("layout is selected by the supported root layout option", () => {
  expect(mermaidOptions("light").layout).toBe("dagre");
  expect(mermaidOptions("dark").layout).toBe("dagre");
});
it("PNG checks the actual 2x allocation and finite edges", () => {
  expect(pngDimensions(370, 58)).toEqual({ width: 740, height: 116 });
  for (const [w, h] of [
    [5000, 1],
    [2500, 2500],
    [Infinity, 1],
    [0, 2],
  ])
    expect(() => pngDimensions(w, h)).toThrow();
});
it("only known unreadable library labels get a local text contrast correction", async () => {
  const { textContrastKind } = await import("../src/doc/mermaid");
  expect(textContrastKind("journey\n title Reading", "light")).toBe("journey");
  expect(textContrastKind("journey\n title Reading", "dark")).toBeNull();
  expect(textContrastKind('C4Context\nPerson(a, "A")', "dark")).toBe("c4");
  expect(
    textContrastKind('C4Context\nPerson(a, "A", $fontColor="red")', "dark"),
  ).toBeNull();
  expect(
    textContrastKind(
      'C4Context\nUpdateElementStyle(a, $bgColor="blue")',
      "dark",
    ),
  ).toBeNull();
  expect(textContrastKind("sankey-beta\n A,B,5", "dark")).toBe("sankey");
  expect(textContrastKind("flowchart LR\n A --> B", "dark")).toBeNull();
});
