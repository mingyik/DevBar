import { RuleTester } from "eslint";
import { describe, it } from "vitest";
import rule from "../eslint-rules/devbar-restrictions.js";

RuleTester.describe = describe;
RuleTester.it = it;

const tester = new RuleTester({
  languageOptions: {
    ecmaVersion: 2022,
    sourceType: "module",
  },
});

const tools = "src/tools/sample.ts";
const tree = "src/tree/sample.ts";
const editor = "src/editor/sample.ts";
const envelope = "src/bridge/envelope.ts";

tester.run("devbar/restrictions", rule, {
  valid: [
    {
      name: "tools 允许 setTimeout 传函数回调",
      filename: tools,
      code: "setTimeout(() => {}, 0);",
    },
    {
      name: "tools 允许 setInterval 传函数回调",
      filename: tools,
      code: "setInterval(function () {}, 10);",
    },
    {
      name: "editor 允许 JSON.parse",
      filename: editor,
      code: 'export const value = JSON.parse("1");',
    },
    {
      name: "editor 允许 JSON 静态计算属性和解构",
      filename: editor,
      code: 'const { parse } = JSON; export const value = JSON["stringify"](1);',
    },
    {
      name: "envelope 允许 JSON.parse",
      filename: envelope,
      code: 'export const value = JSON.parse("1");',
    },
    {
      name: "envelope 允许 JSON 解构",
      filename: envelope,
      code: "const { stringify } = JSON; export const write = stringify;",
    },
    {
      name: "tools 允许普通对象的 parse",
      filename: tools,
      code: 'const url = { parse(text) { return text; } }; export const value = url.parse("a");',
    },
    {
      name: "tools 允许从普通对象解构 parse",
      filename: tools,
      code: "const url = { parse(text) { return text; } }; const { parse } = url;",
    },
  ],
  invalid: [
    {
      name: "tools 禁止点属性 JSON.parse",
      filename: tools,
      code: 'export const a = JSON.parse("1");',
      errors: [{ messageId: "json" }],
    },
    {
      name: 'tools 禁止静态计算属性 JSON["stringify"]',
      filename: tools,
      code: 'export const b = JSON["stringify"](1);',
      errors: [{ messageId: "json" }],
    },
    {
      name: "tools 禁止 JSON.parse 方法引用",
      filename: tools,
      code: "export const f = JSON.parse;",
      errors: [{ messageId: "json" }],
    },
    {
      name: "tools 禁止从 JSON 解构 parse",
      filename: tools,
      code: "const { parse } = JSON;",
      errors: [{ messageId: "json" }],
    },
    {
      name: "tree 禁止从 JSON 解构并重命名 stringify",
      filename: tree,
      code: "const { stringify: write } = JSON;",
      errors: [{ messageId: "json" }],
    },
    {
      name: "tree 禁止赋值解构 JSON.parse",
      filename: tree,
      code: "let parse; ({ parse } = JSON);",
      errors: [{ messageId: "json" }],
    },
    {
      name: "tools 禁止 setTimeout 字符串字面量",
      filename: tools,
      code: 'setTimeout("alert(1)", 0);',
      errors: [{ messageId: "setTimeoutString" }],
    },
    {
      name: "tools 禁止 setInterval 模板字符串",
      filename: tools,
      code: "setInterval(`alert(1)`, 0);",
      errors: [{ messageId: "setTimeoutString" }],
    },
    {
      name: "tools 禁止 window.setTimeout 模板字符串",
      filename: tools,
      code: "window.setTimeout(`alert(1)`, 0);",
      errors: [{ messageId: "setTimeoutString" }],
    },
    {
      name: "tools 禁止 Function 调用",
      filename: tools,
      code: 'export const f = Function("return 1");',
      errors: [{ messageId: "functionConstructor" }],
    },
    {
      name: "tools 禁止 new Function",
      filename: tools,
      code: 'export const f = new Function("return 1");',
      errors: [{ messageId: "functionConstructor" }],
    },
    {
      name: "tools 禁止 window.Function 静态计算属性",
      filename: tools,
      code: 'export const f = window["Function"]("return 1");',
      errors: [{ messageId: "functionConstructor" }],
    },
    {
      name: "tools 禁止 window.eval",
      filename: tools,
      code: 'export const e = window.eval("1");',
      errors: [{ messageId: "eval" }],
    },
    {
      name: 'tools 禁止 window["eval"]',
      filename: tools,
      code: 'export const e = window["eval"]("1");',
      errors: [{ messageId: "eval" }],
    },
    {
      name: "tools 禁止 globalThis.eval",
      filename: tools,
      code: 'export const e = globalThis.eval("1");',
      errors: [{ messageId: "eval" }],
    },
    {
      name: "tools 禁止 window.fetch",
      filename: tools,
      code: 'export const d = window.fetch("x");',
      errors: [{ messageId: "network" }],
    },
    {
      name: 'tools 禁止 globalThis["fetch"]',
      filename: tools,
      code: 'export const d = globalThis["fetch"]("x");',
      errors: [{ messageId: "network" }],
    },
    {
      name: 'tools 禁止 new window["XMLHttpRequest"]',
      filename: tools,
      code: 'export const x = new window["XMLHttpRequest"]();',
      errors: [{ messageId: "network" }],
    },
  ],
});
