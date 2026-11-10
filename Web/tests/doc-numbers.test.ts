import { expect, it } from "vitest";
import { isNumericColumn } from "../src/doc/tables";
it.each(
  [
    ["007", "12345678901234567890"],
    ["-2", "+3.14", ""],
    ["1,234.50", "-0.5%"],
  ].map((cells) => ({ cells })),
)("numeric columns only add layout hints %s", ({ cells }) =>
  expect(isNumericColumn(cells, false)).toBe(true),
);
it.each(
  [
    ["", " "],
    ["1", "word"],
    ["1e10", "2"],
    ["1,23", "4"],
    [".5", "2"],
  ].map((cells) => ({ cells })),
)("mixed or empty columns %s", ({ cells }) =>
  expect(isNumericColumn(cells, false)).toBe(false),
);
it("explicit alignment takes precedence", () =>
  expect(isNumericColumn(["1", "2"], true)).toBe(false));
