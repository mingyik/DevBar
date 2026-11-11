import { isLosslessNumber, LosslessNumber } from "lossless-json";
import type { Result } from "./protocol.ts";
type Wire =
  ["n", string] | ["a", Wire[]] | ["o", [string, Wire][]] | ["v", unknown];
function pack(value: unknown): Wire {
  if (isLosslessNumber(value)) return ["n", value.value];
  if (Array.isArray(value)) return ["a", value.map(pack)];
  if (value !== null && typeof value === "object")
    return ["o", Object.entries(value).map(([key, item]) => [key, pack(item)])];
  return ["v", value];
}
function unpack(wire: Wire): unknown {
  switch (wire[0]) {
    case "n":
      return new LosslessNumber(wire[1]);
    case "a":
      return wire[1].map(unpack);
    case "o":
      return Object.fromEntries(
        wire[1].map(([key, item]) => [key, unpack(item)]),
      );
    case "v":
      return wire[1];
  }
}
// Structured clone drops the library's Symbol marker/prototype. Encode every node
// explicitly so user objects that resemble numbers cannot be mistaken for numbers.
export function packResult(result: Result): Result {
  return result.status === "success" && "value" in result
    ? { ...result, value: pack(result.value) }
    : result;
}
export function unpackResult(result: Result): Result {
  return result.status === "success" && "value" in result
    ? { ...result, value: unpack(result.value as Wire) }
    : result;
}
