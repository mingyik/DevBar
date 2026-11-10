import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export type RGB = { r: number; g: number; b: number };

export type ColorToken = {
  color: string;
  alpha: number;
  highContrast?: number;
};

export type RefToken = {
  ref: string;
  weight?: number;
  italic?: boolean;
  tabular?: boolean;
};

export type Role = ColorToken | RefToken;

export type Scheme = "light" | "dark";

export type Tokens = {
  light: Record<string, Role>;
  dark: Record<string, Role>;
  radius: { small: number; medium: number; large: number; inline: number };
  stroke: { hairline: number; strong: number };
  font: { body: number; bodyLarge: number; lineHeight: number };
  opaqueBackdrop: { light: string; dark: string };
};

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const tokensPath = join(root, "design/tokens.json");
const header = "自动生成，勿手改。来源：design/tokens.json";

const outputs = [
  "Sources/DevBar/Generated/DesignTokens.swift",
  "Web/src/theme/tokens.css",
  "Web/src/theme/cm-highlight.ts",
  "Web/src/theme/shiki-devbar-light.json",
  "Web/src/theme/shiki-devbar-dark.json",
  "Web/src/theme/mermaid-vars.ts",
] as const;

export function parseHex(hex: string): RGB {
  const body = hex.startsWith("#") ? hex.slice(1) : hex;
  const expanded =
    body.length === 3
      ? body
          .split("")
          .map((char) => char + char)
          .join("")
      : body;
  if (!/^[\da-fA-F]{6}$/.test(expanded)) {
    throw new Error(`无法解析颜色 ${hex}`);
  }
  return {
    r: Number.parseInt(expanded.slice(0, 2), 16),
    g: Number.parseInt(expanded.slice(2, 4), 16),
    b: Number.parseInt(expanded.slice(4, 6), 16),
  };
}

export function compositeOpaque(color: string, alpha: number, backdrop: string): string {
  const foreground = parseHex(color);
  const background = parseHex(backdrop);
  const channels = [foreground.r, foreground.g, foreground.b].map((channel, index) => {
    const base = [background.r, background.g, background.b][index] ?? 0;
    return Math.round(channel * alpha + base * (1 - alpha));
  });
  return `#${channels.map((channel) => channel.toString(16).padStart(2, "0")).join("").toUpperCase()}`;
}

export function isTextRole(key: string): boolean {
  return key.startsWith("text.") || key.startsWith("syntax.") || key === "selection.text";
}

export function resolveColor(tokens: Tokens, scheme: Scheme, key: string, seen = new Set<string>()): ColorToken {
  if (seen.has(key)) {
    throw new Error(`颜色引用成环：${key}`);
  }
  seen.add(key);
  const role = tokens[scheme][key];
  if (!role) {
    throw new Error(`缺少角色 ${scheme}.${key}`);
  }
  if ("ref" in role) {
    return resolveColor(tokens, scheme, role.ref, seen);
  }
  return role;
}

export function assertTextAlphas(tokens: Tokens): void {
  for (const scheme of ["light", "dark"] as const) {
    for (const key of Object.keys(tokens[scheme])) {
      if (!isTextRole(key)) {
        continue;
      }
      const color = resolveColor(tokens, scheme, key);
      if (color.alpha < 0.6) {
        throw new Error(`文字角色 ${scheme}.${key} 的 alpha ${color.alpha} 低于 0.60`);
      }
    }
  }
}

export function loadTokens(path = tokensPath): Tokens {
  return JSON.parse(readFileSync(path, "utf8")) as Tokens;
}

function camel(key: string): string {
  return key.replace(/\.([a-z])/g, (_match, char: string) => char.toUpperCase());
}

function cssName(key: string): string {
  return `--${key.replaceAll(".", "-")}`;
}

function rgba(token: ColorToken): string {
  const { r, g, b } = parseHex(token.color);
  return `rgba(${r}, ${g}, ${b}, ${token.alpha})`;
}

