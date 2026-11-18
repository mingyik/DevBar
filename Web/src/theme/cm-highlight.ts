// 自动生成，勿手改。来源：design/tokens.json
import { HighlightStyle } from "@codemirror/language";
import { tags } from "@lezer/highlight";

export const devbarHighlightStyle = HighlightStyle.define([
  {
    tag: [tags.keyword, tags.propertyName, tags.definition(tags.propertyName)],
    color: "var(--syntax-keyword)",
    fontWeight: "600",
  },
  { tag: tags.string, color: "var(--syntax-string)" },
  {
    tag: tags.number,
    color: "var(--syntax-number)",
    fontVariantNumeric: "tabular-nums",
  },
  {
    tag: [tags.bool, tags.null, tags.atom],
    color: "var(--syntax-constant)",
    fontStyle: "italic",
  },
  { tag: tags.comment, color: "var(--syntax-comment)", fontStyle: "italic" },
  { tag: tags.punctuation, color: "var(--syntax-punct)" },
]);

export const devbarMarkdownHighlightStyle = HighlightStyle.define([
  {
    tag: [
      tags.heading,
      tags.heading1,
      tags.heading2,
      tags.heading3,
      tags.heading4,
      tags.heading5,
      tags.heading6,
    ],
    color: "var(--markdown-editor-heading)",
  },
  { tag: [tags.link, tags.url], color: "var(--markdown-editor-link)" },
  { tag: tags.strong, color: "var(--markdown-editor-strong)" },
  { tag: tags.emphasis, color: "var(--markdown-editor-emphasis)" },
  { tag: tags.monospace, color: "var(--markdown-editor-inline-code)" },
  { tag: tags.processingInstruction, color: "var(--markdown-editor-marker)" },
]);
