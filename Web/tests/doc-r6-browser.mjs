/* global document, window, getComputedStyle, Image, atob */
import assert from "node:assert/strict";
import process from "node:process";
import console from "node:console";
import { writeFileSync } from "node:fs";
const { chromium } = await import(
  process.env.DEVBAR_PLAYWRIGHT_MODULE ?? "playwright"
);
const browser = await chromium.launch({ headless: true, channel: "chromium" });
const results = {
  colors: {},
  metrics: {},
  layouts: {},
  security: null,
  png: null,
  svgChecks: null,
};
try {
  const page = await browser.newPage({
    viewport: { width: 420, height: 560 },
    deviceScaleFactor: 2,
  });
  page.on("pageerror", (e) => console.log("page error", e.message));
  await page.route("**/*", (route) =>
    route.request().url().startsWith("http://127.0.0.1:5173/")
      ? route.continue()
      : route.abort(),
  );
  for (const theme of ["light", "dark"])
    for (const size of ["normal", "large"]) {
      await page.setViewportSize({
        width: size === "large" ? 600 : 420,
        height: size === "large" ? 700 : 560,
      });
      await page.goto(
        `http://127.0.0.1:5173/dev/r6-preview.html?theme=${theme}&size=${size}`,
      );
      await page.waitForFunction(() => window.ready, {}, { timeout: 120000 });
      results.metrics[theme + "-" + size] = await page.evaluate(
        () => window.metrics,
      );
      const colors = await page.evaluate(() =>
        Array.from(document.querySelectorAll(".mmd")).map((card) => {
          const svg = card.querySelector("svg");
          const colors = new Set();
          if (svg)
            for (const element of [svg, ...svg.querySelectorAll("*")])
              for (const property of [
                "fill",
                "stroke",
                "color",
                "stop-color",
              ]) {
                const value =
                  getComputedStyle(element).getPropertyValue(property);
                const match = /rgba?\(([^)]+)\)/.exec(value);
                if (match) {
                  const channels = match[1]
                    .split(/[, ]+/)
                    .slice(0, 3)
                    .map(Number);
                  if (Math.max(...channels) - Math.min(...channels) > 3)
                    colors.add(value);
                }
              }
          return {
            name: card.previousElementSibling?.textContent,
            colors: [...colors],
            defaultTextVisible: ["图表 journey", "图表 C4"].includes(
              card.previousElementSibling?.textContent,
            )
              ? Array.from(svg.querySelectorAll("text, text *")).every(
                  (text) =>
                    getComputedStyle(text).fill ===
                    getComputedStyle(card).color,
                )
              : true,
            error: card.classList.contains("mmd-error"),
            foreignObjects: svg?.querySelectorAll("foreignObject").length ?? 0,
          };
        }),
      );
      if (size === "normal") results.colors[theme] = colors;
      await page.screenshot({
        path: `../Screenshots/R6/${theme}-${size}.png`,
        fullPage: true,
      });
    }
  assert.equal(await page.locator("pre.shiki").count(), 10);
  results.svgChecks = await page.evaluate(async () => {
    const { normalizeSvg, renderMermaid } = await import("/src/doc/mermaid.ts");
    const svg = normalizeSvg(
      '<svg viewBox="0 0 320 200" width="100%" style="max-width:320px"></svg>',
    );
    let rejected = false;
    try {
      normalizeSvg('<svg viewBox="0 0 0 0"></svg>');
    } catch {
      rejected = true;
    }
    const source = "flowchart LR\n A-->B";
    return {
      svg,
      rejected,
      cacheIdentical:
        (await renderMermaid(source, "dark")) ===
        (await renderMermaid(source, "dark")),
      csp: document.querySelector('meta[http-equiv="Content-Security-Policy"]')
        .content,
    };
  });
  assert.ok(results.svgChecks.svg.includes('width="320"'));
  assert.ok(!results.svgChecks.svg.includes("max-width"));
  assert.ok(results.svgChecks.rejected && results.svgChecks.cacheIdentical);
  assert.ok(!results.svgChecks.csp.includes("unsafe-eval"));
  results.security = await page.evaluate(async () => {
    const { loadMermaid, mermaidOptions } = await import("/src/doc/mermaid.ts");
    const m = await loadMermaid();
    const options = mermaidOptions("light");
    const samples = {
      frontmatter:
        '---\nconfig:\n  theme: forest\n  look: handDrawn\n  fontFamily: Comic\n  darkMode: true\n  htmlLabels: true\n  themeCSS: "rect{fill:red}"\n  themeVariables:\n    primaryColor: red\n---\nflowchart LR\n A-->B',
      directive:
        "%%{init: {theme: 'forest', look: 'handDrawn',fontFamily:'Comic',darkMode:true,htmlLabels:true,themeCSS:'rect{fill:red}',themeVariables:{primaryColor:'red'}}}%%\nflowchart LR\n A-->B",
    };
    const output = {};
    for (const [key, source] of Object.entries(samples)) {
      m.initialize(options);
      await m.parse(source);
      const config = m.mermaidAPI.getConfig();
      output[key] = {
        theme: config.theme,
        look: config.look,
        fontFamily: config.fontFamily,
        darkMode: config.darkMode,
        htmlLabels: config.htmlLabels,
        themeCSS: config.themeCSS,
        primaryColor: config.themeVariables.primaryColor,
      };
    }
    return output;
  });
  for (const type of ["flowchart", "state"])
    for (const layout of ["dagre", "elk"]) {
      const box = await page.evaluate(
        async ({ type, layout }) => {
          const { renderMermaid } = await import("/src/doc/mermaid.ts");
          const source =
            type === "flowchart"
              ? "flowchart LR\n subgraph Group\n A-->B\n A-->C\n end\n B-->D\n C-->D"
              : "stateDiagram-v2\n [*]-->Idle\n Idle-->Ready\n Ready-->Working\n Ready-->Error\n Working-->Ready\n Error-->Idle";
          const root = document.querySelector("#preview");
          root.innerHTML = '<div class="mmd"></div>';
          root.firstChild.innerHTML = await renderMermaid(
            source,
            "dark",
            layout,
          );
          const svg = root.querySelector("svg");
          return {
            width: svg.getAttribute("width"),
            height: svg.getAttribute("height"),
          };
        },
        { type, layout },
      );
      results.layouts[type + "-" + layout] = box;
      await page
        .locator("#preview")
        .screenshot({ path: `../Screenshots/R6/layout-${type}-${layout}.png` });
    }
  results.png = await page.evaluate(async () => {
    const { renderMermaid, svgToPngBase64 } =
      await import("/src/doc/mermaid.ts");
    const svg = await renderMermaid("flowchart LR\n A-->B", "dark");
    const bytes = await svgToPngBase64(svg, "dark");
    const raw = Uint8Array.from(atob(bytes), (c) => c.charCodeAt(0));
    const view = new DataView(raw.buffer);
    const image = new Image();
    image.src = "data:image/png;base64," + bytes;
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = image.width;
    canvas.height = image.height;
    const ctx = canvas.getContext("2d");
    ctx.drawImage(image, 0, 0);
    return {
      prefix: bytes.slice(0, 12),
      length: bytes.length,
      width: view.getUint32(16),
      height: view.getUint32(20),
      alpha: ctx.getImageData(0, 0, 1, 1).data[3],
    };
  });
  await page.goto("http://127.0.0.1:5173/dev/r6-preview.html?mode=mermaid");
  await page.waitForFunction(() => window.ready, {}, { timeout: 120000 });
  assert.equal(await page.locator(".mmd > svg").count(), 1);
  writeFileSync(
    "../Samples/R6-browser-results.json",
    JSON.stringify(results, null, 2) + "\n",
  );
  for (const [theme, cards] of Object.entries(results.colors))
    for (const card of cards) {
      assert.equal(card.foreignObjects, 0);
      assert.equal(
        card.defaultTextVisible,
        true,
        theme + " " + card.name + " text contrast",
      );
      if (card.name === "图表 error") assert.equal(card.error, true);
      else assert.equal(card.error, false, theme + " " + card.name);
      if (card.name !== "图表 explicit-color")
        assert.deepEqual(card.colors, [], theme + " " + card.name);
      else assert.ok(card.colors.length > 0);
    }
  for (const security of Object.values(results.security)) {
    assert.equal(security.theme, "base");
    assert.equal(security.look, "neo");
    assert.equal(security.htmlLabels, false);
    assert.equal(security.darkMode, false);
    assert.notEqual(security.fontFamily, "Comic");
    assert.notEqual(security.themeCSS, "rect{fill:red}");
    assert.notEqual(security.primaryColor, "red");
  }
  assert.ok(results.png.prefix.startsWith("iVBORw0KGgo"));
  assert.equal(results.png.alpha, 255);
  assert.ok(results.png.width > 0 && results.png.height > 0);
  console.log("R6 browser checks passed", results.metrics);
} finally {
  await browser.close();
}
