/* global atob, document, setTimeout, getComputedStyle */
import process from "node:process";
import console from "node:console";
const { chromium } = await import(
  process.env.DEVBAR_PLAYWRIGHT_MODULE ?? "playwright"
);
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
const browser = await chromium.launch({ headless: true, channel: "chromium" });
try {
  const page = await browser.newPage();
  await page.goto("http://127.0.0.1:5187/dev/doc-preview.html");
  const result = await page.evaluate(async () => {
    const { renderMermaid, svgToPngBase64 } =
      await import("/src/doc/mermaid.ts");
    const samples = [
      'C4Context\nPerson(user, "User", $fontColor="red")',
      'C4Context\nPerson(user, "User")\nSystem(sys, "System")\nRel(user, sys, "Uses", $lineColor="red")',
    ];
    const c4 = [];
    for (const theme of ["light", "dark"])
      for (const source of samples) {
        try {
          const svg = await renderMermaid(source, theme);
          c4.push({
            theme,
            authorColorRetained: /red|rgb\(255,\s*0,\s*0\)/.test(svg),
          });
        } catch (e) {
          c4.push({ theme, error: String(e) });
        }
      }
    const encoded = await svgToPngBase64(
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 30"><rect width="40" height="30"/></svg>',
      "light",
    );
    const binary = atob(encoded);
    const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
    const view = new DataView(bytes.buffer);
    let oversized = false;
    try {
      await svgToPngBase64('<svg viewBox="0 0 8000 8000"></svg>', "light");
    } catch {
      oversized = true;
    }
    const { installReadOnlyScrollbars } =
      await import("/src/styles/readonly-scroll.ts");
    installReadOnlyScrollbars(document);
    const owner = document.createElement("div");
    owner.style.cssText =
      "position:fixed;top:0;left:0;width:100px;height:100px;overflow:auto";
    const body = document.createElement("div");
    body.style.cssText = "height:800px;width:400px";
    owner.append(body);
    document.body.append(owner);
    owner.scrollTop = 40;
    await new Promise((resolve) => setTimeout(resolve, 320));
    const indicator = document.querySelector(".devbar-scroll-thumb.vertical");
    const shown = indicator && getComputedStyle(indicator);
    const scrollbar = {
      width: shown?.width,
      pointerEvents: shown?.pointerEvents,
      visible: Number(shown?.opacity) > 0.9,
    };
    await new Promise((resolve) => setTimeout(resolve, 850));
    scrollbar.hiddenAfterIdle =
      Number(getComputedStyle(indicator).opacity) === 0;
    owner.scrollTop = 80;
    await new Promise((resolve) => setTimeout(resolve, 50));
    owner.hidden = true;
    await new Promise((resolve) => setTimeout(resolve, 30));
    scrollbar.removedOnPageHide = !indicator.isConnected;
    owner.remove();
    return {
      scrollbar,
      c4,
      png: {
        width: view.getUint32(16),
        height: view.getUint32(20),
        oversizedRejected: oversized,
      },
    };
  });
  writeFileSync(
    "../docs/验证记录/R7-网页回归.json",
    JSON.stringify(result, null, 2),
  );
  assert.deepEqual(result.scrollbar, {
    width: "3px",
    pointerEvents: "none",
    visible: true,
    hiddenAfterIdle: true,
    removedOnPageHide: true,
  });
  assert.ok(
    result.c4.every((r) => r.authorColorRetained),
    JSON.stringify(result),
  );
  assert.deepEqual(result.png, {
    width: 80,
    height: 60,
    oversizedRejected: true,
  });
  console.log(JSON.stringify(result));
} finally {
  await browser.close();
}
