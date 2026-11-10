import assert from "node:assert/strict";
import test from "node:test";
import { findSwiftColorViolations } from "./check-swift-colors.ts";

const blocked = [
  "let a = Color( red: 1, green: 0, blue: 0)",
  "let b = Color(white: 0.5)",
  "let c = NSColor(white: 0.5, alpha: 1)",
  "let d = Color(.sRGB, red: 1, green: 0, blue: 0)",
  "let e = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)",
  "let f = Color(hue: 0.5, saturation: 1, brightness: 1)",
  "let g = Color(\n    red: 1,\n    green: 0,\n    blue: 0\n)",
  '#expect(Color(red: 1, green: 0, blue: 0) == x)',
  'let hex = "#fff"',
  'let wide = "#112233"',
  'let alpha = "#11223344"',
];

for (const [index, source] of blocked.entries()) {
  test(`拦截颜色写法 ${index + 1}`, () => {
    assert.ok(findSwiftColorViolations(source).length > 0, source);
  });
}

test("带允许标记的行不报", () => {
  const source = 'let a = Color(red: 1, green: 0, blue: 0) // devbar:allow-color\nlet hex = "#fff" // devbar:allow-color';
  assert.equal(findSwiftColorViolations(source).length, 0);
});

test("语义色和普通宏不误报", () => {
  const source = ["let a = Color.primary", "let b = NSColor.labelColor", "#expect(true)", "#available(macOS 15, *)"].join("\n");
  assert.equal(findSwiftColorViolations(source).length, 0);
});

test("宏和颜色在同一行仍拦截颜色", () => {
  const hits = findSwiftColorViolations('#expect(text == "#aabbcc")');
  assert.equal(hits.length, 1);
  assert.equal(hits[0]?.line, 1);
});
