/* global document, window, MouseEvent */
import assert from "node:assert/strict";
import process from "node:process";
import console from "node:console";
const { chromium } = await import(
  process.env.DEVBAR_PLAYWRIGHT_MODULE ?? "playwright"
);
const browser = await chromium.launch({ headless: true, channel: "chromium" });
let externalRequests = 0;
try {
  const page = await browser.newPage({
    viewport: { width: 420, height: 560 },
    deviceScaleFactor: 2,
  });
  await page.route("**/*", (route) => {
    const url = route.request().url();
    if (url.startsWith("http://127.0.0.1:5173/")) return route.continue();
    if (url.startsWith("devbar:") || url.startsWith("data:"))
      return route.abort();
    externalRequests++;
    return route.abort();
  });
  await page.goto("http://127.0.0.1:5173/dev/doc-preview.html");
  await page.waitForFunction(() => window.docPreviewReady === true);
  const result = await page.evaluate(async () => {
    const { createMarkdownPreview, bindPreviewLinks } =
      await import("/src/doc/preview.ts");
    const preview = createMarkdownPreview();
    const render = (text) => {
      const root = document.createElement("div");
      root.innerHTML = preview.render(text);
      return root;
    };
    const unsafe = render(
      '<script>window.pwned=1</script><input type="image" src="https://invalid.example/input"><img src="https://invalid.example/a" onerror="window.pwned=1"><img src="data:image/png;base64,AA=="><img src="devbar://app/a.png"><a href="javascript:alert(1)">bad</a><p style="background:url(https://invalid.example/a)" onclick="alert(1)">text</p>',
    );
    const tasks = render("- [x] done\n- [ ] pending");
    const table = render(
      "| N | Left | Empty |\n| --- | :--- | --- |\n| 007 | 007 | |\n| 12345678901234567890 | -3 | |",
    );
    const fence = render(
      '```mermaid\nA["<script>"]\n```\n\n```js\nconst x = "<img>";\n```',
    );
    const links = render("[link](https://example.com)");
    document.body.append(links);
    let opened = "";
    const dispose = bindPreviewLinks(links, (url) => {
      opened = url;
    });
    const ordinary = new MouseEvent("click", {
      bubbles: true,
      cancelable: true,
    });
    links.querySelector("a").dispatchEvent(ordinary);
    const noJump = ordinary.defaultPrevented && opened === "";
    links.querySelector("a").dispatchEvent(
      new MouseEvent("click", {
        bubbles: true,
        cancelable: true,
        metaKey: true,
      }),
    );
    dispose();
    links.remove();
    return {
      noUnsafe: !unsafe.querySelector(
        'script,[onerror],[onclick],[style],a[href^="javascript:"]',
      ),
      images: unsafe.querySelectorAll("img").length,
      imageSources: Array.from(unsafe.querySelectorAll("img")).map((image) =>
        image.getAttribute("src"),
      ),
      noOtherSource: !unsafe.querySelector("input[src]"),
      placeholder: unsafe.querySelector(".external-image")?.textContent,
      tasks: tasks.querySelectorAll("input[type=checkbox][disabled]").length,
      numeric: Array.from(table.querySelectorAll("tbody tr")).map((r) => [
        r.cells[0].textContent,
        r.cells[0].classList.contains("num"),
        r.cells[1].classList.contains("num"),
        r.cells[1].classList.contains("align-left"),
        r.cells[2].classList.contains("num"),
      ]),
      wrap: !!table.querySelector(".table-wrap > table"),
      diagram: fence.querySelector(".mmd")?.getAttribute("data-src"),
      plain: fence.querySelector("pre.code.plain code")?.textContent,
      noJump,
      opened,
      cache: preview.render("same") === preview.render("same"),
    };
  });
  assert.equal(result.noUnsafe, true);
  assert.equal(result.images, 2);
  assert.deepEqual(result.imageSources, [
    "data:image/png;base64,AA==",
    "devbar://app/a.png",
  ]);
  assert.equal(result.noOtherSource, true);
  assert.match(result.placeholder, /外部图片未加载/);
  assert.equal(result.tasks, 2);
  assert.deepEqual(result.numeric, [
    ["007", true, false, true, false],
    ["12345678901234567890", true, false, true, false],
  ]);
  assert.equal(result.wrap, true);
  assert.equal(result.diagram, 'A["<script>"]\n');
  assert.equal(result.plain, 'const x = "<img>";\n');
  assert.equal(result.noJump, true);
  assert.equal(result.opened, "https://example.com");
  assert.equal(result.cache, true);
  for (const theme of ["light", "dark"])
    for (const size of ["normal", "large"]) {
      await page.setViewportSize({
        width: size === "large" ? 600 : 420,
        height: size === "large" ? 700 : 560,
      });
      await page.goto(
        `http://127.0.0.1:5173/dev/doc-preview.html?theme=${theme}&size=${size}`,
      );
      await page.waitForFunction(() => window.docPreviewReady === true);
      await page.evaluate(() => document.fonts.ready);
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= window.innerWidth,
        ),
        true,
        "page must not overflow; tables scroll inside containers",
      );
      await page.screenshot({
        path: `../Screenshots/R5/${theme}-${size}.png`,
        fullPage: true,
      });
    }
  assert.equal(
    externalRequests,
    0,
    "preview must issue no external image requests",
  );
  console.log(
    "Browser assertions passed; four 2x screenshots saved; external requests:",
    externalRequests,
  );
} finally {
  await browser.close();
}
