/* global window, document, performance, requestAnimationFrame, KeyboardEvent */
import process from "node:process";
import { writeFileSync } from "node:fs";
import assert from "node:assert/strict";
import console from "node:console";
const { chromium } = await import(process.env.DEVBAR_PLAYWRIGHT_MODULE);
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage({ viewport: { width: 448, height: 536 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("http://127.0.0.1:5188/dev/tools-preview.html");
  await page.waitForFunction(() => window.__devbar && window.testView);
  const send = (type, payload) =>
    page.evaluate(
      ({ type, payload }) =>
        window.__devbar.receive(
          JSON.stringify({ v: 1, id: "test", type, payload }),
        ),
      { type, payload },
    );
  const text = () =>
    page.evaluate(() => window.testView().state.doc.toString());
  const paste = (value) =>
    page.evaluate((value) => {
      const view = window.testView();
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: value },
        userEvent: "input.paste",
      });
    }, value);
  await send("settings.set", { autoImport: false });
  const original = '{"id":1234567890123456789,"decimal":1.0,"text":"中文"}';
  await paste(original);
  await page.waitForFunction(() => window.testView().state.doc.lines > 1);
  assert((await text()).includes("1234567890123456789"));
  assert((await text()).includes("1.0"));
  await page.locator("#tools .cm-content").focus();
  await page.keyboard.press("Meta+z");
  assert.equal(await text(), original);
  await page.keyboard.press("Meta+Shift+z");
  assert((await text()).includes("\n"));
  await page.getByRole("button", { name: "JSON", exact: true }).click();
  assert.equal(await text(), original);
  await page.keyboard.press("Meta+e");
  await page.locator(".tree-row").first().waitFor();
  const rows = await page.locator(".tree-row").count();
  assert.equal(rows, 4);
  const before = await page.locator(".tree-children").count();
  await page.locator(".tree-value").first().click();
  assert.equal(await page.locator(".tree-children").count(), before);
  await page
    .locator(".tree-buttons button")
    .filter({ hasText: "复制值" })
    .nth(1)
    .dispatchEvent("click");
  assert.equal(
    await page.evaluate(
      () =>
        window.testMessages
          .filter((m) => m.type === "clipboard.writeText")
          .at(-1).payload.text,
    ),
    "1234567890123456789",
  );
  await send("tools.import", { text: '{"a":1,}', mode: "replace" });
  await page.waitForFunction(() =>
    document.querySelector("#tools .page-error"),
  );
  assert.equal(await text(), '{"a":1,}');
  assert.equal(
    await page.getByRole("button", { name: "修复", exact: true }).count(),
    0,
  );
  assert(
    await page.getByRole("button", { name: "JSON", exact: true }).isDisabled(),
  );
  await page.keyboard.press("Meta+e");
  assert.equal(await text(), '{"a":1,}');
  assert(await page.locator("#tools .preview").isHidden());
  await send("tools.import", {
    text: "https://example.com/a%20b?x=1",
    mode: "replace",
  });
  await page.getByRole("button", { name: "解码", exact: true }).waitFor();
  await page.keyboard.press("Meta+e");
  assert.equal(await page.locator(".url-table").count(), 1);
  await send("tools.import", { text: "%41%FF%42", mode: "replace" });
  await page.getByRole("button", { name: "解码", exact: true }).click();
  assert.equal(await text(), "A%FFB");
  await page.waitForTimeout(500);
  assert((await page.locator(".page-error").count()) > 0);
  await send("tools.import", { text: "SGVsbG8gd29ybGQ=", mode: "replace" });
  await page.getByRole("button", { name: "解码", exact: true }).click();
  assert.equal(await text(), "Hello world");
  await page.getByRole("button", { name: "编码", exact: true }).click();
  assert.equal(await text(), "Hello%20world");
  const many = "[" + Array.from({ length: 600 }, (_, i) => i).join(",") + "]";
  await send("tools.import", { text: many, mode: "replace" });
  await page.keyboard.press("Meta+e");
  assert.equal(await page.locator(".tree-row").count(), 201);
  await page.locator(".tree-more").click();
  assert.equal(await page.locator(".tree-row").count(), 401);
  assert.equal(await page.locator("#tools .page-fixed button").count(), 1);
  assert.equal(
    await page.getByRole("button", { name: "长图", exact: true }).count(),
    0,
  );
  assert.equal(
    await page.locator("#tools select, #tools .codec-segment").count(),
    0,
  );
  // The 2 MiB fixture has 200 large leaves, so the DOM bound is independent of bytes.
  const large =
    "{" +
    Array.from(
      { length: 200 },
      (_, i) => '"key' + i + '":"' + "a".repeat(10475) + '"',
    ).join(",") +
    "}";
  await send("tools.import", { text: large, mode: "replace" });
  const timing = await page.evaluate(async () => {
    const start = performance.now();
    document.dispatchEvent(
      new KeyboardEvent("keydown", { key: "e", metaKey: true, bubbles: true }),
    );
    while (document.querySelector("#tools .preview").hidden)
      await new Promise(requestAnimationFrame);
    return performance.now() - start;
  });
  assert(timing < 300, `2MiB preview ${timing}ms exceeds 300ms`);
  assert.equal(errors.length, 0, errors.join("\n"));
  const report = {
    checks: 16,
    bytes: large.length,
    previewMilliseconds: timing,
    treeRows: await page.locator(".tree-row").count(),
    errors,
  };
  writeFileSync(
    process.env.DEVBAR_R8_OUTPUT ?? "/tmp/devbar-r8-web-result.json",
    JSON.stringify(report, null, 2) + "\n",
  );
  console.log(report);
} finally {
  await browser.close();
}
