import { expect, it } from "vitest";
import { parse, isLosslessNumber } from "lossless-json";
import {
  format,
  compact,
  repair,
  analyze,
  positionFromError,
  escapeJsonString,
  unescapeJsonString,
  copyValue,
} from "../src/tools/json/core.ts";
export const original =
  '{"big":12345678901234567890,"decimal":1.0,"exp":1e10,"negative":-0,"fraction":0.1000}';
const numbers = ["12345678901234567890", "1.0", "1e10", "-0", "0.1000"];
it("spec lossless chain: paste, compact, format, copy value, escape, unescape, undo, copy", () => {
  const history = [original];
  const steps = [format(original)];
  steps.push(compact(steps.at(-1)!));
  steps.push(format(steps.at(-1)!));
  const object = parse(steps.at(-1)!) as Record<string, unknown>;
  expect(Object.values(object).map(copyValue)).toEqual(numbers);
  steps.push(copyValue(object));
  steps.push(escapeJsonString(steps.at(-1)!));
  steps.push(unescapeJsonString(steps.at(-1)!));
  steps.push(history[0]); // Model undo by restoring the immutable pre-transform snapshot.
  steps.push(steps.at(-1)!); // Model clipboard copy as reading the current string unchanged.
  for (const text of steps) {
    const decoded = text.startsWith('"') ? unescapeJsonString(text) : text;
    const values = Object.values(parse(decoded) as Record<string, unknown>);
    expect(values.every(isLosslessNumber)).toBe(true);
    expect(values.map(copyValue)).toEqual(numbers);
  }
  expect(steps.at(-1)).toBe(original);
});
it("numeric keys have fixed JS enumeration order", () =>
  expect(compact('{"z":0,"10":1.0,"2":1e10,"01":-0}')).toBe(
    '{"2":1e10,"10":1.0,"z":0,"01":-0}',
  ));
it("repair only on explicit request, preserves numeric lexemes", () => {
  const input = "{a:12345678901234567890,b:1.0,}";
  expect(analyze(input).state).toBe("repairable");
  expect(compact(repair(input))).toBe('{"a":12345678901234567890,"b":1.0}');
  expect(input).toBe("{a:12345678901234567890,b:1.0,}");
});
it("invalid and valid states", () => {
  expect(analyze('{"x":\\uZZZZ}').state).toBe("invalid");
  expect(analyze(original)).toEqual({ state: "valid" });
});
it.each([
  "中文😀",
  '"\\\b\f\n\r\t',
  String.fromCharCode(...Array.from({ length: 32 }, (_, i) => i)),
  "\ud800",
  "\udc00",
  "a/b",
])("escape roundtrip %s", (s) =>
  expect(unescapeJsonString(escapeJsonString(s))).toBe(s),
);
it("escaping exact short forms and unicode unchanged", () =>
  expect(escapeJsonString('中文😀\u0001\n"\\')).toBe(
    '"中文😀\\u0001\\n\\"\\\\"',
  ));
it.each([
  ['"\\uD83D\\uDE00"', "😀"],
  ['{\\"a\\":1}', '{"a":1}'],
  ['"\\/"', "/"],
  ["  bare  ", "  bare  "],
  ['  "a"  ', "a"],
])("unescape %s", (s, w) => expect(unescapeJsonString(s)).toBe(w));
it.each(['"\\x"', '"\\uZZZZ"', '"a\nb"', '"a"b"', "abc\\"])(
  "bad string %s",
  (s) => {
    expect(() => unescapeJsonString(s)).toThrow();
    try {
      unescapeJsonString(s);
    } catch (e) {
      expect(positionFromError(e, s)).not.toBeNull();
    }
  },
);
it.each(['{"a":}', "[1,]", "{", '"bad\\x"', '{\n "😀": @\n}'])(
  "real parser error position %s",
  (s) => {
    const result = analyze(s);
    expect(result.state).not.toBe("valid");
    if (result.state !== "valid") {
      expect(result.error.offset).toBeGreaterThanOrEqual(0);
      expect(result.error.offset).toBeLessThanOrEqual(s.length);
    }
  },
);
it("error adapter handles properties, messages, CRLF and unknown errors", () => {
  const text = "a\r\n😀@";
  expect(
    positionFromError(new Error("Unexpected character at position 5"), text),
  ).toEqual({ offset: 5, line: 2, column: 3 });
  expect(positionFromError({ position: 3 }, text)).toEqual({
    offset: 3,
    line: 2,
    column: 1,
  });
  expect(
    positionFromError(new Error("Unexpected end of input"), text)?.offset,
  ).toBe(text.length);
  expect(positionFromError(new Error("at line 2 column 3"), text)?.offset).toBe(
    5,
  );
  expect(positionFromError(new Error("unknown"), text)).toBeNull();
});
it("copy strings and primitives with no quotation or coercion", () => {
  expect(copyValue("中文")).toBe("中文");
  expect(copyValue(true)).toBe("true");
  expect(copyValue(null)).toBe("null");
});
it("a lone quote is not a complete string literal", () =>
  expect(() => unescapeJsonString('"')).toThrow());
it("relative errors reject out-of-line columns", () =>
  expect(
    positionFromError(new Error("at line 2 column 50"), "a\r\nb"),
  ).toBeNull());
it("repair errors retain original input in the worker protocol", async () => {
  const { execute } = await import("../src/tools/json/protocol.ts");
  const input = '{"x":\\uZZZZ}';
  expect(execute({ operation: "repair", text: input }).text).toBe(input);
  expect(execute({ operation: "repair", text: input }).status).toBe("error");
});
it("real parser offset maps CRLF and emoji in UTF-16 exactly", () => {
  const text = '{\r\n "😀": @\r\n}';
  const result = analyze(text);
  expect(result.state).not.toBe("valid");
  if (result.state !== "valid")
    expect(result.error).toMatchObject({
      offset: text.indexOf("@"),
      line: 2,
      column: 8,
    });
});
