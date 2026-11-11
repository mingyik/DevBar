import { describe, expect, it } from "vitest";
import { scrollThumb } from "../src/styles/readonly-scroll";
describe("read-only scroll indicator geometry", () => {
  it("hides non-scrollable and invalid geometry", () => {
    for (const [v, c, o] of [
      [0, 20, 0],
      [20, 20, 0],
      [30, 20, 0],
      [20, NaN, 0],
      [20, 30, Infinity],
    ])
      expect(scrollThumb(v, c, o)).toBeNull();
  });
  it("is proportional and clamps overscroll", () => {
    expect(scrollThumb(100, 400, 150)).toEqual({ length: 25, position: 37.5 });
    expect(scrollThumb(100, 400, -20)?.position).toBe(0);
    expect(scrollThumb(100, 400, 900)?.position).toBe(75);
    expect(scrollThumb(100, 10000, 0)?.length).toBe(20);
  });
});
