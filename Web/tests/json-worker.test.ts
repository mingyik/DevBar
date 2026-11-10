import { afterEach, expect, it, vi } from "vitest";
import { startTransform } from "../src/tools/json/client.ts";
import type { WorkerPort } from "../src/tools/json/client.ts";
const large = " ".repeat(1024 * 1024) + "{}";
function fakeWorker() {
  const port: WorkerPort = {
    onmessage: null,
    onerror: null,
    postMessage: vi.fn(),
    terminate: vi.fn(),
  };
  return port;
}
afterEach(() => vi.useRealTimers());
it("small input runs without a worker", async () => {
  const factory = vi.fn();
  expect(
    await startTransform("compact", '{ "x":1.0 }', { workerFactory: factory })
      .result,
  ).toEqual({ status: "success", text: '{"x":1.0}' });
  expect(factory).not.toHaveBeenCalled();
});
it("large input waits for worker and emits slow signal only after 300ms", async () => {
  vi.useFakeTimers();
  const port = fakeWorker(),
    onSlow = vi.fn();
  const job = startTransform("format", large, {
    workerFactory: () => port,
    onSlow,
  });
  expect(port.postMessage).toHaveBeenCalledWith({
    operation: "format",
    text: large,
  });
  await vi.advanceTimersByTimeAsync(299);
  expect(onSlow).not.toHaveBeenCalled();
  await vi.advanceTimersByTimeAsync(1);
  expect(onSlow).toHaveBeenCalledOnce();
  port.onmessage?.({ data: { status: "success", text: "{}" } });
  expect(await job.result).toEqual({ status: "success", text: "{}" });
  expect(port.terminate).toHaveBeenCalledOnce();
});
it("cancel terminates and preserves original, ignoring a late completion", async () => {
  vi.useFakeTimers();
  const port = fakeWorker(),
    onSlow = vi.fn();
  const job = startTransform("format", large, {
    workerFactory: () => port,
    onSlow,
  });
  const late = port.onmessage;
  job.cancel();
  job.cancel();
  late?.({ data: { status: "success", text: "replaced" } });
  expect(await job.result).toEqual({ status: "cancelled", text: large });
  expect(port.terminate).toHaveBeenCalledOnce();
  await vi.advanceTimersByTimeAsync(500);
  expect(onSlow).not.toHaveBeenCalled();
});
it("worker crash preserves input", async () => {
  const port = fakeWorker();
  const job = startTransform("format", large, { workerFactory: () => port });
  port.onerror?.();
  expect((await job.result).text).toBe(large);
  expect((await job.result).status).toBe("error");
  expect(port.terminate).toHaveBeenCalledOnce();
});
it("worker creation failure preserves input", async () => {
  const job = startTransform("format", large, {
    workerFactory: () => {
      throw new Error("unavailable");
    },
  });
  expect((await job.result).status).toBe("error");
  expect((await job.result).text).toBe(large);
});
it("small invalid input returns original with diagnostic", async () => {
  const result = await startTransform("format", '{"x":}').result;
  expect(result.status).toBe("error");
  expect(result.text).toBe('{"x":}');
});
it("threshold uses UTF-8 bytes, not UTF-16 length", () => {
  const port = fakeWorker();
  const job = startTransform("format", "中".repeat(400000), {
    workerFactory: () => port,
  });
  expect(port.postMessage).toHaveBeenCalled();
  job.cancel();
});
