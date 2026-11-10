import { expect, it } from "vitest";
import { mermaidOptions } from "../src/doc/mermaid";
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
  expect(mermaidOptions("light", "dagre").layout).toBe("dagre");
  expect(mermaidOptions("dark", "elk").layout).toBe("elk");
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
