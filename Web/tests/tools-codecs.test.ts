import { expect, it } from "vitest";
import { encode, decode } from "../src/tools/base64";
it.each(["", "hello", "中文😀", "line\ntext"])("base64 roundtrip %s", (s) =>
  expect(decode(encode(s))).toEqual({ kind: "text", text: s }),
);
it.each(["aGVsbG8=", "aGVsbG8", " aGVs\nbG8= "])("accepts %s", (s) =>
  expect(decode(s)).toEqual({ kind: "text", text: "hello" }),
);
it("binary retains byte size", () =>
  expect(decode("/w==")).toEqual({ kind: "binary", bytes: 1 }));
it.each(["a", "===", "aa=a", "ab+_", "aGVsbG8==="])("invalid %s", (s) =>
  expect(decode(s).kind).toBe("invalid"),
);
it("URL safe utf8", () =>
  expect(decode("8J-YgA")).toEqual({ kind: "text", text: "😀" }));