function hexWithAlpha(token: ColorToken): string {
  const { r, g, b } = parseHex(token.color);
  if (token.alpha >= 1) {
    return `#${[r, g, b].map((channel) => channel.toString(16).padStart(2, "0")).join("").toUpperCase()}`;
  }
  const alpha = Math.round(token.alpha * 255)
    .toString(16)
    .padStart(2, "0")
    .toUpperCase();
  return `#${[r, g, b].map((channel) => channel.toString(16).padStart(2, "0")).join("").toUpperCase()}${alpha}`;
}

function swiftComponent(value: number): string {
  if (value === 0) {
    return "0";
  }
  if (value === 255) {
    return "1";
  }
  return `${value}.0 / 255`;
}

function swiftColor(token: ColorToken, alpha = token.alpha): string {
  const { r, g, b } = parseHex(token.color);
  return `Color(red: ${swiftComponent(r)}, green: ${swiftComponent(g)}, blue: ${swiftComponent(b)}, opacity: ${alpha})`;
}

function formatSwift(source: string): string {
  const dir = mkdtempSync(join(tmpdir(), "devbar-tokens-"));
  const file = join(dir, "DesignTokens.swift");
  writeFileSync(file, source);
  const result = spawnSync("swift", ["format", "-i", file], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(result.stderr || "swift format 失败");
  }
  const formatted = readFileSync(file, "utf8");
  rmSync(dir, { recursive: true, force: true });
  return formatted;
}
function formatPrettier(filename: string, source: string): string {
  const dir = mkdtempSync(join(tmpdir(), "devbar-tokens-"));
  const file = join(dir, filename);
  writeFileSync(file, source);
  const prettier = join(root, "Web/node_modules/.bin/prettier");
  const result = spawnSync(prettier, ["--write", file], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(result.stderr || "prettier 失败");
  }
  const formatted = readFileSync(file, "utf8");
  rmSync(dir, { recursive: true, force: true });
  return formatted;
}


function renderSwift(tokens: Tokens): string {
  const lines = [
    "// " + header,
    "import AppKit",
    "import SwiftUI",
    "",
    "enum DesignTokens {",
    `  static let radiusSmall: CGFloat = ${tokens.radius.small}`,
    `  static let radiusMedium: CGFloat = ${tokens.radius.medium}`,
    `  static let radiusLarge: CGFloat = ${tokens.radius.large}`,
    `  static let radiusInline: CGFloat = ${tokens.radius.inline}`,
    `  static let strokeHairline: CGFloat = ${tokens.stroke.hairline}`,
    `  static let strokeStrong: CGFloat = ${tokens.stroke.strong}`,
    `  static let fontBody: CGFloat = ${tokens.font.body}`,
    `  static let fontBodyLarge: CGFloat = ${tokens.font.bodyLarge}`,
    `  static let fontLineHeight: CGFloat = ${tokens.font.lineHeight}`,
    "",
    "  struct SyntaxStyle: Sendable {",
    "    let weight: Int?",
    "    let italic: Bool",
    "    let tabular: Bool",
    "  }",
    "",
  ];

  const keys = Object.keys(tokens.light);
  for (const key of keys) {
    const name = camel(key);
    const light = tokens.light[key];
    const dark = tokens.dark[key];
    if (!light || !dark) {
      throw new Error(`白、黑角色不一致：${key}`);
    }
    if ("ref" in light) {
      lines.push(`  static func ${name}(_ scheme: ColorScheme) -> Color {`);
      lines.push(`    ${camel(light.ref)}(scheme)`);
      lines.push("  }");
      lines.push("");
      lines.push(
        `  static let ${name}Style = SyntaxStyle(weight: ${light.weight ?? "nil"}, italic: ${light.italic === true}, tabular: ${light.tabular === true})`,
      );
      lines.push("");
      continue;
    }
    if ("highContrast" in light || "highContrast" in dark) {
      lines.push("  @MainActor");
      lines.push(`  static func ${name}(_ scheme: ColorScheme) -> Color {`);
      lines.push("    let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast");
      lines.push("    switch scheme {");
      lines.push("    case .light:");
      lines.push(
        `      return increaseContrast ? ${swiftColor(light, light.highContrast ?? light.alpha)} : ${swiftColor(light)}`,
      );
      lines.push("    case .dark:");
      lines.push(
        `      return increaseContrast ? ${swiftColor(dark as ColorToken, (dark as ColorToken).highContrast ?? (dark as ColorToken).alpha)} : ${swiftColor(dark as ColorToken)}`,
      );
      lines.push("    @unknown default:");
      lines.push(
        `      return increaseContrast ? ${swiftColor(light, light.highContrast ?? light.alpha)} : ${swiftColor(light)}`,
      );
      lines.push("    }");
      lines.push("  }");
      lines.push("");
      continue;
    }
    lines.push(`  static func ${name}(_ scheme: ColorScheme) -> Color {`);
    lines.push("    switch scheme {");
    lines.push("    case .light:");
    lines.push(`      return ${swiftColor(light)}`);
    lines.push("    case .dark:");
    lines.push(`      return ${swiftColor(dark as ColorToken)}`);
    lines.push("    @unknown default:");
    lines.push(`      return ${swiftColor(light)}`);
    lines.push("    }");
    lines.push("  }");
    lines.push("");
  }

  lines.push("  static func opaqueBackdrop(_ scheme: ColorScheme) -> Color {");
  lines.push("    switch scheme {");
  lines.push("    case .light:");
  lines.push(`      return ${swiftColor({ color: tokens.opaqueBackdrop.light, alpha: 1 })}`);
  lines.push("    case .dark:");
  lines.push(`      return ${swiftColor({ color: tokens.opaqueBackdrop.dark, alpha: 1 })}`);
  lines.push("    @unknown default:");
  lines.push(`      return ${swiftColor({ color: tokens.opaqueBackdrop.light, alpha: 1 })}`);
  lines.push("    }");
  lines.push("  }");
  lines.push("}");
  lines.push("");
  return lines.join("\n");
}

