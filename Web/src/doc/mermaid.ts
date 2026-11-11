import type { MermaidConfig } from "mermaid";
import type { Theme } from "./highlight";
export const LAYOUT = "dagre" as const;
export const SYSTEM_FONT = "-apple-system, BlinkMacSystemFont, sans-serif";
let library: Promise<(typeof import("mermaid"))["default"]> | undefined;
let queue: Promise<unknown> = Promise.resolve();
let nonce = 0;
const cache = new Map<string, string>();
const backgrounds: Partial<Record<Theme, string>> = {};
export function loadMermaid() {
  return (library ??= import("mermaid").then((m) => m.default));
}
export function mermaidOptions(theme: Theme): MermaidConfig {
  return {
    journey: { textPlacement: "tspan" },
    startOnLoad: false,
    securityLevel: "strict",
    theme: theme === "dark" ? "dark" : "default",
    fontFamily: SYSTEM_FONT,
    look: "classic",
    htmlLabels: false,
    layout: LAYOUT,
    flowchart: { htmlLabels: false, useMaxWidth: false },
    state: { useMaxWidth: false },
    suppressErrorRendering: true,
    secure: [
      "secure",
      "securityLevel",
      "startOnLoad",
      "maxTextSize",
      "suppressErrorRendering",
      "maxEdges",
      "theme",
      "themeVariables",
      "themeCSS",
      "look",
      "fontFamily",
      "darkMode",
      "htmlLabels",
      "layout",
    ],
  };
}
export function normalizeSvg(svg: string): string {
  const template = document.createElement("template");
  template.innerHTML = svg;
  const root = template.content.querySelector("svg");
  if (!root) throw new Error("图表没有返回 SVG");
  const box = root
    .getAttribute("viewBox")
    ?.split(/[\s,]+/)
    .map(Number);
  if (
    !box ||
    box.length !== 4 ||
    !box.every(Number.isFinite) ||
    box[2] <= 0 ||
    box[3] <= 0
  )
    throw new Error("图表尺寸无效");
  root.style.removeProperty("max-width");
  root.style.removeProperty("width");
  root.style.removeProperty("height");
  root.setAttribute("width", String(box[2]));
  root.setAttribute("height", String(box[3]));
  root.setAttribute("xmlns", "http://www.w3.org/2000/svg");
  return root.outerHTML;
}
async function generate(source: string, theme: Theme): Promise<string> {
  const key = JSON.stringify([source, theme]);
  const existing = cache.get(key);
  if (existing) return existing;
  const m = await loadMermaid();
  m.initialize(mermaidOptions(theme));
  backgrounds[theme] = m.mermaidAPI.getConfig().themeVariables?.background;
  await m.parse(source);
  const { svg } = await m.render("mmd-" + ++nonce, source);
  const normalized = normalizeSvg(svg);
  if (cache.size >= 64) cache.delete(cache.keys().next().value!);
  cache.set(key, normalized);
  return normalized;
}
export function renderMermaid(source: string, theme: Theme): Promise<string> {
  const result = queue.then(() => generate(source, theme));
  queue = result.catch(() => {});
  return result;
}
export async function renderMermaidElements(root: HTMLElement, theme: Theme) {
  for (const element of Array.from(
    root.querySelectorAll<HTMLElement>(".mmd[data-src]"),
  )) {
    const source = element.dataset.src ?? "";
    try {
      element.innerHTML = await renderMermaid(source, theme);
      element.classList.remove("mmd-error");
    } catch (error) {
      element.replaceChildren();
      element.classList.add("mmd-error");
      const title = document.createElement("strong");
      title.textContent = "⚠ Mermaid 语法错误";
      const detail = document.createElement("pre");
      detail.textContent =
        error instanceof Error ? error.message : "图表无法渲染";
      element.append(title, detail);
    }
  }
}
/** Only produces image bytes. The host owns clipboard access. */
export async function svgToPngBase64(
  svg: string,
  theme: Theme,
): Promise<string> {
  const normalized = normalizeSvg(svg);
  const template = document.createElement("template");
  template.innerHTML = normalized;
  const node = template.content.querySelector("svg")!;
  const width = Number(node.getAttribute("width")),
    height = Number(node.getAttribute("height"));
  const pixels = pngDimensions(width, height);
  const image = new Image();
  image.src =
    "data:image/svg+xml;charset=utf-8," + encodeURIComponent(normalized);
  await image.decode();
  const canvas = document.createElement("canvas");
  canvas.width = pixels.width;
  canvas.height = pixels.height;
  const context = canvas.getContext("2d");
  if (!context) throw new Error("无法创建图片");
  context.fillStyle =
    backgrounds[theme] ??
    getComputedStyle(document.documentElement)
      .getPropertyValue("--snapshot-background")
      .trim();
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.drawImage(image, 0, 0, canvas.width, canvas.height);
  const blob = await new Promise<Blob>((resolve, reject) =>
    canvas.toBlob(
      (b) => (b ? resolve(b) : reject(new Error("图片生成失败"))),
      "image/png",
    ),
  );
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function pngDimensions(width: number, height: number) {
  const w = Math.ceil(width * 2),
    h = Math.ceil(height * 2);
  if (
    !Number.isFinite(w) ||
    !Number.isFinite(h) ||
    w <= 0 ||
    h <= 0 ||
    w > 8192 ||
    h > 8192 ||
    w * h * 4 > 64000000
  )
    throw new Error("图表过大，无法生成图片");
  return { width: w, height: h };
}
