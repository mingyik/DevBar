import "./readonly-scroll.css";

export function scrollThumb(
  viewport: number,
  content: number,
  offset: number,
): { length: number; position: number } | null {
  if (
    ![viewport, content, offset].every(Number.isFinite) ||
    viewport <= 0 ||
    content <= viewport
  )
    return null;
  const length = Math.min(
    viewport,
    Math.max(20, (viewport * viewport) / content),
  );
  return {
    length,
    position:
      Math.min(1, Math.max(0, offset / (content - viewport))) *
      (viewport - length),
  };
}

const installed = new WeakMap<Document, () => void>();
/** Overlay indicators never receive pointer events or change the scroll owner's layout. */
export function installReadOnlyScrollbars(doc: Document): () => void {
  const Observer = doc.defaultView?.MutationObserver;
  if (!Observer) return () => {};
  const existing = installed.get(doc);
  if (existing) return existing;
  const records = new Map<
    HTMLElement,
    {
      vertical: HTMLDivElement;
      horizontal: HTMLDivElement;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  const remove = (owner: HTMLElement): void => {
    const record = records.get(owner);
    if (!record) return;
    clearTimeout(record.timer);
    record.vertical.remove();
    record.horizontal.remove();
    records.delete(owner);
  };
  const scroll = (event: Event): void => {
    const owner = event.target === doc ? doc.scrollingElement : event.target;
    if (!(owner instanceof HTMLElement)) return;
    // Wide Markdown tables show their own persistent scrollbar.
    if (owner.classList.contains("table-wrap")) return;
    let record = records.get(owner);
    if (!record) {
      const vertical = doc.createElement("div");
      const horizontal = doc.createElement("div");
      vertical.className = "devbar-scroll-thumb vertical";
      horizontal.className = "devbar-scroll-thumb horizontal";
      for (const node of [vertical, horizontal]) {
        node.setAttribute("aria-hidden", "true");
        doc.body.append(node);
      }
      record = { vertical, horizontal, timer: setTimeout(() => {}, 0) };
      records.set(owner, record);
    }
    clearTimeout(record.timer);
    const rect = owner.getBoundingClientRect();
    const vertical = scrollThumb(
      owner.clientHeight,
      owner.scrollHeight,
      owner.scrollTop,
    );
    const horizontal = scrollThumb(
      owner.clientWidth,
      owner.scrollWidth,
      owner.scrollLeft,
    );
    record.vertical.style.cssText = vertical
      ? `left:${rect.right - 5}px;top:${rect.top + vertical.position}px;height:${vertical.length}px`
      : "opacity:0";
    record.horizontal.style.cssText = horizontal
      ? `left:${rect.left + horizontal.position}px;top:${rect.bottom - 5}px;width:${horizontal.length}px`
      : "opacity:0";
    record.vertical.classList.toggle("scrolling", vertical !== null);
    record.horizontal.classList.toggle("scrolling", horizontal !== null);
    const current = record;
    record.timer = setTimeout(() => {
      current.vertical.classList.remove("scrolling");
      current.horizontal.classList.remove("scrolling");
    }, 800);
  };
  const observer = new Observer(() => {
    for (const owner of records.keys())
      if (!owner.isConnected || owner.getClientRects().length === 0)
        remove(owner);
  });
  observer.observe(doc.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["hidden", "class"],
  });
  doc.addEventListener("scroll", scroll, true);
  const dispose = (): void => {
    doc.removeEventListener("scroll", scroll, true);
    observer.disconnect();
    for (const owner of records.keys()) remove(owner);
    installed.delete(doc);
  };
  installed.set(doc, dispose);
  return dispose;
}
