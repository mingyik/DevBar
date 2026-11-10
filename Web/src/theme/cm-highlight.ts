// 自动生成，勿手改。来源：design/tokens.json
import { HighlightStyle } from "@codemirror/language";
import { tags } from "@lezer/highlight";

export const devbarHighlightStyle = HighlightStyle.define([
  { tag: tags.keyword, color: "var(--syntax-keyword)", fontWeight: "600" },
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
