import { execute } from "./protocol.ts";
import type { Request } from "./protocol.ts";
// No parsed objects cross the boundary: numeric lexemes remain in text throughout.
if (typeof self !== "undefined" && typeof document === "undefined") {
  self.onmessage = (event: MessageEvent<Request>) =>
    self.postMessage(execute(event.data));
}
