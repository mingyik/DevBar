import { RuleTester } from "eslint";
import { describe, it } from "vitest";
import rule, { textParser } from "../eslint-rules/no-literal-color.js";

RuleTester.describe = describe;
RuleTester.it = it;

const tester = new RuleTester();
const css = { languageOptions: { parser: textParser } };

tester.run("devbar/no-literal-color", rule, {
  valid: [
    {
      name: "业务代码允许 CSS 变量",
      filename: "src/styles/probe.ts",
      code: 'export const color = "var(--text-primary)";',
    },
    {
      name: "生成的 tokens.css 不检查",
      filename: "src/theme/tokens.css",
      code: "a { color: #fff; }",
      ...css,
    },
    {
      name: "生成的 mermaid 变量不检查",
      filename: "src/theme/mermaid-vars.ts",
      code: 'export const color = "#fff";',
    },
    {
      name: "带允许标记的行不报",
      filename: "src/editor/probe.ts",
      code: 'export const color = "#fff"; // devbar:allow-color',
    },
  ],
  invalid: [
    {
      name: "ts 禁止 #fff",
      filename: "src/editor/probe.ts",
      code: 'export const color = "#fff";',
      errors: [{ messageId: "literal" }],
    },
    {
      name: "ts 禁止 rgb",
      filename: "src/editor/probe.ts",
      code: 'export const color = "rgb(0, 0, 0)";',
      errors: [{ messageId: "literal" }],
    },
    {
      name: "css 禁止 #fff",
      filename: "src/styles/probe.css",
      code: "a { color: #fff; }",
      errors: [{ messageId: "literal" }],
      ...css,
    },
    {
      name: "css 禁止 rgba",
      filename: "src/styles/probe.css",
      code: "a { color: rgba(0, 0, 0, 0.5); }",
      errors: [{ messageId: "literal" }],
      ...css,
    },
    {
      name: "css 禁止 hsl",
      filename: "src/styles/probe.css",
      code: "a { color: hsl(0 0% 0%); }",
      errors: [{ messageId: "literal" }],
      ...css,
    },
  ],
});
