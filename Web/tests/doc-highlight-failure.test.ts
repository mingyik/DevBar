import { expect, it, vi } from "vitest";
vi.mock("shiki/core", () => ({
  createHighlighterCore: vi.fn().mockRejectedValue(new Error("unavailable")),
}));
import { highlightCode } from "../src/doc/highlight";
it("creation failure falls back and warns once without user content", async () => {
  const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
  try {
    expect(await highlightCode("<private>", "js", "light")).toContain(
      "&lt;private&gt;",
    );
    expect(await highlightCode("secret", "python", "dark")).toContain(
      "<code>secret</code>",
    );
    expect(warn).toHaveBeenCalledExactlyOnceWith("代码高亮不可用，已显示原文");
  } finally {
    warn.mockRestore();
  }
});
