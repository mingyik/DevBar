import type { MermaidConfig } from "mermaid";
import { mermaidVars, mermaidDiagramConfig } from "../theme/mermaid-vars";
import type { Theme } from "./highlight";
export const LAYOUT = "dagre" as const;
export const SYSTEM_FONT = "-apple-system, BlinkMacSystemFont, sans-serif";
let library: Promise<(typeof import("mermaid"))["default"]> | undefined;
let queue: Promise<unknown> = Promise.resolve();
let nonce = 0;
const cache = new Map<string, string>();
export function loadMermaid() {
  return (library ??= import("mermaid").then((m) => m.default));
}
export function mermaidOptions(theme: Theme): MermaidConfig {
  return {
    ...mermaidDiagramConfig[theme],
    journey: {
      ...mermaidDiagramConfig[theme].journey,
      textPlacement: "tspan",
      taskFontFamily: SYSTEM_FONT,
      titleFontFamily: SYSTEM_FONT,
    },
    startOnLoad: false,
    securityLevel: "strict",
    theme: "base",
    themeVariables: { ...mermaidVars[theme], fontFamily: SYSTEM_FONT },
    fontFamily: SYSTEM_FONT,
    look: "neo",
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
  await m.parse(source);
  if (/^\s*sankey(?:-beta)?\s*$/m.test(source)) {
    const diagram = await m.mermaidAPI.getDiagramFromText(source);
    const graph = (
      diagram.db as unknown as { getGraph(): { nodes: { id: string }[] } }
    ).getGraph();
    const vars = mermaidVars[theme] as Record<string, unknown>;
    const nodeColors = Object.fromEntries(
      graph.nodes.map((node, i) => [
        node.id,
        String(vars[`pie${(i % 12) + 1}`]),
      ]),
    );
    m.initialize({ ...mermaidOptions(theme), sankey: { nodeColors } });
  }
  const { svg } = await m.render("mmd-" + ++nonce, source);
  let output = svg;
  if (/^\s*journey\s*$/m.test(source)) {
    // Mermaid 12.3 concatenates configured palettes after its default palette.
    // Replace only Journey actor swatches; classDef/style on other diagrams stay intact.
    const template = document.createElement("template");
    template.innerHTML = output;
    const colors = mermaidDiagramConfig[theme].journey.actorColours;
    for (const actor of Array.from(
      template.content.querySelectorAll<SVGElement>("circle[class^='actor-']"),
    )) {
      const index = Number(actor.getAttribute("class")?.slice(6));
      actor.setAttribute("fill", colors[index % colors.length]);
    }
    for (const text of Array.from(
      template.content.querySelectorAll<SVGElement>("text, text *"),
    ))
      text.style.setProperty("fill", mermaidVars[theme].textColor, "important");
    output = template.innerHTML;
  }
  if (
    /^\s*C4(?:Context|Container|Component|Dynamic|Deployment)/m.test(source) &&
    !/(?:Update(?:Element|Rel)Style\s*\(|\$\w*Color\s*=)/i.test(source)
  ) {
    // C4 12.3 hardcodes default white node labels and dark relationship labels.
    // Respect explicit C4 styling; adapt only diagrams using those defaults.
    const template = document.createElement("template");
    template.innerHTML = output;
    for (const node of Array.from(
      template.content.querySelectorAll<SVGElement>(".c4-shape, .c4-shape *"),
    ))
      node.style.color = mermaidVars[theme].textColor;
    for (const text of Array.from(
      template.content.querySelectorAll<SVGElement>("text, text *"),
    )) {
      text.style.setProperty("fill", mermaidVars[theme].textColor, "important");
      text.style.fontFamily = SYSTEM_FONT;
    }
    for (const line of Array.from(
      template.content.querySelectorAll("line, path[stroke]"),
    ))
      line.setAttribute("stroke", mermaidVars[theme].lineColor);
    output = template.innerHTML;
  }
  const normalized = normalizeSvg(output);
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
  context.fillStyle = mermaidVars[theme].primaryColor;
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
