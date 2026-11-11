import { encodeEnvelope, type JSONValue } from "./envelope";
export type NativeReply = Record<string, unknown>;
export async function post(
  type: string,
  payload: Record<string, JSONValue> = {},
): Promise<NativeReply> {
  const raw = await window.webkit?.messageHandlers.devbar.postMessage(
    encodeEnvelope({ v: 1, id: crypto.randomUUID(), type, payload }),
  );
  if (!raw) return {};
  const reply: unknown = JSON.parse(raw);
  return reply && typeof reply === "object" && !Array.isArray(reply)
    ? (reply as NativeReply)
    : {};
}

declare global {
  interface Window {
    webkit?: {
      messageHandlers: {
        devbar: { postMessage: (body: string) => Promise<string> };
      };
    };
  }
}
