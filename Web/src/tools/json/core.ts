import { parse, stringify } from "lossless-json";
import { jsonrepair } from "jsonrepair";

export type Position = { offset: number; line: number; column: number };
export type Diagnostic = Position & { message: string };
export type Analysis =
  { state: "valid" } | { state: "repairable" | "invalid"; error: Diagnostic };

function location(text: string, offset: number): Position {
  let line = 1,
    column = 1;
  for (let i = 0; i < offset; i++) {
    if (text[i] === "\r") {
      if (text[i + 1] === "\n" && i + 1 < offset) i++;
      line++;
      column = 1;
    } else if (text[i] === "\n") {
      line++;
      column = 1;
    } else column++;
  }
  return { offset, line, column };
}
/** Offsets/columns use UTF-16, matching editor positions. Unknown formats return null. */
export function positionFromError(
  error: unknown,
  text: string,
): Position | null {
  const data =
    typeof error === "object" && error !== null
      ? (error as Record<string, unknown>)
      : {};
  const message = typeof data.message === "string" ? data.message : "";
  let offset =
    typeof data.position === "number"
      ? data.position
      : typeof data.offset === "number"
        ? data.offset
        : undefined;
  const absolute = /\b(?:at\s+)?position\s+(\d+)\b/i.exec(message);
  if (offset === undefined && absolute) offset = Number(absolute[1]);
  if (offset === undefined) {
    const relative = /\bline\s+(\d+)\s+(?:and\s+)?column\s+(\d+)/i.exec(
      message,
    );
    if (relative) {
      const line = Number(relative[1]),
        column = Number(relative[2]);
      let currentLine = 1;
      let start = 0;
      for (let i = 0; i <= text.length; i++) {
        if (i === text.length || text[i] === "\r" || text[i] === "\n") {
          if (currentLine === line) {
            const candidate = start + column - 1;
            if (column >= 1 && candidate <= i) offset = candidate;
            break;
          }
          if (text[i] === "\r" && text[i + 1] === "\n") i++;
          start = i + 1;
          currentLine++;
        }
      }
    }
  }
  if (
    offset === undefined &&
    /unexpected end|end of (?:input|data)/i.test(message)
  )
    offset = text.length;
  return offset !== undefined && Number.isInteger(offset) && offset >= 0
    ? location(text, Math.min(offset, text.length))
    : null;
}
export function diagnostic(error: unknown, text: string): Diagnostic {
  return {
    ...(positionFromError(error, text) ?? location(text, 0)),
    message: error instanceof Error ? error.message : "转换失败",
  };
}
function serialize(value: unknown, space?: number): string {
  const text = stringify(value, null, space);
  if (text === undefined) throw new TypeError("无法序列化该值");
  return text;
}
export function format(text: string): string {
  return serialize(parse(text), 2);
}
export function compact(text: string): string {
  return serialize(parse(text));
}
/** Only call after an explicit repair action; analysis never returns replacement text. */
export function repair(text: string): string {
  return format(jsonrepair(text));
}
export function analyze(text: string): Analysis {
  try {
    parse(text);
    return { state: "valid" };
  } catch (error) {
    let state: "repairable" | "invalid" = "invalid";
    try {
      parse(jsonrepair(text));
      state = "repairable";
    } catch {
      /* Keep the original parse diagnostic. */
    }
    return { state, error: diagnostic(error, text) };
  }
}
/** Same copy semantics as the future read-only tree, without UI or clipboard access. */
export function copyValue(value: unknown): string {
  return typeof value === "string" ? value : serialize(value, 2);
}

export function escapeJsonString(text: string): string {
  const short: Record<string, string> = {
    '"': '\\"',
    "\\": "\\\\",
    "\b": "\\b",
    "\f": "\\f",
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
  };
  let out = '"';
  for (const char of text) {
    const code = char.charCodeAt(0);
    out +=
      short[char] ??
      (code < 32 ? "\\u" + code.toString(16).padStart(4, "0") : char);
  }
  return out + '"';
}
class StringSyntaxError extends SyntaxError {
  readonly position: number;
  constructor(position: number) {
    super("字符串转义无效");
    this.position = position;
  }
}
export function unescapeJsonString(text: string): string {
  const trimmed = text.trim();
  const quoted = trimmed.startsWith('"') && trimmed.endsWith('"');
  const source = quoted ? trimmed : '"' + text + '"';
  const origin = quoted ? text.indexOf(trimmed) : -1;
  const fail = (i: number): never => {
    throw new StringSyntaxError(Math.max(0, Math.min(text.length, i + origin)));
  };
  if (source.length < 2) fail(0);
  let out = "";
  for (let i = 1; i < source.length - 1; i++) {
    const char = source[i];
    if (char === '"' || char.charCodeAt(0) < 32) fail(i);
    if (char !== "\\") {
      out += char;
      continue;
    }
    const start = i;
    const escaped = source[++i];
    if (i >= source.length - 1) fail(start);
    const short: Record<string, string> = {
      '"': '"',
      "\\": "\\",
      "/": "/",
      b: "\b",
      f: "\f",
      n: "\n",
      r: "\r",
      t: "\t",
    };
    if (escaped in short) {
      out += short[escaped];
      continue;
    }
    if (escaped !== "u") fail(i);
    const digits = source.slice(i + 1, i + 5);
    if (
      digits.length !== 4 ||
      !/^[0-9a-f]{4}$/i.test(digits) ||
      i + 4 >= source.length - 1
    )
      fail(i);
    // UTF-16 code units preserve paired and lone surrogates without numeric coercion.
    out += String.fromCharCode(Number.parseInt(digits, 16));
    i += 4;
  }
  return out;
}
