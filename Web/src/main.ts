export const entryName = "DevBar";
import { decodeEnvelope, type JSONValue } from "./bridge/envelope";
import { post } from "./bridge/client";
import { PageShell, type PageState } from "./editor/page-shell";
import { installReadOnlyScrollbars } from "./styles/readonly-scroll";
import "./styles/app.css";
import "./styles/pages.css";
import "./styles/contrast.css";
import "./theme/tokens.css";

type Page = "json" | "qr" | "doc";
let current: Page = "json";
let autoImport = true;
const pages = new Map<Page, PageShell>();
let saveTimer: ReturnType<typeof setTimeout> | undefined;
const bridge = {
  async receive(raw: string): Promise<JSONValue> {
    const { type, payload } = decodeEnvelope(raw);
    switch (type) {
      case "theme.set":
        document.documentElement.dataset.theme =
          payload.theme === "dark" ? "dark" : "light";
        break;
      case "panel.size":
        document.documentElement.dataset.size =
          payload.size === "large" ? "large" : "normal";
        break;
      case "settings.set":
        autoImport = payload.autoImport !== false;
        break;
      case "screen.show": {
        const value = payload.page ?? payload.screen;
        await show(value === "qr" ? "qr" : value === "doc" ? "doc" : "json");
        break;
      }
      case "tools.import": {
        const page = payload.page === "qr" ? "qr" : "json";
        await importText(
          page,
          typeof payload.text === "string" ? payload.text : "",
          payload.mode === "ifEmpty",
          typeof payload.fileName === "string" ? payload.fileName : null,
        );
        break;
      }
      case "doc.import":
        await importText(
          "doc",
          typeof payload.text === "string" ? payload.text : "",
          false,
          typeof payload.fileName === "string" ? payload.fileName : null,
        );
        break;
      case "memory.flush":
        await save();
        return { ok: true };
    }
    return {};
  },
};
declare global {
  interface Window {
    __devbar: typeof bridge;
  }
}
if (typeof document !== "undefined") void start();
async function start(): Promise<void> {
  installReadOnlyScrollbars(document);
  for (const [page, id] of [
    ["json", "tools"],
    ["qr", "qr"],
    ["doc", "doc"],
  ] as const) {
    const root = document.getElementById(id);
    if (!root) throw new Error(`missing ${id}`);
    const shell = new PageShell(root, page);
    shell.onStateChange = scheduleSave;
    pages.set(page, shell);
    const reply = await post("state.load", { screen: page });
    if (reply.state && typeof reply.state === "object")
      shell.restore(reply.state as Partial<PageState>);
  }
  window.__devbar = bridge;
  const reply = await post("app.ready", { version: "1" });
  document.documentElement.dataset.theme =
    reply.theme === "dark" ? "dark" : "light";
  if (reply.settings && typeof reply.settings === "object")
    autoImport =
      (reply.settings as Record<string, unknown>).autoImport !== false;
}
async function show(page: Page): Promise<void> {
  current = page;
  for (const [name, shell] of pages) shell.root.hidden = name !== page;
  const shell = pages.get(page)!;
  shell.view.focus();
  if (autoImport && shell.text === "" && page !== "doc") {
    const reply = await post("clipboard.readText");
    if (
      reply.status === "ok" &&
      typeof reply.text === "string" &&
      shell.text === ""
    )
      await importText(page, reply.text, true, null);
  }
}
async function importText(
  page: Page,
  text: string,
  ifEmpty: boolean,
  fileName: string | null,
): Promise<void> {
  const shell = pages.get(page);
  if (!shell || (ifEmpty && shell.text !== "")) return;
  shell.showPreview(false);
  shell.replace(text, "devbar.import");
  shell.fileName = fileName;
  shell.updateInfo();
  scheduleSave();
}
function scheduleSave(): void {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    void save();
  }, 1000);
}
async function save(): Promise<void> {
  for (const [screen, shell] of pages)
    await post("state.save", {
      screen,
      state: shell.state() as unknown as JSONValue,
    });
}
export function activePage(): string {
  return current;
}
