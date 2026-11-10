import {
  analyze,
  compact,
  diagnostic,
  escapeJsonString,
  format,
  repair,
  unescapeJsonString,
} from "./core.ts";
import type { Analysis, Diagnostic } from "./core.ts";
export type Operation =
  "format" | "compact" | "repair" | "analyze" | "escape" | "unescape";
export type Request = { operation: Operation; text: string };
export type Result =
  | { status: "success"; text: string; analysis?: Analysis }
  | { status: "error"; text: string; error: Diagnostic }
  | { status: "cancelled"; text: string };
export function execute(request: Request): Result {
  const { operation, text } = request;
  try {
    if (operation === "analyze")
      return { status: "success", text, analysis: analyze(text) };
    const operations = {
      format,
      compact,
      repair,
      escape: escapeJsonString,
      unescape: unescapeJsonString,
    };
    return { status: "success", text: operations[operation](text) };
  } catch (error) {
    return { status: "error", text, error: diagnostic(error, text) };
  }
}
