import { EditorView } from "@codemirror/view";
import {
  PageShell,
  element,
  pill,
  iconButton,
  type PageState,
} from "../../editor/page-shell";
import { errorMarks, markErrors } from "../../editor/diagnostics";
import { post } from "../../bridge/client";
import { strings } from "../../strings";
import { startTransform } from "./client";
import type { Operation, Result } from "./protocol";
import type { Analysis } from "./core";
import { actionLabels, decodedRanges, type Encoding } from "./actions";
import { encodeComponent, preview as urlPreview } from "../url";
import { decode as decodeBase64 } from "../base64";
import { detect } from "../detect";
import { renderTree } from "../../tree/render";
import { jsonFoldingExtension } from "./folding";

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
  private readonly cancelButton: HTMLButtonElement;
  constructor(shell: PageShell) {
    this.shell = shell;
    shell.addExtensions([
      errorMarks,
      jsonFoldingExtension(),
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
    this.escapeButton = pill(strings.escape, () => {
      void this.convert(actionLabels(shell.text, this.encoding).escape);
    });
    this.escapeButton.style.minWidth = "72px";
    this.codecButton = pill(strings.encode, () => this.codec());
    this.codecButton.style.minWidth = "60px";
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
      this.cancelButton,
    );
    const clear = iconButton("clear", () => {
      shell.showPreview(false);
      shell.replace("");
    });
    shell.fixed.append(clear);
    shell.onChange = () => this.changed();
    this.changed();
  }
  setEncoding(value: Encoding): void {
    this.encoding = value;
    if (value === "base64") this.shell.showPreview(false);
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
    this.encoding = /^[\s]*[{[]/.test(this.shell.text)
      ? "url"
      : detect(this.shell.text).type === "base64"
        ? "base64"
        : "url";
    const labels = actionLabels(this.shell.text, this.encoding);
    this.escapeButton.textContent = strings[labels.escape];
    this.codecButton.textContent = strings[labels.codec];
    this.jsonButton.disabled = this.analysis?.state !== "valid";
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
      if (action === "encode") text = encodeComponent(this.shell.text);
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
    } else if (action === "encode") text = encodeComponent(this.shell.text);
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
    if (this.encoding === "base64") return;
    if (this.shell.mode === "preview") {
      this.shell.showPreview(false);
      this.labels();
      this.shell.onStateChange();
      return;
    }
    await this.analyze();
    if (await this.buildPreview()) this.shell.onStateChange();
  }
  async refresh(): Promise<void> {
    if (this.analysis === null && this.shell.text.trim()) await this.analyze();
    if (
      this.shell.mode === "preview" &&
      this.shell.preview.childElementCount === 0
    )
      await this.buildPreview();
  }
  releaseMemory(): void {
    clearTimeout(this.analysisTimer);
    this.cancel();
    this.cancelButton.hidden = true;
    this.analysis = null;
    this.shell.preview.replaceChildren();
    markErrors(this.shell.view, []);
    this.labels();
  }
  private async buildPreview(): Promise<boolean> {
    if (this.analysis?.state === "valid") {
      const revision = this.shell.revision;
      const result = await this.request("parse");
      if (revision !== this.shell.revision || result.status !== "success")
        return false;
      renderTree(this.shell.preview, result.value, (text) =>
        post("clipboard.writeText", { text }),
      );
    } else {
      const url = urlPreview(this.shell.text.trim());
      if (!url) return false;
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
    return true;
  }
  async copy(): Promise<void> {
    if (this.shell.mode === "preview" && this.analysis?.state === "valid") {
      const result = await this.request("format");
      if (result.status === "success")
        await post("clipboard.writeText", { text: result.text });
    } else await post("clipboard.writeText", { text: this.shell.text });
  }
}
