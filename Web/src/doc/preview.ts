import MarkdownIt from "markdown-it";
import taskLists from "markdown-it-task-lists";
import createDOMPurify from "dompurify";
import { prepareTables } from "./tables";

export function createMarkdownPreview(doc: Document = document) {
  const md = new MarkdownIt({
    html: true,
    linkify: false,
    typographer: false,
    breaks: false,
  }).use(taskLists);
  const purifier = createDOMPurify(doc.defaultView!);
  const sources: string[] = [];
  let diagram = 0,
    lastText: string | undefined,
    lastHTML = "";
  md.renderer.rules.fence = (tokens, index) => {
    const token = tokens[index];
    const escaped = md.utils.escapeHtml(token.content);
    if (token.info.trim().split(/\s/, 1)[0] === "mermaid")
      sources.push(token.content);
    return token.info.trim().split(/\s/, 1)[0] === "mermaid"
      ? `<div class="mmd" data-src="${escaped}" data-idx="${diagram++}"></div>\n`
      : `<pre class="code plain"><code>${escaped}</code></pre>\n`;
  };
  function render(text: string): string {
    if (text === lastText) return lastHTML;
    diagram = 0;
    sources.length = 0;
    const template = doc.createElement("template");
    template.innerHTML = md.render(text);
    prepareTables(template.content);
    for (const image of Array.from(template.content.querySelectorAll("img"))) {
      const address = image.getAttribute("src") ?? "";
      image.removeAttribute("srcset");
      if (!/^(?:devbar:|data:)/i.test(address.trim())) {
        const placeholder = doc.createElement("span");
        placeholder.className = "external-image";
        const label = doc.createElement("span");
        label.textContent = "外部图片未加载";
        const url = doc.createElement("span");
        url.className = "image-address";
        url.textContent = address;
        placeholder.append(label, url);
        image.replaceWith(placeholder);
      }
    }
    for (const element of Array.from(
      template.content.querySelectorAll("[src]"),
    )) {
      if (element.tagName !== "IMG") element.removeAttribute("src");
    }
    // Preserve table alignment through classes; arbitrary CSS could issue network requests.
    for (const element of Array.from(
      template.content.querySelectorAll("[style]"),
    ))
      element.removeAttribute("style");
    const html = purifier.sanitize(template.innerHTML, {
      USE_PROFILES: { html: true },
      ALLOW_DATA_ATTR: false,
      ADD_ATTR: ["class", "data-src", "data-idx", "data-line"],
      FORBID_ATTR: [
        "style",
        "srcset",
        "poster",
        "background",
        "ping",
        "action",
        "formaction",
      ],
      ALLOWED_URI_REGEXP:
        /^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix|devbar):|[^a-z]|[a-z+.-]+(?:[^a-z+.:-]|$))/i,
      FORBID_TAGS: [
        "style",
        "script",
        "iframe",
        "object",
        "embed",
        "link",
        "meta",
        "base",
        "form",
        "video",
        "audio",
        "source",
      ],
    });
    // Sanitizers trim attribute whitespace. Restore only our inert fence source
    // strings so diagram whitespace is preserved for the later renderer.
    const clean = doc.createElement("template");
    clean.innerHTML = html;
    for (const placeholder of Array.from(
      clean.content.querySelectorAll("div.mmd[data-idx]"),
    )) {
      const index = Number(placeholder.getAttribute("data-idx"));
      if (Number.isInteger(index) && sources[index] !== undefined)
        placeholder.setAttribute("data-src", sources[index]);
    }
    lastText = text;
    lastHTML = clean.innerHTML;
    return lastHTML;
  }
  return { render };
}
/** Ordinary clicks never navigate; only an explicit command-click requests the host. */
export function bindPreviewLinks(
  root: HTMLElement,
  onOpenLink: (url: string) => void = () => {},
): () => void {
  const click = (event: MouseEvent) => {
    const target =
      event.target instanceof Element ? event.target.closest("a") : null;
    if (!target || !root.contains(target)) return;
    event.preventDefault();
    const href = target.getAttribute("href") ?? "";
    if (
      event.type === "click" &&
      event.button === 0 &&
      event.metaKey &&
      /^https?:\/\//i.test(href)
    )
      onOpenLink(href);
  };
  root.addEventListener("click", click);
  root.addEventListener("auxclick", click);
  return () => {
    root.removeEventListener("click", click);
    root.removeEventListener("auxclick", click);
  };
}
