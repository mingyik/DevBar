import { createHighlighterCore } from "shiki/core";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import light from "shiki/themes/github-light.mjs";
import dark from "shiki/themes/github-dark.mjs";
export type Theme = "light" | "dark";
const aliases: Record<string, string> = {
  js: "javascript",
  ts: "typescript",
  sh: "shellscript",
  bash: "shellscript",
  zsh: "shellscript",
  yml: "yaml",
  md: "markdown",
  py: "python",
  kt: "kotlin",
};
export const languages = [
  "json",
  "javascript",
  "typescript",
  "swift",
  "python",
  "go",
  "java",
  "kotlin",
  "sql",
  "shellscript",
  "yaml",
  "html",
  "css",
  "diff",
  "markdown",
];
let highlighter: ReturnType<typeof createHighlighterCore> | undefined;
let warned = false;
export function getHighlighter() {
  return (highlighter ??= createHighlighterCore({
    themes: [
      { ...light, type: "light" },
      { ...dark, type: "dark" },
    ],
    langs: [
      import("@shikijs/langs/json"),
      import("@shikijs/langs/javascript"),
      import("@shikijs/langs/typescript"),
      import("@shikijs/langs/swift"),
      import("@shikijs/langs/python"),
      import("@shikijs/langs/go"),
      import("@shikijs/langs/java"),
      import("@shikijs/langs/kotlin"),
      import("@shikijs/langs/sql"),
      import("@shikijs/langs/shellscript"),
      import("@shikijs/langs/yaml"),
      import("@shikijs/langs/html"),
      import("@shikijs/langs/css"),
      import("@shikijs/langs/diff"),
      import("@shikijs/langs/markdown"),
    ],
    engine: createJavaScriptRegexEngine(),
  }));
}
export async function releaseHighlighter(): Promise<void> {
  const current = highlighter;
  highlighter = undefined;
  warned = false;
  if (current) await current.then((loaded) => loaded.dispose()).catch(() => {});
}
function escape(text: string) {
  return text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}
export async function highlightCode(
  text: string,
  language: string,
  theme: Theme,
): Promise<string> {
  const lang = aliases[language.toLowerCase()] ?? language.toLowerCase();
  const plain = () =>
    `<pre class="code plain"><code>${escape(text)}</code></pre>`;
  if (!languages.includes(lang)) return plain();
  try {
    const renderer = await getHighlighter();
    return renderer.codeToHtml(text, {
      lang,
      theme: theme === "dark" ? "github-dark" : "github-light",
    });
  } catch {
    if (!warned) {
      console.warn("代码高亮不可用，已显示原文");
      warned = true;
    }
    return plain();
  }
}
