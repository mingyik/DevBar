import {
  PageShell,
  element,
  iconButton,
  setButtonLabel,
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
    this.toggle = iconButton("preview", () => {
      void this.togglePreview();
    });
    setButtonLabel(this.toggle, strings.preview);
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
    setIcon(this.toggle, "preview");
    setButtonLabel(this.toggle, strings.preview);
  }
  async togglePreview(): Promise<void> {
    if (this.shell.mode === "preview") {
      this.edit();
      this.shell.onStateChange();
      return;
    }
    if (await this.renderPreview()) this.shell.onStateChange();
  }
  async refresh(): Promise<void> {
    if (
      this.shell.mode === "preview" &&
      !this.png &&
      this.shell.preview.childElementCount === 0
    )
      await this.renderPreview();
  }
  releaseMemory(): void {
    this.png = "";
    this.shell.preview.replaceChildren();
    this.shell.preview.classList.remove("qr-preview");
  }
  private async renderPreview(): Promise<boolean> {
    if (this.shell.text === "") {
      this.png = "";
      this.shell.preview.replaceChildren();
      this.shell.preview.classList.remove("qr-preview");
      this.shell.showPreview(true);
      setIcon(this.toggle, "edit");
      setButtonLabel(this.toggle, strings.edit);
      return true;
    }
    const bytes = new TextEncoder().encode(this.shell.text).length;
    if (bytes > 2331) {
      this.shell.updateInfo(strings.qrTooLarge(bytes));
      return false;
    }
    const revision = this.shell.revision;
    const reply = await post("qr.show", { text: this.shell.text });
    if (revision !== this.shell.revision) return false;
    if (reply.status !== "shown" || typeof reply.pngBase64 !== "string") {
      this.shell.updateInfo(
        reply.status === "tooLarge"
          ? strings.qrTooLarge(bytes)
          : strings.qrFailed,
      );
      return false;
    }
    this.png = reply.pngBase64;
    const image = element("img");
    image.alt = strings.qr;
    image.src = `data:image/png;base64,${this.png}`;
    this.shell.preview.classList.add("qr-preview");
    this.shell.preview.replaceChildren(image);
    this.shell.showPreview(true);
    setIcon(this.toggle, "edit");
    setButtonLabel(this.toggle, strings.edit);
    return true;
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
