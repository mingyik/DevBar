import { expect, it } from "vitest";
import { imageDimensions } from "../src/preview/export";
import { packResult, unpackResult } from "../src/tools/json/transfer";
import { execute } from "../src/tools/json/protocol";
import { copyValue } from "../src/tree/model";
it("checks scaled dimensions and area before allocating PNG", () => {
  expect(imageDimensions(8192, 100)).toEqual({ width: 16384, height: 200 });
  expect(imageDimensions(8193, 100)).toBeNull();
  expect(imageDimensions(4001, 4000)).toBeNull();
  expect(imageDimensions(0, 5)).toBeNull();
  expect(imageDimensions(NaN, 5)).toBeNull();
});
it("worker structured clone retains exact numeric spelling for tree copying", () => {
  const result = unpackResult(
    structuredClone(
      packResult(
        execute({
          operation: "parse",
          text: '{"n":1234567890123456789,"f":1.0}',
        }),
      ),
    ),
  );
  expect(result.status).toBe("success");
  if (result.status === "success") {
    const value = result.value as Record<string, unknown>;
    expect(copyValue(value.n)).toBe("1234567890123456789");
    expect(copyValue(value.f)).toBe("1.0");
  }
});
