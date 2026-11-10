import js from "@eslint/js";
import prettier from "eslint-config-prettier";
import tseslint from "typescript-eslint";
import devbarRestrictions from "./eslint-rules/devbar-restrictions.js";

export default tseslint.config(
  { ignores: ["dist/**", "node_modules/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["src/**/*.ts"],
    plugins: {
      devbar: {
        rules: {
          restrictions: devbarRestrictions,
        },
      },
    },
    rules: {
      "devbar/restrictions": "error",
    },
  },
  prettier,
);
