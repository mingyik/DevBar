import assert from "node:assert/strict";
import test from "node:test";
import { assertTextAlphas, compositeOpaque, loadTokens, renderTokens, resolveColor } from "./gen-tokens.ts";

test("#000000 @ 0.6 叠在 #F2F2F2 上得到 #616161", () => {
  assert.equal(compositeOpaque("#000000", 0.6, "#F2F2F2"), "#616161");
});

test("不透明叠色保持原色", () => {
  assert.equal(compositeOpaque("#1C1C1E", 1, "#F2F2F2"), "#1C1C1E");
});

test("完全透明叠色等于底色", () => {
  assert.equal(compositeOpaque("#000000", 0, "#F2F2F2"), "#F2F2F2");
});

test("文字角色 alpha 低于 0.60 时报错", () => {
  const tokens = loadTokens();
  const role = tokens.light["text.tertiary"];
  if (!role || !("alpha" in role)) {
    throw new Error("缺少 text.tertiary");
  }
  role.alpha = 0.5;
  assert.throws(() => assertTextAlphas(tokens), /text\.tertiary 的 alpha 0\.5 低于 0\.60/);
});

test("当前 tokens 的文字角色不低于 0.60", () => {
  const tokens = loadTokens();
  assert.doesNotThrow(() => assertTextAlphas(tokens));
  assert.equal(resolveColor(tokens, "light", "syntax.comment").alpha, 0.6);
});
test("syntax.keyword 字重改变后 CodeMirror 产物跟着变", () => {
  const tokens = structuredClone(loadTokens());
  const role = tokens.light["syntax.keyword"];
  if (!role || !("weight" in role)) {
    throw new Error("缺少 syntax.keyword.weight");
  }
  role.weight = 500;
  const highlight = renderTokens(tokens)["Web/src/theme/cm-highlight.ts"] ?? "";
  assert.match(highlight, /500/);
  assert.match(highlight, /tags\.propertyName/);
  assert.match(highlight, /tags\.definition\(tags\.propertyName\)/);
});

test("黑主题引用与白主题不同时 Swift 按主题解析", () => {
  const tokens = structuredClone(loadTokens());
  const role = tokens.dark["syntax.string"];
  if (!role || !("ref" in role)) {
    throw new Error("缺少 syntax.string.ref");
  }
  role.ref = "text.primary";
  const swift = renderTokens(tokens)["Sources/DevBar/Generated/DesignTokens.swift"] ?? "";
  assert.match(swift, /func syntaxString\(_ scheme: ColorScheme\)[\s\S]*?case \.dark:\s*return textPrimary\(scheme\)/);
});

test("JSON 键映射到 CodeMirror propertyName 和 Shiki property-name", () => {
  const files = renderTokens(loadTokens());
  const highlight = files["Web/src/theme/cm-highlight.ts"] ?? "";
  const shiki = files["Web/src/theme/shiki-devbar-light.json"] ?? "";
  assert.match(highlight, /tags\.propertyName/);
  assert.match(highlight, /tags\.definition\(tags\.propertyName\)/);
  assert.match(shiki, /support\.type\.property-name/);
  assert.match(shiki, /meta\.object-literal\.key/);
});

test("Mermaid 使用库主题，不生成灰阶覆盖", () => {
  assert.equal(renderTokens(loadTokens())["Web/src/theme/mermaid-vars.ts"], undefined);
});
