import { describe, expect, it } from "vitest";
import { isDirty, nextDisplayMode } from "../src/doc/mode";

describe("Markdown display modes", () => {
  it("cycles edit, preview, side-by-side", () => {
    expect(nextDisplayMode("source")).toBe("preview");
    expect(nextDisplayMode("preview")).toBe("split");
    expect(nextDisplayMode("split")).toBe("source");
  });
});

describe("Markdown save state", () => {
  it("tracks edits against the last saved text", () => {
    expect(isDirty("abc", "abc")).toBe(false);
    expect(isDirty("abc\n", "abc")).toBe(true);
    expect(isDirty("", "abc")).toBe(true);
  });

  it("stays dirty when editing during a save", () => {
    const saved = "first line";
    const editedDuringSave = "first line\nsecond line";
    expect(isDirty(editedDuringSave, saved)).toBe(true);
    expect(isDirty(saved, saved)).toBe(false);
  });

  it("returns to clean when undo restores the saved text", () => {
    const saved = "# 标题\n原文";
    expect(isDirty("# 标题\n修改", saved)).toBe(true);
    expect(isDirty(saved, saved)).toBe(false);
  });
});
