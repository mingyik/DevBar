import { expect, it } from "vitest";
import { encode, decode } from "../src/tools/base64";
import { timestamp } from "../src/tools/timestamp";
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
it("microseconds exact with explicit timezone", () => {
  const r = timestamp("1700000000123456", "Asia/Shanghai");
  expect(r?.local).toBe("2023-11-15 06:13:20.123456");
  expect(r?.utc).toBe("2023-11-14 22:13:20.123456 UTC");
  expect(r?.iso).toBe("2023-11-15T06:13:20.123456+08:00");
});
it("UTC and milliseconds", () =>
  expect(timestamp("1700000000123", "UTC")?.iso).toBe(
    "2023-11-14T22:13:20.123+00:00",
  ));
it.each(["9466848000", "4102444800", "123", "-1700000000"])(
  "rejects timestamp %s",
  (s) => expect(timestamp(s, "UTC")).toBeNull(),
);
it("lower bound", () =>
  expect(timestamp("0946684800", "UTC")?.utc).toBe("2000-01-01 00:00:00 UTC"));
it("negative offset and DST use supplied timezone", () =>
  expect(timestamp("1700000000", "America/New_York")?.iso).toBe(
    "2023-11-14T17:13:20-05:00",
  ));
it("microsecond trailing zeroes survive", () =>
  expect(timestamp("1700000000000000", "UTC")?.iso).toBe(
    "2023-11-14T22:13:20.000000+00:00",
  ));