function renderCSS(tokens: Tokens): string {
  const shared = [
    "/* " + header + " */",
    ":root {",
    `  --radius-small: ${tokens.radius.small}px;`,
    `  --radius-medium: ${tokens.radius.medium}px;`,
    `  --radius-large: ${tokens.radius.large}px;`,
    `  --radius-inline: ${tokens.radius.inline}px;`,
    `  --stroke-hairline: ${tokens.stroke.hairline}px;`,
    `  --stroke-strong: ${tokens.stroke.strong}px;`,
    `  --font-body: ${tokens.font.body}px;`,
    `  --font-body-large: ${tokens.font.bodyLarge}px;`,
    `  --font-line-height: ${tokens.font.lineHeight};`,
    "}",
    "",
  ];
  const themes = (["light", "dark"] as const).map((scheme) => {
    const body = Object.keys(tokens[scheme]).map((key) => {
      const color = resolveColor(tokens, scheme, key);
      const lines = [`  ${cssName(key)}: ${rgba(color)};`];
      const role = tokens[scheme][key];
      if (role && "highContrast" in role && role.highContrast !== undefined) {
        lines.push(`  ${cssName(key)}-high-contrast: ${rgba({ ...color, alpha: role.highContrast })};`);
      }
      if (role && "ref" in role) {
        if (role.weight !== undefined) {
          lines.push(`  ${cssName(key)}-weight: ${role.weight};`);
        }
        if (role.italic) {
          lines.push(`  ${cssName(key)}-style: italic;`);
        }
        if (role.tabular) {
          lines.push(`  ${cssName(key)}-variant: tabular-nums;`);
        }
      }
      return lines.join("\n");
    });
    return [`:root[data-theme="${scheme}"] {`, ...body, "}", ""].join("\n");
  });
  return [...shared, ...themes].join("\n");
}

