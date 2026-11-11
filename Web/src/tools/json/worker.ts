import { packResult } from "./transfer.ts";
import { execute } from "./protocol.ts";
import type { Request } from "./protocol.ts";
// Numeric lexemes cross only inside tagged transfer nodes.
if (typeof self !== "undefined" && typeof document === "undefined") {
  self.onmessage = (event: MessageEvent<Request>) =>
    self.postMessage(packResult(execute(event.data)));
}
