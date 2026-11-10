import { expect, it } from "vitest";
import {
  encodeComponent,
  encodeWhole,
  decode,
  preview,
} from "../src/tools/url";
it.each([
  ["中文 😀", "%E4%B8%AD%E6%96%87%20%F0%9F%98%80"],
  ["a+b c", "a%2Bb%20c"],
  ["!'()*", "%21%27%28%29%2A"],
  ["-._~AZ09", "-._~AZ09"],
])("component %s", (s, w) => expect(encodeComponent(s)).toBe(w));
it("whole preserves reserved and escapes once", () =>
  expect(encodeWhole("https://A/a%20b?q=中文+1&x=%zz")).toBe(
    "https://A/a%20b?q=%E4%B8%AD%E6%96%87+1&x=%25zz",
  ));
it.each([
  ["%G1", [{ start: 0, end: 3 }]],
  ["a%2", [{ start: 1, end: 3 }]],
  ["%FF", [{ start: 0, end: 3 }]],
  ["%E4%B8", [{ start: 0, end: 6 }]],
])("bad encoding %s", (s, errors) =>
  expect(decode(s)).toEqual({ text: s, errors }),
);
it("decodes unicode and preserves plus", () =>
  expect(decode("%E4%B8%AD+%F0%9F%98%80").text).toBe("中+😀"));
it("preview preserves spelling and repeated query keys", () =>
  expect(preview("HTTP://u:p@[::1]:80/a/../b?x=a+b&x=c%3Dd#F")).toEqual({
    scheme: "HTTP",
    userinfo: "u:p",
    host: "[::1]",
    port: "80",
    path: "/a/../b",
    query: "x=a+b&x=c%3Dd",
    fragment: "F",
    parameters: [
      { key: "x", value: "a b" },
      { key: "x", value: "c=d" },
    ],
  }));
it("error offsets count UTF-16 units and preserve valid neighbours", () =>
  expect(decode("😀%G1%41")).toEqual({
    text: "😀%G1A",
    errors: [{ start: 2, end: 5 }],
  }));
it("query only splits first equals and preserves empty values", () =>
  expect(preview("x://Host/path?a=b=c&a=&flag")?.parameters).toEqual([
    { key: "a", value: "b=c" },
    { key: "a", value: "" },
    { key: "flag", value: "" },
  ]));
it("does not normalize host or path", () =>
  expect(preview("x://EXAMPLE/a/../b")?.host).toBe("EXAMPLE"));
it("non-url has no preview", () => expect(preview("ordinary text")).toBeNull());
