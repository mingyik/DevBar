import { execute } from "./protocol.ts";
import type { Operation, Request, Result } from "./protocol.ts";
export interface WorkerPort {
  onmessage: ((event: { data: Result }) => void) | null;
  onerror: (() => void) | null;
  postMessage(request: Request): void;
  terminate(): void;
}
export type TransformOptions = {
  workerFactory?: () => WorkerPort;
  onSlow?: () => void;
};
function browserWorker(): WorkerPort {
  const worker = new Worker(new URL("./worker.ts", import.meta.url), {
    type: "module",
  });
  const port: WorkerPort = {
    onmessage: null,
    onerror: null,
    postMessage: (request) => worker.postMessage(request),
    terminate: () => worker.terminate(),
  };
  worker.onmessage = (event) =>
    port.onmessage?.({ data: event.data as Result });
  worker.onerror = () => port.onerror?.();
  return port;
}
/** Caller applies only success results as one undoable editor transaction. */
export function startTransform(
  operation: Operation,
  text: string,
  options: TransformOptions = {},
) {
  if (new TextEncoder().encode(text).length <= 1024 * 1024) {
    return {
      result: Promise.resolve(execute({ operation, text })),
      cancel: () => {},
    };
  }
  let cancel = () => {};
  const result = new Promise<Result>((resolve) => {
    let worker: WorkerPort | undefined;
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (reply: Result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (worker) {
        worker.onmessage = null;
        worker.onerror = null;
        worker.terminate();
      }
      resolve(reply);
    };
    cancel = () => finish({ status: "cancelled", text });
    const fail = () =>
      finish({
        status: "error",
        text,
        error: { offset: 0, line: 1, column: 1, message: "后台转换失败" },
      });
    try {
      worker = options.workerFactory?.() ?? browserWorker();
      worker.onmessage = (event) => finish(event.data);
      worker.onerror = fail;
      timer = setTimeout(() => options.onSlow?.(), 300);
      worker.postMessage({ operation, text });
    } catch {
      fail();
    }
  });
  return { result, cancel: () => cancel() };
}
