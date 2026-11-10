import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export type ColorHit = { line: number; column: number; text: string };

const ALLOW = "devbar:allow-color";
const COLOR_PARAMS =
  "(?:red|white|hue|gray|genericGrayGamma2_2Gray|srgbRed|displayP3Red|calibratedRed|calibratedWhite|deviceRed|deviceWhite)";
const CONSTRUCTOR = new RegExp(
  `\\b(?:Color|NSColor|CGColor)\\s*\\(\\s*(?:\\.(?:sRGB|displayP3)\\b|${COLOR_PARAMS}\\s*:)`,
  "g",
);
const INIT_CALL = new RegExp(
  `\\.init\\s*\\(\\s*(?:\\.(?:sRGB|displayP3)\\b|${COLOR_PARAMS}\\s*:)`,
  "g",
);
const COLOR_CALL = /\b(?:rgba?|hsla?)\s*\(|#colorLiteral\b/g;
const HEX_IN_STRING = /#(?:[\da-fA-F]{8}|[\da-fA-F]{6}|[\da-fA-F]{4}|[\da-fA-F]{3})(?![\da-fA-F])/g;

function lineAt(source: string, index: number): { line: number; column: number; text: string } {
  let line = 1;
  let start = 0;
  for (let cursor = 0; cursor < index; cursor += 1) {
    if (source[cursor] === "\n") {
      line += 1;
      start = cursor + 1;
    }
  }
  const end = source.indexOf("\n", index);
  return {
    line,
    column: index - start + 1,
    text: source.slice(start, end === -1 ? source.length : end),
  };
}

function allowed(source: string, start: number, end: number): boolean {
  const from = lineAt(source, start).line;
  const to = lineAt(source, Math.max(start, end - 1)).line;
  const lines = source.split("\n");
  for (let line = from; line <= to; line += 1) {
    if ((lines[line - 1] ?? "").includes(ALLOW)) {
      return true;
    }
  }
  return false;
}

function push(hits: ColorHit[], source: string, index: number, length: number): void {
  if (allowed(source, index, index + length)) {
    return;
  }
  const place = lineAt(source, index);
  hits.push({ line: place.line, column: place.column, text: place.text.trim() });
}

function stringRanges(source: string): Array<{ start: number; end: number }> {
  const ranges: Array<{ start: number; end: number }> = [];
  let cursor = 0;
  while (cursor < source.length) {
    if (source.startsWith('"""', cursor)) {
      const close = source.indexOf('"""', cursor + 3);
      const end = close === -1 ? source.length : close + 3;
      ranges.push({ start: cursor, end });
      cursor = end;
      continue;
    }
    if (source[cursor] !== '"') {
      cursor += 1;
      continue;
    }
    let end = cursor + 1;
    while (end < source.length) {
      if (source[end] === "\\") {
        end += 2;
        continue;
      }
      if (source[end] === '"') {
        end += 1;
        break;
      }
      if (source[end] === "\n") {
        break;
      }
      end += 1;
    }
    ranges.push({ start: cursor, end });
    cursor = end;
  }
  return ranges;
}

export function findSwiftColorViolations(source: string): ColorHit[] {
  const hits: ColorHit[] = [];
  for (const pattern of [CONSTRUCTOR, INIT_CALL, COLOR_CALL]) {
    pattern.lastIndex = 0;
    for (const match of source.matchAll(pattern)) {
      push(hits, source, match.index ?? 0, match[0].length);
    }
  }
  for (const range of stringRanges(source)) {
    const body = source.slice(range.start, range.end);
    HEX_IN_STRING.lastIndex = 0;
    for (const match of body.matchAll(HEX_IN_STRING)) {
      push(hits, source, range.start + (match.index ?? 0), match[0].length);
    }
  }
  return hits;
}

function swiftFiles(dir: string, out: string[]): void {
  for (const name of readdirSync(dir)) {
    if (name === "Generated") {
      continue;
    }
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      swiftFiles(path, out);
      continue;
    }
    if (name.endsWith(".swift")) {
      out.push(path);
    }
  }
}

function main(): void {
  const root = join(dirname(fileURLToPath(import.meta.url)), "..");
  const files: string[] = [];
  for (const dir of ["Sources", "Tests"]) {
    swiftFiles(join(root, dir), files);
  }
  const lines: string[] = [];
  for (const path of files) {
    const source = readFileSync(path, "utf8");
    for (const hit of findSwiftColorViolations(source)) {
      lines.push(`${path}:${hit.line}:${hit.column}: ${hit.text}`);
    }
  }
  if (lines.length > 0) {
    console.error(lines.join("\n"));
    console.error("业务代码出现字面颜色（Generated/ 与 design/ 除外；行内 // devbar:allow-color 可放行）");
    process.exit(1);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main();
}