function renderCodeMirror(): string {
  return [
    "// " + header,
    'import { HighlightStyle } from "@codemirror/language";',
    'import { tags } from "@lezer/highlight";',
    "",
    "export const devbarHighlightStyle = HighlightStyle.define([",
    "  { tag: tags.keyword, color: \"var(--syntax-keyword)\", fontWeight: \"600\" },",
    "  { tag: tags.string, color: \"var(--syntax-string)\" },",
    "  {",
    "    tag: tags.number,",
    "    color: \"var(--syntax-number)\",",
    "    fontVariantNumeric: \"tabular-nums\",",
    "  },",
    "  {",
    "    tag: [tags.bool, tags.null, tags.atom],",
    "    color: \"var(--syntax-constant)\",",
    "    fontStyle: \"italic\",",
    "  },",
    "  { tag: tags.comment, color: \"var(--syntax-comment)\", fontStyle: \"italic\" },",
    "  { tag: tags.punctuation, color: \"var(--syntax-punct)\" },",
    "]);",
    "",
  ].join("\n");
}

function shikiSettings(token: ColorToken, role: Role | undefined): { foreground: string; fontStyle?: string } {
  const settings: { foreground: string; fontStyle?: string } = { foreground: hexWithAlpha(token) };
  if (role && "ref" in role) {
    const styles = [role.weight !== undefined && role.weight >= 600 ? "bold" : "", role.italic ? "italic" : ""]
      .filter(Boolean)
      .join(" ");
    if (styles) {
      settings.fontStyle = styles;
    }
  }
  return settings;
}

function renderShiki(tokens: Tokens, scheme: Scheme): string {
  const foreground = resolveColor(tokens, scheme, "text.primary");
  const background = resolveColor(tokens, scheme, "panel.card");
  const scopes: Array<[string, string[]]> = [
    ["syntax.keyword", ["keyword", "storage.type", "storage.modifier"]],
    ["syntax.string", ["string"]],
    ["syntax.number", ["constant.numeric"]],
    ["syntax.constant", ["constant.language", "constant.language.boolean", "constant.language.null"]],
    ["syntax.comment", ["comment"]],
    ["syntax.punct", ["punctuation"]],
  ];
  const theme = {
    comment: header,
    name: `devbar-${scheme}`,
    displayName: scheme === "light" ? "DevBar Light" : "DevBar Dark",
    type: scheme,
    colors: {
      "editor.background": hexWithAlpha(background),
      "editor.foreground": hexWithAlpha(foreground),
    },
    tokenColors: scopes.map(([key, scope]) => ({
      scope,
      settings: shikiSettings(resolveColor(tokens, scheme, key), tokens[scheme][key]),
    })),
  };
  return JSON.stringify(theme, null, 2) + "\n";
}

function grayStep(tokens: Tokens, scheme: Scheme, alpha: number): string {
  const text = resolveColor(tokens, scheme, "text.primary");
  return compositeOpaque(text.color, alpha, tokens.opaqueBackdrop[scheme]);
}

