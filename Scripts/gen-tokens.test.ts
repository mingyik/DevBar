import assert from "node:assert/strict";
import test from "node:test";
import { assertTextAlphas, compositeOpaque, loadTokens, resolveColor } from "./gen-tokens.ts";

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
