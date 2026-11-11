import { expect, it } from "vitest";
import { mermaidOptions, pngDimensions } from "../src/doc/mermaid";
import { mermaidVars, mermaidDiagramConfig } from "../src/theme/mermaid-vars";
it.each(["light", "dark"] as const)(
  "%s keeps strict security and generated roles",
  (theme) => {
    const options = mermaidOptions(theme);
    expect(options.securityLevel).toBe("strict");
    expect(options.htmlLabels).toBe(false);
    expect(options.theme).toBe("base");
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
    expect(options.themeVariables.primaryColor).toBe(
      mermaidVars[theme].primaryColor,
    );
    expect(options.c4).toEqual(mermaidDiagramConfig[theme].c4);
  },
);
it("layout is selected by the supported root layout option", () => {
  expect(mermaidOptions("light").layout).toBe("dagre");
  expect(mermaidOptions("dark").layout).toBe("dagre");
});
it.each(["light", "dark"] as const)(
  "%s generated palettes contain only neutral colors",
  (theme) => {
    const walk = (value: unknown) => {
      if (typeof value === "string")
        for (const match of value.matchAll(/#([\da-f]{6})/gi)) {
          const channels = [0, 2, 4].map((i) =>
            parseInt(match[1].slice(i, i + 2), 16),
          );
          expect(
            Math.max(...channels) - Math.min(...channels),
          ).toBeLessThanOrEqual(3);
        }
      else if (value && typeof value === "object")
        for (const child of Object.values(value)) walk(child);
    };
    walk(mermaidVars[theme]);
    walk(mermaidDiagramConfig[theme]);
  },
);

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
