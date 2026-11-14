import { describe, expect, it } from "vitest";
import { isDirty, nextDisplayMode } from "../src/doc/mode";
import { isCurrentDocumentMessage } from "../src/doc/state";

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

describe("split editor document identity", () => {
  it("accepts only updates from the currently opened document", () => {
    expect(isCurrentDocumentMessage("doc-a", "doc-a")).toBe(true);
    expect(isCurrentDocumentMessage(null, null)).toBe(true);
    expect(isCurrentDocumentMessage("doc-b", "doc-a")).toBe(false);
    expect(isCurrentDocumentMessage("doc-b", null)).toBe(false);
  });
});
