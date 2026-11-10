const generatedTheme =
  /(?:^|\/)src\/theme\/(?:tokens\.css|cm-highlight\.ts|mermaid-vars\.ts|shiki-devbar-(?:light|dark)\.json)$/;

const colorPatterns = [
  /#(?:[\da-fA-F]{8}|[\da-fA-F]{6}|[\da-fA-F]{4}|[\da-fA-F]{3})(?![\da-fA-F])/g,
  /\brgba?\(/gi,
  /\bhsla?\(/gi,
];

/** @type {import("eslint").Linter.Parser} */
export const textParser = {
  parse(text) {
    return {
      type: "Program",
      body: [],
      sourceType: "script",
      range: [0, text.length],
      loc: {
        start: { line: 1, column: 0 },
        end: { line: 1, column: 0 },
      },
      tokens: [],
      comments: [],
    };
  },
};

/**
 * @param {string} text
 * @param {number} index
 */
function locAt(text, index) {
  let line = 1;
  let column = 0;
  for (let cursor = 0; cursor < index; cursor += 1) {
    if (text[cursor] === "\n") {
      line += 1;
      column = 0;
    } else {
      column += 1;
    }
  }
  return { line, column };
}

/** @type {import("eslint").Rule.RuleModule} */
const noLiteralColor = {
  meta: {
    type: "problem",
    docs: { description: "业务代码禁止字面颜色，生成的 theme 产物除外。" },
    schema: [],
    messages: {
      literal: "禁止字面颜色值，只用 design/tokens.json 生成的变量。",
    },
  },
  create(context) {
    const filename = context.filename.replaceAll("\\", "/");
    if (generatedTheme.test(filename)) {
      return {};
    }
    return {
      Program(node) {
        const text = context.sourceCode.getText();
        for (const pattern of colorPatterns) {
          pattern.lastIndex = 0;
          for (const match of text.matchAll(pattern)) {
            const start = match.index ?? 0;
            const lineStart = text.lastIndexOf("\n", start) + 1;
            const lineEnd = text.indexOf("\n", start);
            const line = text.slice(
              lineStart,
              lineEnd === -1 ? text.length : lineEnd,
            );
            if (line.includes("devbar:allow-color")) {
              continue;
            }
            const end = start + match[0].length;
            context.report({
              node,
              loc: { start: locAt(text, start), end: locAt(text, end) },
              messageId: "literal",
            });
          }
        }
      },
    };
  },
};

export default noLiteralColor;
