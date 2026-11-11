import {
  PageShell,
  element,
  pill,
  iconButton,
  setIcon,
  type PageState,
} from "../editor/page-shell";
import { post } from "../bridge/client";
import { strings } from "../strings";
export class QRPage {
  readonly shell: PageShell;
  private png = "";
  private readonly toggle: HTMLButtonElement;
  constructor(shell: PageShell) {
    this.shell = shell;
    this.toggle = pill(strings.qr, () => {
      void this.togglePreview();
    });
    this.toggle.classList.add("primary");
    shell.actions.append(this.toggle);
    const copy = iconButton("copy", () => {
      void this.copy().then(() => {
        setIcon(copy, "copied");
        setTimeout(() => setIcon(copy, "copy"), 1000);
      });
    });
    shell.fixed.append(
      copy,
      iconButton("clear", () => {
        this.edit();
        shell.replace("");
      }),
    );
    shell.onChange = () => {
      this.png = "";
      this.edit();
    };
  }
  private edit(): void {
    this.shell.showPreview(false);
    this.toggle.textContent = strings.qr;
  }
  async togglePreview(): Promise<void> {
    if (this.shell.mode === "preview") {
      this.edit();
      this.shell.onStateChange();
      return;
    }
    const bytes = new TextEncoder().encode(this.shell.text).length;
    if (bytes > 2331) {
      this.shell.updateInfo(strings.qrTooLarge(bytes));
      return;
    }
    const revision = this.shell.revision;
    const reply = await post("qr.show", { text: this.shell.text });
    if (revision !== this.shell.revision) return;
    if (reply.status !== "shown" || typeof reply.pngBase64 !== "string") {
      this.shell.updateInfo(
        reply.status === "tooLarge"
          ? strings.qrTooLarge(bytes)
          : strings.qrFailed,
      );
      return;
    }
    this.png = reply.pngBase64;
    const image = element("img");
    image.alt = strings.qr;
    image.src = `data:image/png;base64,${this.png}`;
    this.shell.preview.classList.add("qr-preview");
    this.shell.preview.replaceChildren(image);
    this.shell.showPreview(true);
    this.toggle.textContent = strings.edit;
    this.shell.onStateChange();
  }
  async copy(): Promise<void> {
    if (this.shell.mode === "preview" && this.png)
      await post("clipboard.writeImage", { pngBase64: this.png });
    else await post("clipboard.writeText", { text: this.shell.text });
  }
  async restore(state: Partial<PageState>): Promise<void> {
    this.shell.restore(state);
    if (state.view === "preview") await this.togglePreview();
  }
}
