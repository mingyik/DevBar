import { parse } from "lossless-json";
import { jsonrepair } from "jsonrepair";
import { decode } from "./base64";
import { timestamp } from "./timestamp";
export type Detection = {
  type: "json" | "url" | "base64" | "timestamp" | "text";
  json?: "valid" | "repairable" | "invalid";
  hint?: "escapedJson";
};
export function detect(text: string): Detection {
  const t = text.trim();
  if (!t) return { type: "text" };
  if (/^[{[]/.test(t)) {
    try {
      parse(t);
      return { type: "json", json: "valid" };
    } catch {
      try {
        parse(jsonrepair(t));
        return { type: "json", json: "repairable" };
      } catch {
        const tail = t.slice(1).trimStart();
        const structured =
          t[0] === "{"
            ? /^["'}]/.test(tail) || t.split(/\r?\n/, 1)[0].includes(":")
            : /^[{[\]"'0-9tfn-]/.test(tail);
        return structured
          ? { type: "json", json: "invalid" }
          : { type: "text" };
      }
    }
  }
  if (t.startsWith('"') && t.endsWith('"')) {
    try {
      const value: unknown = parse(t);
      if (typeof value === "string" && /^[{[]/.test(value.trim())) {
        parse(value);
        return { type: "text", hint: "escapedJson" };
      }
    } catch {
      /* A hint must be certain. */
    }
  }
  if (/^[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s]+$/.test(t)) return { type: "url" };
  if (timestamp(t, "UTC")) return { type: "timestamp" };
  const compact = t.replace(/\s/g, "");
  if (compact.length >= 8 && !/^[A-Z]?[a-z]+$/.test(compact)) {
    const result = decode(t);
    if (
      result.kind === "text" &&
      !Array.from(result.text).some(
        (c) =>
          (c.charCodeAt(0) >= 128 && c.charCodeAt(0) <= 159) ||
          (c.charCodeAt(0) < 32 && ![9, 10, 13].includes(c.charCodeAt(0))),
      )
    )
      return { type: "base64" };
  }
  return { type: "text" };
}
