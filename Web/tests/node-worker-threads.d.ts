// Test-only subset: browser source remains independent of Node APIs.
declare module "node:worker_threads" {
  export class Worker {
    constructor(url: URL);
    on(type: "message", callback: (data: unknown) => void): this;
    on(type: "error", callback: () => void): this;
    postMessage(data: unknown): void;
    terminate(): Promise<number>;
  }
}
