import { parse } from "lossless-json";
import { detect } from "../detect";
import { decode as decodeBase64 } from "../base64";
import { decode } from "../url";
export type Encoding = "url" | "base64";
export function actionLabels(text: string, encoding: Encoding) {
  const t = text.trim();
  let unescape = false;
  try {
    unescape = typeof parse(t) === "string";
  } catch {
    unescape = t.includes('\\"');
  }
  return {
    escape: unescape ? ("unescape" as const) : ("escape" as const),
    codec:
      encoding === "url"
        ? /%[0-9a-f]{2}/i.test(text)
          ? ("decode" as const)
          : ("encode" as const)
        : t !== "" && decodeBase64(text).kind === "text"
          ? ("decode" as const)
          : ("encode" as const),
  };
}
export function routeImport(text: string): {
  page: "json";
  encoding: Encoding;
} {
  return {
    page: "json",
    encoding: detect(text).type === "base64" ? "base64" : "url",
  };
}
export function decodedRanges(input: string) {
  const result = decode(input);
  let inputEnd = 0,
    outputEnd = 0;
  const errors = result.errors.map(({ start, end }) => {
    outputEnd += decode(input.slice(inputEnd, start)).text.length;
    const mapped = { start: outputEnd, end: outputEnd + end - start };
    outputEnd = mapped.end;
    inputEnd = end;
    return mapped;
  });
  return { text: result.text, errors };
}
