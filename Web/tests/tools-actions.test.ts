import { expect, it } from "vitest";
import {
  actionLabels,
  routeImport,
  decodedRanges,
} from "../src/tools/json/actions";
import { childPath, copyValue, summary } from "../src/tree/model";
import { parse } from "lossless-json";
it("labels are conservative actions and never modify text", () => {
  expect(actionLabels("hello", "url")).toEqual({
    escape: "escape",
    codec: "encode",
  });
  expect(actionLabels('\\"a\\"', "url").escape).toBe("unescape");
  expect(actionLabels('"hello"', "url").escape).toBe("unescape");
  expect(actionLabels("%G1", "url").codec).toBe("encode");
  expect(actionLabels("%41", "url").codec).toBe("decode");
  expect(actionLabels("aGVsbG8=", "base64").codec).toBe("decode");
  expect(actionLabels("AAECAwQFBgc=", "base64").codec).toBe("encode");
});
it("routing has a single JSON destination and only changes the encoding submode", () => {
  expect(routeImport("https://a.test")).toEqual({
    page: "json",
    encoding: "url",
  });
  expect(routeImport("aGVsbG8=")).toEqual({ page: "json", encoding: "base64" });
  expect(routeImport("1700000000")).toEqual({ page: "json", encoding: "url" });
});
it("decoder annotations map original byte errors into the rewritten document", () => {
  expect(decodedRanges("%41%FF%42%G1")).toEqual({
    text: "A%FFB%G1",
    errors: [
      { start: 1, end: 4 },
      { start: 5, end: 8 },
    ],
  });
});
it("tree values preserve number spelling and special-key paths", () => {
  const value = parse('{"id":1234567890123456789,"f":1.0,"e":1e10}') as Record<
    string,
    unknown
  >;
  expect(copyValue(value.id)).toBe("1234567890123456789");
  expect(copyValue(value.f)).toBe("1.0");
  expect(summary(value.e)).toBe("1e10");
  expect(copyValue("emoji😀")).toBe("emoji😀");
  expect(childPath("$", 'user "name\\')).toBe('$["user \\"name\\\\"]');
  expect(childPath("$.items", 3)).toBe("$.items[3]");
  expect(copyValue(true)).toBe("true");
  expect(copyValue(null)).toBe("null");
});
