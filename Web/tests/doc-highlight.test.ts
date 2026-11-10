import { expect, it } from "vitest";
import { highlightCode, getHighlighter, languages } from "../src/doc/highlight";
it("reuses one highlighter", async () =>
  expect(await getHighlighter()).toBe(await getHighlighter()));
it.each(["js", "ts", "sh", "bash", "zsh", "yml", "md", "py", "kt"])(
  "alias %s",
  async (lang) =>
    expect(await highlightCode("const x = 1", lang, "light")).toContain(
      'class="shiki',
    ),
);
it("unknown language falls back with escaped source", async () =>
  expect(
    await highlightCode("<img onerror=x>", "not-a-language", "light"),
  ).toBe('<pre class="code plain"><code>&lt;img onerror=x&gt;</code></pre>'));
it("dark and light use generated themes", async () => {
  expect(await highlightCode('const x = "a"; // c', "js", "dark")).not.toBe(
    await highlightCode('const x = "a"; // c', "js", "light"),
  );
});

it.each(languages)("supported language %s", async (lang) => {
  expect(await highlightCode("value = 1", lang, "light")).toContain(
    'class="shiki',
  );
});
