import { expect, it } from "vitest";
import { BoundedTextCache } from "../src/bounded-text-cache";

it("bounds Mermaid text cache by entry count and estimated UTF-16 bytes", () => {
  const cache = new BoundedTextCache(2, 128);
  cache.set("a", "one");
  cache.set("b", "two");
  expect(cache.get("a")).toBe("one");
  cache.set("c", "three");
  expect(cache.get("a")).toBeUndefined();
  expect(cache.get("b")).toBe("two");
  const byteLimited = new BoundedTextCache(10, 16);
  byteLimited.set("a", "one");
  byteLimited.set("b", "two");
  byteLimited.set("c", "three");
  expect(byteLimited.get("a")).toBeUndefined();
  expect(byteLimited.get("b")).toBeUndefined();
  expect(byteLimited.get("c")).toBe("three");
  byteLimited.set("large", "0123456789");
  expect(byteLimited.get("c")).toBe("three");
  expect(byteLimited.get("large")).toBeUndefined();
  byteLimited.set("d", "four");
  byteLimited.clear();
  expect(byteLimited.get("d")).toBeUndefined();
});

it("disposes the Shiki highlighter and recreates it after memory flush", async () => {
  const { getHighlighter, releaseHighlighter } =
    await import("../src/doc/highlight");
  const theme = "devbar-tomorrow-dark";
  const first = await getHighlighter();
  expect(first.getLoadedLanguages()).toContain("json");
  expect(first.getLoadedThemes()).toContain(theme);
  await releaseHighlighter();
  expect(() => first.codeToHtml("{}", { lang: "json", theme })).toThrow(
    /disposed/i,
  );
  const second = await getHighlighter();
  expect(second).not.toBe(first);
  await releaseHighlighter();
});
