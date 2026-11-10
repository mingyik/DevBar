import { expect, test } from "vitest";
import { entryName } from "../src/main.ts";

test("空白入口可被测试工具链加载", () => {
  expect(entryName).toBe("DevBar");
});
