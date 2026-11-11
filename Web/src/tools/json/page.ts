import { EditorView } from "@codemirror/view";
import { StreamLanguage } from "@codemirror/language";
import {
  PageShell,
  element,
  pill,
  iconButton,
  setIcon,
  type PageState,
} from "../../editor/page-shell";
import { errorMarks, markErrors } from "../../editor/diagnostics";
import { post } from "../../bridge/client";
import { strings } from "../../strings";
import { startTransform } from "./client";
import type { Operation, Result } from "./protocol";
import type { Analysis } from "./core";
import { actionLabels, decodedRanges, type Encoding } from "./actions";
import { encodeComponent, encodeWhole, preview as urlPreview } from "../url";
import { encode as encodeBase64, decode as decodeBase64 } from "../base64";
import { renderTree } from "../../tree/render";

export class JsonPage {
  readonly shell: PageShell;
  encoding: Encoding = "url";
  wholeURL = false;
  private analysis: Analysis | null = null;
  private codecErrors = false;
  private analysisTimer: ReturnType<typeof setTimeout> | undefined;
  private cancel: () => void = () => {};
  private readonly jsonButton: HTMLButtonElement;
  private readonly escapeButton: HTMLButtonElement;
  private readonly codecButton: HTMLButtonElement;
  readonly previewButton: HTMLButtonElement;
  private readonly cancelButton: HTMLButtonElement;
  private readonly urlButton: HTMLButtonElement;
  private readonly base64Button: HTMLButtonElement;
  private readonly wholeSelect: HTMLSelectElement;
  constructor(shell: PageShell) {
    this.shell = shell;
    shell.addExtensions([
      errorMarks,
      StreamLanguage.define({
        token(stream) {
          if (stream.eatSpace()) return null;
          if (stream.match(/"(?:[^"\\]|\\.)*"(?=\s*:)/))
            return "def propertyName";
          if (stream.match(/"(?:[^"\\]|\\.)*"/)) return "string";
          if (stream.match(/-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/))
            return "number";
          if (stream.match(/true|false|null/)) return "atom";
          stream.next();
          return "punctuation";
        },
      }),
      EditorView.updateListener.of((update) => {
        if (
          update.transactions.some(
            (t) =>
              t.isUserEvent("input.paste") &&
              t.changes.length === t.startState.doc.length,
          )
        ) {
          const transaction = update.transactions.find((t) =>
            t.isUserEvent("input.paste"),
          );
          let whole = false;
          transaction?.changes.iterChangedRanges((from, to) => {
            if (from === 0 && to === transaction.startState.doc.length)
              whole = true;
          });
          if (whole)
            queueMicrotask(() => {
              void this.autoFormat();
            });
        }
      }),
    ]);
    this.jsonButton = pill(strings.json, () => {
      void this.convert("toggle");
    });
    this.jsonButton.classList.add("primary");
    this.escapeButton = pill(strings.escape, () => {
      void this.convert(actionLabels(shell.text, this.encoding).escape);
    });
    this.escapeButton.style.minWidth = "72px";
    this.codecButton = pill(strings.encode, () => this.codec());
    this.codecButton.style.minWidth = "60px";
    this.urlButton = pill("URL", () => this.setEncoding("url"));
    this.base64Button = pill("Base64", () => this.setEncoding("base64"));
    const segment = element("span", "codec-segment");
    segment.append(this.urlButton, this.base64Button);
    this.wholeSelect = element("select");
    this.wholeSelect.setAttribute("aria-label", strings.urlComponent);
    for (const [value, label] of [
      ["component", strings.urlComponent],
      ["whole", strings.urlWhole],
    ]) {
      const option = element("option", "", label);
      option.value = value;
      this.wholeSelect.append(option);
    }
    this.wholeSelect.onchange = () => {
      this.wholeURL = this.wholeSelect.value === "whole";
      shell.onStateChange();
    };
    this.cancelButton = pill(strings.cancel, () => {
      this.cancel();
      this.cancelButton.hidden = true;
      shell.updateInfo();
    });
    this.cancelButton.hidden = true;
    shell.actions.append(
      this.jsonButton,
      this.escapeButton,
      this.codecButton,
      segment,
      this.wholeSelect,
      this.cancelButton,
    );
    this.previewButton = iconButton("preview", () => {
      void this.togglePreview();
    });
    const copy = iconButton("copy", () => {
      void this.copy().then(() => {
        setIcon(copy, "copied");
        setTimeout(() => setIcon(copy, "copy"), 1000);
      });
    });
    const image = iconButton("exportImage", () => {
      void this.exportImage();
    });
    const clear = iconButton("clear", () => {
      shell.showPreview(false);
      shell.replace("");
    });
    shell.fixed.append(this.previewButton, copy, image, clear);
    shell.onChange = () => this.changed();
    this.changed();
  }
  setEncoding(value: Encoding): void {
    this.encoding = value;
    this.labels();
    this.shell.onStateChange();
  }
  state(): PageState {
    return {
      ...this.shell.state(),
      encoding: this.encoding,
      wholeURL: this.wholeURL,
    };
  }
  async restore(state: Partial<PageState>): Promise<void> {
    this.encoding = state.encoding === "base64" ? "base64" : "url";
    this.wholeURL = state.wholeURL === true;
    this.shell.restore(state);
    await this.analyze();
    if (state.view === "preview") await this.togglePreview();
  }
  private changed(): void {
    this.codecErrors = false;
    this.cancel();
    this.cancelButton.hidden = true;
    clearTimeout(this.analysisTimer);
    this.analysis = null;
    this.labels();
    this.analysisTimer = setTimeout(() => {
      void this.analyze();
    }, 400);
  }
  private labels(): void {
    const labels = actionLabels(this.shell.text, this.encoding);
    this.escapeButton.textContent = strings[labels.escape];
    this.codecButton.textContent = strings[labels.codec];
    this.urlButton.classList.toggle("selected", this.encoding === "url");
    this.base64Button.classList.toggle("selected", this.encoding === "base64");
    this.wholeSelect.hidden = this.encoding !== "url";
    this.wholeSelect.value = this.wholeURL ? "whole" : "component";
    this.jsonButton.disabled = this.analysis?.state !== "valid";
    this.previewButton.disabled =
      this.analysis?.state !== "valid" &&
      (this.encoding === "base64" || !urlPreview(this.shell.text.trim()));
    setIcon(
      this.previewButton,
      this.shell.mode === "preview" ? "edit" : "preview",
    );
  }
  private async request(operation: Operation): Promise<Result> {
    const job = startTransform(operation, this.shell.text, {
      onSlow: () => {
        this.cancelButton.hidden = false;
        this.shell.updateInfo(strings.working);
      },
    });
    this.cancel = job.cancel;
    return job.result;
  }
  async analyze(): Promise<void> {
    clearTimeout(this.analysisTimer);
    const revision = this.shell.revision;
    const text = this.shell.text;
    if (!text.trim()) {
      this.analysis = null;
      this.labels();
      return;
    }
    const result = await this.request("analyze");
    if (
      revision !== this.shell.revision ||
      result.status !== "success" ||
      !result.analysis
    )
      return;
    this.cancelButton.hidden = true;
    this.analysis = result.analysis;
    this.labels();
    if (this.analysis.state !== "valid" && /^[\s]*[{[]/.test(text)) {
      const error = this.analysis.error;
      markErrors(this.shell.view, [
        { start: error.offset, end: error.offset + 1 },
      ]);
      this.shell.updateInfo(strings.error(error.line, error.column));
    } else if (!this.codecErrors) {
      markErrors(this.shell.view, []);
      this.shell.updateInfo();
    }
  }
  async convert(
    operation: "format" | "compact" | "escape" | "unescape" | "toggle",
  ): Promise<void> {
    this.cancel();
    clearTimeout(this.analysisTimer);
    const revision = this.shell.revision;
    let result = await this.request(
      operation === "toggle" ? "format" : operation,
    );
    if (
      operation === "toggle" &&
      result.status === "success" &&
      result.text === this.shell.text &&
      revision === this.shell.revision
    )
      result = await this.request("compact");
    this.cancelButton.hidden = true;
    if (revision !== this.shell.revision || result.status === "cancelled")
      return;
    if (result.status === "error") {
      markErrors(this.shell.view, [
        { start: result.error.offset, end: result.error.offset + 1 },
      ]);
      this.shell.updateInfo(
        strings.error(result.error.line, result.error.column),
      );
      return;
    }
    this.shell.showPreview(false);
    this.shell.replace(result.text, "devbar.transform");
    await this.analyze();
  }
  async autoFormat(): Promise<void> {
    const revision = this.shell.revision;
    const result = await this.request("analyze");
    if (
      revision === this.shell.revision &&
      result.status === "success" &&
      result.analysis?.state === "valid"
    )
      await this.convert("format");
  }
  private codec(): void {
    const action = actionLabels(this.shell.text, this.encoding).codec;
    let text: string;
    let errors: { start: number; end: number }[] = [];
    if (this.encoding === "base64") {
      if (action === "encode") text = encodeBase64(this.shell.text);
      else {
        const result = decodeBase64(this.shell.text);
        if (result.kind !== "text") {
          this.shell.updateInfo(
            result.kind === "binary"
              ? strings.binary(result.bytes)
              : strings.invalidBase64,
          );
          return;
        }
        text = result.text;
      }
    } else if (action === "encode")
      text = (this.wholeURL ? encodeWhole : encodeComponent)(this.shell.text);
    else {
      const result = decodedRanges(this.shell.text);
      text = result.text;
      errors = result.errors;
    }
    this.shell.showPreview(false);
    this.shell.replace(text);
    this.codecErrors = errors.length > 0;
    markErrors(this.shell.view, errors);
    if (errors.length)
      this.shell.updateInfo(
        strings.error(
          this.shell.view.state.doc.lineAt(errors[0].start).number,
          errors[0].start -
            this.shell.view.state.doc.lineAt(errors[0].start).from +
            1,
        ),
      );
  }
  async togglePreview(): Promise<void> {
    if (this.shell.mode === "preview") {
      this.shell.showPreview(false);
      this.labels();
      this.shell.onStateChange();
      return;
    }
    await this.analyze();
    if (this.analysis?.state === "valid") {
      const revision = this.shell.revision;
      const result = await this.request("parse");
      if (revision !== this.shell.revision || result.status !== "success")
        return;
      renderTree(this.shell.preview, result.value, (text) =>
        post("clipboard.writeText", { text }),
      );
    } else {
      if (this.encoding === "base64") return;
      const url = urlPreview(this.shell.text.trim());
      if (!url) return;
      const table = element("table", "url-table");
      for (const [label, value] of [
        [strings.protocol, url.scheme],
        [strings.userinfo, url.userinfo],
        [strings.host, url.host],
        [strings.port, url.port],
        [strings.path, url.path],
        [strings.fragment, url.fragment],
        ...url.parameters.map((p) => [p.key, p.value]),
      ]) {
        const row = element("tr");
        row.append(element("td", "", label), element("td", "", value));
        const copy = element("td");
        copy.append(
          iconButton("copy", () => {
            void post("clipboard.writeText", { text: value });
          }),
        );
        row.append(copy);
        table.append(row);
      }
      this.shell.preview.replaceChildren(table);
    }
    this.shell.showPreview(true);
    this.labels();
    this.shell.onStateChange();
  }
  async copy(): Promise<void> {
    if (this.shell.mode === "preview" && this.analysis?.state === "valid") {
      const result = await this.request("format");
      if (result.status === "success")
        await post("clipboard.writeText", { text: result.text });
    } else await post("clipboard.writeText", { text: this.shell.text });
  }
  async exportImage(): Promise<void> {
    if (this.shell.mode !== "preview") {
      if (this.analysis?.state !== "valid") await this.analyze();
      if (this.analysis?.state !== "valid") return;
      const result = await this.request("format");
      if (result.status !== "success") return;
      const pre = element("pre", "export-text", result.text);
      this.shell.preview.replaceChildren(pre);
    }
    // Snapshot preparation is shared with the document page in R9.
    const { exportPreview } = await import("../../preview/export");
    await exportPreview(this.shell);
  }
}
