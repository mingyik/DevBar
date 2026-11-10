import { describe, expect, it } from "vitest";
import { detect } from "../src/tools/detect";
const cases: [string, string][] = [
  ["", "text"],
  ["  ", "text"],
  ["\n", "text"],
  ["hello", "text"],
  ["{}", "json"],
  ["[]", "json"],
  [' {"n":12345678901234567890} ', "json"],
  ["{a:1}", "json"],
  ["[1,]", "json"],
  ["{", "json"],
  ["[", "json"],
  ['{"a":1', "json"],
  ['"{\\"a\\":1}"', "escaped"],
  ['"[]"', "escaped"],
  ['" {} "', "escaped"],
  ['"hello"', "text"],
  ['"{bad"', "text"],
  ['"unterminated', "text"],
  ["https://example.com", "url"],
  ["custom+v1://Host/a", "url"],
  ["file:///tmp/a", "url"],
  ["http://a b", "text"],
  ["example.com", "text"],
  ["1abc://host", "text"],
  ["https://", "text"],
  ["http:/a", "text"],
  ["1700000000", "timestamp"],
  ["1700000000123", "timestamp"],
  ["1700000000123456", "timestamp"],
  ["1000000000", "timestamp"],
  ["4102444799999999", "timestamp"],
  ["9999999999", "text"],
  ["4102444800", "text"],
  ["0946684799", "text"],
  ["17000000000", "text"],
  ["-1700000000", "text"],
  ["aGVsbG8gd29ybGQ=", "base64"],
  ["aGVsbG8gd29ybGQ", "base64"],
  ["aGVs bG8g\nd29ybGQ=", "base64"],
  ["5Lit5paH", "base64"],
  ["YWJj", "text"],
  ["AAECAwQFBgc=", "text"],
  ["////////", "text"],
  ["abcd-_+/", "text"],
  ["aGVsbG8===", "text"],
  ["========", "text"],
  ["aGVsbG8!", "text"],
  ["true", "text"],
  ["null", "text"],
  ["123", "text"],
];
describe("spec detection", () => {
  it.each(cases)("%s → %s", (input, type) => {
    const r = detect(input);
    expect(type === "escaped" ? r.hint : r.type).toBe(
      type === "escaped" ? "escapedJson" : type,
    );
  });
  it("distinguishes valid, repairable and invalid without changing input", () => {
    expect(detect("{}").json).toBe("valid");
    expect(detect("{a:1}").json).toBe("repairable");
    expect(detect('{"x":\\uZZZZ}').json).toBe("invalid");
  });
});
it.each(["8J-YgA==", "aAkKYg=="])(
  "readable URL-safe or whitespace payload %s",
  (s) => expect(detect(s).type).toBe("base64"),
);
it("unreadable URL-safe payload stays text", () =>
  expect(detect("________").type).toBe("text"));
