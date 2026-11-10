import js from "@eslint/js";
import prettier from "eslint-config-prettier";
import tseslint from "typescript-eslint";
import devbarRestrictions from "./eslint-rules/devbar-restrictions.js";
import noLiteralColor, { textParser } from "./eslint-rules/no-literal-color.js";

const devbarPlugin = {
  rules: {
    restrictions: devbarRestrictions,
    "no-literal-color": noLiteralColor,
  },
};

export default tseslint.config(
  { ignores: ["dist/**", "node_modules/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["src/**/*.ts"],
    plugins: { devbar: devbarPlugin },
    rules: {
      "devbar/restrictions": "error",
      "devbar/no-literal-color": "error",
    },
  },
  {
    files: ["src/**/*.css"],
    languageOptions: { parser: textParser },
    plugins: { devbar: devbarPlugin },
    rules: {
      "devbar/no-literal-color": "error",
    },
  },
  prettier,
);
