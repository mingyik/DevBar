/* global window, document, performance, setTimeout, KeyboardEvent, crypto, Image, requestAnimationFrame, TextEncoder */
export default async function run(scenario, fixture) {
  const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const until = async (predicate, description = "condition") => {
    const end = performance.now() + 60000;
    while (!predicate()) {
      if (performance.now() > end)
        throw Error(
          "Timed out waiting for " +
            (typeof description === "function" ? description() : description),
        );
      await delay(10);
    }
  };
  const editor = (id) =>
    document.querySelector(`#${id} .cm-content`).cmTile.root.view;
  const text = (id) => editor(id).state.doc.toString();
  const receive = async (type, payload) =>
    window.__devbar.receive(
      JSON.stringify({ v: 1, id: crypto.randomUUID(), type, payload }),
    );
  const metaE = () =>
    document.dispatchEvent(
      new KeyboardEvent("keydown", { key: "e", metaKey: true, bubbles: true }),
    );
  const result = {};
  if (scenario === "markdown-mode") {
    await receive("screen.show", { page: "doc" });
    await receive("doc.import", {
      text: "# Mode test\n\nSynthetic paragraph.",
      docMode: "markdown",
    });
    result.startsInEditor = document.querySelector("#doc .preview").hidden;
    await receive("doc.toggleMode", {});
    result.firstTogglePreviews =
      !document.querySelector("#doc .preview").hidden &&
      !!document.querySelector("#doc .preview h1");
    result.buttonOffersEdit =
      document
        .querySelector("#doc .page-actions .icon-button")
        .getAttribute("aria-label") === "编辑";
    await receive("doc.toggleMode", {});
    result.secondToggleEdits = document.querySelector("#doc .preview").hidden;
    result.buttonOffersPreview =
      document
        .querySelector("#doc .page-actions .icon-button")
        .getAttribute("aria-label") === "预览";
    return result;
  }
  if (scenario === "storage") {
    await receive("screen.show", { page: "json" });
    await receive("tools.import", {
      page: "json",
      mode: "replace",
      text: '{"n":12345678901234567890,"f":0.1000}',
    });
    const original = text("tools");
    metaE();
    await until(() => !!document.querySelector("#tools .tree-root"));
    await receive("screen.show", { page: "qr" });
    result.jsonPreviewReleased =
      document.querySelector("#tools .preview").childElementCount === 0;
    await receive("screen.show", { page: "json" });
    await until(() => !!document.querySelector("#tools .tree-root"));
    result.jsonRestoredExactly =
      text("tools") === original &&
      original.includes("12345678901234567890") &&
      original.includes("0.1000");
    await receive("screen.hide", {});
    result.hiddenPreviewReleased =
      document.querySelector("#tools .preview").childElementCount === 0;
    await receive("screen.show", { page: "json" });
    await until(() => !!document.querySelector("#tools .tree-root"));
    result.restoredAfterNativePage = text("tools") === original;
    return result;
  }
  if (scenario === "limit") {
    await receive("screen.show", { page: "doc" });
    await receive("doc.import", {
      text:
        "# 超限样张\n\n" +
        Array(1800).fill("这是一段用于验证长图上限的正文。\n\n").join(""),
      docMode: "markdown",
    });
    document.querySelector('#doc [aria-label="截全图"]').click();
    await until(() =>
      document
        .querySelector("#doc .page-info")
        .textContent.includes("内容太长"),
    );
    result.limitRejectedWithoutTruncation = true;
    return result;
  }
  if (scenario === "perfjson") {
    await receive("screen.show", { page: "json" });
    const samples = [
      fixture,
      "[" + Array(5).fill(fixture.trim().slice(1, -1)).join(",") + "]",
    ];
    result.format = [];
    result.tree = [];
    for (const sample of samples) {
      const timings = [];
      for (let i = 0; i < 5; i++) {
        const started = performance.now();
        await receive("tools.import", {
          page: "json",
          text: sample,
          mode: "replace",
        });
        timings.push(performance.now() - started);
        if (sample === samples[0]) {
          const t = performance.now();
          metaE();
          await until(() => !!document.querySelector("#tools .tree-root"));
          result.tree.push(performance.now() - t);
          metaE();
        }
      }
      result.format.push({
        bytes: new TextEncoder().encode(sample).length,
        milliseconds: timings,
      });
    }
    // Delayed delivery isolates cancellation from machine-dependent worker speed.
    const OriginalWorker = window.Worker;
    window.Worker = class extends OriginalWorker {
      set onmessage(callback) {
        super.onmessage = callback
          ? (event) => setTimeout(() => callback(event), 1000)
          : null;
      }
    };
    const original = text("tools");
    await until(() => !document.querySelector("#tools .pill").disabled);
    document.querySelector("#tools .pill").click();
    await until(() =>
      Array.from(document.querySelectorAll("#tools .pill")).some(
        (b) => b.textContent === "取消" && !b.hidden,
      ),
    );
    const cancel = Array.from(document.querySelectorAll("#tools .pill")).find(
      (b) => b.textContent === "取消",
    );
    result.cancelAvailable = cancel && !cancel.hidden;
    cancel?.click();
    await delay(1000);
    result.cancelPreservesText = text("tools") === original;
    window.Worker = OriginalWorker;
    result.cancellationUsesDelayedRealWorker = true;
    return result;
  }
  if (scenario === "import") {
    const raw = "\r\nflowchart LR\r\n A --> B\n";
    await receive("screen.show", { page: "doc" });
    await receive("doc.import", {
      text: "# original",
      fileName: "original.md",
      docMode: "markdown",
    });
    await receive("doc.import", {
      text: raw,
      fileName: "diagram.mmd",
      docMode: "mermaid",
    });
    await receive("memory.flush", {});
    let saved = await window.webkit.messageHandlers.devbar.postMessage(
      JSON.stringify({
        v: 1,
        id: crypto.randomUUID(),
        type: "state.load",
        payload: { screen: "doc" },
      }),
    );
    saved = JSON.parse(saved).state;
    result.rawBytesPreserved = saved.text === raw;
    result.importLocked = saved.modeLocked && saved.docMode === "mermaid";
    const v = editor("doc");
    v.contentDOM.dispatchEvent(
      new KeyboardEvent("keydown", {
        key: "z",
        code: "KeyZ",
        keyCode: 90,
        metaKey: true,
        bubbles: true,
      }),
    );
    await delay(100);
    result.undoText = text("doc");
    result.undoFileHint =
      document.querySelector("#doc .file-label").textContent;
    document.querySelector('#doc [aria-label="清空"]').click();
    await delay(50);
    await receive("memory.flush", {});
    saved = JSON.parse(
      await window.webkit.messageHandlers.devbar.postMessage(
        JSON.stringify({
          v: 1,
          id: crypto.randomUUID(),
          type: "state.load",
          payload: { screen: "doc" },
        }),
      ),
    ).state;
    result.clearUnlocked = !saved.modeLocked && saved.docMode === "markdown";
    await receive("doc.import", {
      text: "",
      fileName: "empty.mmd",
      docMode: "mermaid",
    });
    await receive("memory.flush", {});
    saved = JSON.parse(
      await window.webkit.messageHandlers.devbar.postMessage(
        JSON.stringify({
          v: 1,
          id: crypto.randomUUID(),
          type: "state.load",
          payload: { screen: "doc" },
        }),
      ),
    ).state;
    result.emptyImportUnlocked =
      !saved.modeLocked && saved.docMode === "markdown";
    if (
      !result.rawBytesPreserved ||
      !result.importLocked ||
      result.undoText !== "# original" ||
      !result.undoFileHint.startsWith("original.md") ||
      !result.clearUnlocked ||
      !result.emptyImportUnlocked
    )
      throw Error("Import regression: " + JSON.stringify(result));
    return result;
  }
  if (scenario === "json") {
    await receive("screen.show", { page: "json" });
    const input =
      '{"integer":1234567890123456789,"integer20":12345678901234567890,"decimal":1.0,"exponent":1e10,"negativeZero":-0,"trailing":0.1000}';
    const v = editor("tools");
    v.dispatch({
      changes: { from: 0, to: v.state.doc.length, insert: input },
      userEvent: "input.paste",
    });
    await until(() => text("tools").includes("\n"));
    await delay(300);
    const trace = [{ step: "paste+format", text: text("tools") }];
    const pills = document.querySelectorAll("#tools .pill");
    for (const [index, name] of [
      [0, "compact"],
      [0, "format"],
      [1, "escape"],
      [1, "unescape"],
    ]) {
      const before = text("tools");
      pills[index].click();
      await until(() => text("tools") !== before);
      await delay(100);
      trace.push({ step: name, text: text("tools") });
    }
    metaE();
    await until(() => document.querySelector("#tools .tree-root"));
    document.querySelector("#tools .tree-toggle").click();
    document
      .querySelector("#tools .tree-root > .tree-row .tree-buttons button")
      .click();
    await delay(150);
    trace.push({ step: "tree+copy-request", text: text("tools") });
    const numbers = ["1234567890123456789", "1.0", "1e10", "-0", "0.1000"];
    result.trace = trace;
    result.lossless = trace.every((entry) =>
      numbers.every((number) => entry.text.includes(number)),
    );
    if (!result.lossless) throw Error("Number spelling changed");
    metaE();
    for (let i = 0; i < 12 && text("tools") !== input; i++) {
      editor("tools").contentDOM.dispatchEvent(
        new KeyboardEvent("keydown", {
          key: "z",
          code: "KeyZ",
          keyCode: 90,
          metaKey: true,
          bubbles: true,
        }),
      );
      await delay(30);
    }
    result.undoRestoresInput = text("tools") === input;
    trace.push({ step: "undo-to-original", text: text("tools") });
    metaE();
    await until(() => !!document.querySelector("#tools .tree-root"));
    document
      .querySelector("#tools .tree-root > .tree-row .tree-buttons button")
      .click();
    await delay(100);
    result.treeRows = document.querySelectorAll("#tools .tree-row").length;
  } else {
    await receive("screen.show", { page: "doc" });
    const started = performance.now();
    document.querySelector("#doc .page-actions .icon-button").click();
    await until(
      () =>
        !document.querySelector("#doc .preview").hidden &&
        document.querySelector("#doc .preview").textContent.length > 0,
      "document preview text",
    );
    result.firstTextMilliseconds = performance.now() - started;
    await until(
      () =>
        !Array.from(document.querySelectorAll("#doc .mmd")).some(
          (node) =>
            !node.querySelector("svg") && !node.classList.contains("mmd-error"),
        ),
      () =>
        `Mermaid render (${Array.from(document.querySelectorAll("#doc .mmd"))
          .filter(
            (node) =>
              !node.querySelector("svg") &&
              !node.classList.contains("mmd-error"),
          )
          .map((node) => node.dataset.src?.slice(0, 40).replace(/\s+/g, " "))
          .join(" | ")})`,
    );
    await new Promise(requestAnimationFrame);
    result.completeMilliseconds = performance.now() - started;
    result.diagrams = Array.from(document.querySelectorAll("#doc .mmd")).map(
      (node, index) => ({
        index,
        error: node.classList.contains("mmd-error"),
        width: node.querySelector("svg")?.getAttribute("width"),
        height: node.querySelector("svg")?.getAttribute("height"),
        background: window.getComputedStyle(node).backgroundColor,
      }),
    );
    result.highlightedBlocks =
      document.querySelectorAll("#doc pre.shiki").length;
    result.copyButtons = document.querySelectorAll("#doc .diagram-copy").length;
    result.externalPlaceholders = document.querySelectorAll(
      "#doc .external-image",
    ).length;
    const warm = [];
    for (let i = 0; i < 5; i++) {
      document.querySelector("#doc .page-actions .icon-button").click();
      const t = performance.now();
      document.querySelector("#doc .page-actions .icon-button").click();
      await new Promise(requestAnimationFrame);
      warm.push(performance.now() - t);
    }
    result.warmMilliseconds = warm;
    if (scenario === "memory") {
      await receive("tools.import", {
        page: "json",
        text: fixture,
        mode: "replace",
      });
      await receive("screen.show", { page: "json" });
      metaE();
      await until(() => !!document.querySelector("#tools .tree-root"));
      await receive("tools.import", {
        page: "qr",
        text: "DevBar 性能验收",
        mode: "replace",
      });
      await receive("screen.show", { page: "qr" });
      document.querySelector("#qr .page-actions .icon-button").click();
      await until(() => !!document.querySelector("#qr .preview img"));
      await receive("screen.show", { page: "doc" });
      await delay(5000);
      result.documentSurvivesPageSwitch = text("doc").includes("文稿排版样张");
      result.idleAfterAllPagesMilliseconds = 5000;
    }

    if (scenario === "catalog") {
      result.artifacts = [];
      for (const [index, node] of Array.from(
        document.querySelectorAll("#doc .mmd"),
      ).entries()) {
        const svg = node.querySelector("svg");
        if (!svg) continue;
        const image = new Image();
        image.src =
          "data:image/svg+xml;charset=utf-8," +
          encodeURIComponent(svg.outerHTML);
        await image.decode();
        const canvas = document.createElement("canvas");
        canvas.width = Math.ceil(Number(svg.getAttribute("width")) * 2);
        canvas.height = Math.ceil(Number(svg.getAttribute("height")) * 2);
        const context = canvas.getContext("2d");
        context.fillStyle = window
          .getComputedStyle(document.documentElement)
          .getPropertyValue("--snapshot-background")
          .trim();
        context.fillRect(0, 0, canvas.width, canvas.height);
        context.fillStyle = window.getComputedStyle(node).backgroundColor;
        context.fillRect(0, 0, canvas.width, canvas.height);
        context.drawImage(image, 0, 0, canvas.width, canvas.height);
        result.artifacts.push({
          index,
          pngBase64: canvas.toDataURL("image/png").split(",")[1],
        });
      }
    }

    const target =
      document.documentElement.dataset.theme === "dark"
        ? document.querySelector("#doc .mmd")
        : document.querySelector("#doc pre.shiki");
    if (scenario === "doc" && target)
      target.scrollIntoView({ block: "center" });
    if (scenario === "copy") {
      const button = document.querySelector("#doc .diagram-copy");
      button.click();
      await until(() => button.getAttribute("aria-label") === "已复制");
      result.copySucceeded = true;
    }
    if (scenario.startsWith("export")) {
      const exportStarted = performance.now();
      document.querySelector('#doc [aria-label="截全图"]').click();
      await until(() => !!document.querySelector(".snapshot-root"));
      const snapshot = document.querySelector(".snapshot-root");
      result.exportMeasure = {
        height: snapshot.scrollHeight,
        width: snapshot.clientWidth,
        lastText: snapshot.lastElementChild.textContent,
        lastTop:
          snapshot.lastElementChild.getBoundingClientRect().top -
          snapshot.getBoundingClientRect().top,
      };
      await until(
        () =>
          document
            .querySelector("#doc .page-info")
            .textContent.includes("已保存并复制") ||
          document
            .querySelector("#doc .page-info")
            .textContent.includes("无法生成") ||
          document
            .querySelector("#doc .page-info")
            .textContent.includes("长图生成失败"),
      );
      result.exportMilliseconds = performance.now() - exportStarted;
      result.exportMessage =
        document.querySelector("#doc .page-info").textContent;
    }
  }
  if (scenario === "memory") {
    await receive("memory.flush", {});
    result.memoryFlushClearsPreviews = {
      document: document.querySelector("#doc .preview").childElementCount === 0,
      json: document.querySelector("#tools .preview").childElementCount === 0,
      qr: document.querySelector("#qr .preview").childElementCount === 0,
    };
    await receive("screen.show", { page: "doc" });
    await until(
      () =>
        document.querySelectorAll("#doc .mmd:not(.mmd-error) svg").length ===
        22,
      "document preview restored after memory flush",
    );
    result.documentPreviewRestored = true;
    await receive("screen.show", { page: "json" });
    await until(
      () => !!document.querySelector("#tools .tree-root"),
      "JSON tree restored after memory flush",
    );
    result.jsonTreeRestored = true;
    await receive("screen.show", { page: "qr" });
    await until(
      () => !!document.querySelector("#qr .preview img"),
      "QR preview restored after memory flush",
    );
    result.qrPreviewRestored = true;
  } else {
    await receive("memory.flush", {});
  }
  return result;
}