function renderMermaid(tokens: Tokens): string {
  const schemes = (["light", "dark"] as const).map((scheme) => {
    const paint = (key: string) => compositeOpaque(
      resolveColor(tokens, scheme, key).color,
      resolveColor(tokens, scheme, key).alpha,
      tokens.opaqueBackdrop[scheme],
    );
    const vars: Record<string, string> = {
      background: paint("panel.base"),
      primaryColor: paint("panel.card"),
      primaryTextColor: paint("text.primary"),
      primaryBorderColor: paint("line.border"),
      secondaryColor: paint("panel.raised"),
      tertiaryColor: paint("panel.control"),
      lineColor: paint("line.border"),
      textColor: paint("text.primary"),
      mainBkg: paint("panel.card"),
      nodeBorder: paint("line.border"),
      clusterBkg: paint("panel.control"),
      clusterBorder: paint("line.border"),
      noteBkgColor: paint("panel.raised"),
      noteTextColor: paint("text.primary"),
      noteBorderColor: paint("line.border"),
      actorBkg: paint("panel.card"),
      actorBorder: paint("line.border"),
      actorTextColor: paint("text.primary"),
      signalColor: paint("text.primary"),
      labelBoxBkgColor: paint("panel.card"),
      edgeLabelBackground: paint("panel.raised"),
      sectionBkgColor: paint("panel.card"),
      altSectionBkgColor: paint("panel.control"),
      gridColor: paint("line.divider"),
      todayLineColor: paint("text.primary"),
      taskBkgColor: paint("panel.raised"),
      taskBorderColor: paint("line.border"),
      taskTextColor: paint("text.primary"),
      activeTaskBkgColor: paint("text.secondary"),
      activeTaskBorderColor: paint("text.primary"),
      doneTaskBkgColor: paint("panel.card"),
      doneTaskBorderColor: paint("line.border"),
      critBkgColor: paint("text.tertiary"),
      critBorderColor: paint("text.primary"),
      pieTitleTextColor: paint("text.primary"),
      pieSectionTextColor: paint("text.primary"),
      pieLegendTextColor: paint("text.secondary"),
      pieStrokeColor: paint("line.border"),
      commitLabelColor: paint("text.primary"),
      commitLabelBackground: paint("panel.card"),
      tagLabelColor: paint("text.primary"),
      tagLabelBackground: paint("panel.raised"),
      tagLabelBorder: paint("line.border"),
    };
    for (let index = 1; index <= 12; index += 1) {
      vars[`pie${index}`] = grayStep(tokens, scheme, index / 13);
    }
    for (let index = 0; index <= 7; index += 1) {
      vars[`git${index}`] = grayStep(tokens, scheme, (index + 1) / 9);
    }
    const fields = Object.entries(vars).map(([key, value]) => `      ${key}: "${value}",`);
    return `    ${scheme}: {\n${fields.join("\n")}\n    },`;
  });
  return ["// " + header, "export const mermaidVars = {", ...schemes, "};", ""].join("\n");
}

export function renderTokens(tokens: Tokens): Record<string, string> {
  assertTextAlphas(tokens);
  return {
    "Sources/DevBar/Generated/DesignTokens.swift": formatSwift(renderSwift(tokens)),
    "Web/src/theme/tokens.css": formatPrettier("tokens.css", renderCSS(tokens)),
    "Web/src/theme/cm-highlight.ts": formatPrettier("cm-highlight.ts", renderCodeMirror()),
    "Web/src/theme/shiki-devbar-light.json": formatPrettier(
      "shiki-devbar-light.json",
      renderShiki(tokens, "light"),
    ),
    "Web/src/theme/shiki-devbar-dark.json": formatPrettier(
      "shiki-devbar-dark.json",
      renderShiki(tokens, "dark"),
    ),
    "Web/src/theme/mermaid-vars.ts": formatPrettier("mermaid-vars.ts", renderMermaid(tokens)),
  };
}

function writeOutputs(files: Record<string, string>): void {
  for (const [rel, content] of Object.entries(files)) {
    const abs = join(root, rel);
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, content);
  }
}

function checkOutputs(files: Record<string, string>): void {
  const mismatches: string[] = [];
  for (const rel of outputs) {
    const expected = files[rel];
    if (expected === undefined) {
      mismatches.push(`${rel} 未生成`);
      continue;
    }
    let current = "";
    try {
      current = readFileSync(join(root, rel), "utf8");
    } catch {
      mismatches.push(`${rel} 缺失`);
      continue;
    }
    if (current !== expected) {
      mismatches.push(rel);
    }
  }
  if (mismatches.length > 0) {
    console.error("生成产物与 design/tokens.json 不一致：");
    for (const item of mismatches) {
      console.error(`  ${item}`);
    }
    process.exit(1);
  }
  console.log("tokens 与 design/tokens.json 一致");
}

function main(): void {
  const tokens = loadTokens();
  const files = renderTokens(tokens);
  if (process.argv.includes("--check")) {
    checkOutputs(files);
    return;
  }
  writeOutputs(files);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}
