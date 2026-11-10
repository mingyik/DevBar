import { Worker } from "node:worker_threads";
import { expect, it } from "vitest";
import { startTransform } from "../src/tools/json/client.ts";
import type { WorkerPort } from "../src/tools/json/client.ts";
import type { Result } from "../src/tools/json/protocol.ts";
import { compact } from "../src/tools/json/core.ts";

function nativeWorker(onStarted = () => {}): WorkerPort {
  const moduleURL = new URL("../src/tools/json/worker.ts", import.meta.url)
    .href;
  // Only the transport is adapted; the actual production worker.ts executes unchanged.
  const code = `import {parentPort} from 'node:worker_threads';
 globalThis.self={postMessage: data=>parentPort.postMessage(data)};
 await import(${JSON.stringify(moduleURL)});
 parentPort.on('message', data=>{parentPort.postMessage('started');self.onmessage({data});});
 parentPort.postMessage('ready');`;
  const worker = new Worker(
    new URL("data:text/javascript," + encodeURIComponent(code)),
  );
  let ready: () => void = () => {};
  const loaded = new Promise<void>((resolve) => {
    ready = resolve;
  });
  const port: WorkerPort = {
    onmessage: null,
    onerror: null,
    postMessage: (request) => {
      void loaded.then(() => worker.postMessage(request));
    },
    terminate: () => {
      void worker.terminate();
    },
  };
  worker.on("message", (data) => {
    if (data === "ready") ready();
    else if (data === "started") onStarted();
    else port.onmessage?.({ data: data as Result });
  });
  worker.on("error", () => port.onerror?.());
  return port;
}
const row = '{"big":12345678901234567890,"d":1.0,"e":1e10,"n":-0,"f":0.1000}';
function sample10MB() {
  const count = Math.ceil((10 * 1024 * 1024 - 2) / (row.length + 1));
  return "[" + Array(count).fill(row).join(",") + "]";
}
it("10MB formats in a real worker and preserves every numeric lexeme", async () => {
  const input = sample10MB();
  const start = performance.now();
  const result = await startTransform("format", input, {
    workerFactory: () => nativeWorker(),
  }).result;
  const elapsed = performance.now() - start;
  expect(result.status).toBe("success");
  expect(compact(result.text)).toBe(input);
  console.log("10MB worker benchmark", {
    inputBytes: new TextEncoder().encode(input).length,
    outputBytes: result.text.length,
    elapsedMs: elapsed,
  });
}, 30000);
it("real worker cancellation after start returns original bytes unchanged", async () => {
  const input = sample10MB();
  const job = startTransform("format", input, {
    workerFactory: () => nativeWorker(() => job.cancel()),
  });
  expect(await job.result).toEqual({ status: "cancelled", text: input });
}, 30000);
