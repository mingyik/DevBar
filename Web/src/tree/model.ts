import { isLosslessNumber, stringify } from "lossless-json";
import { escapeJsonString } from "../tools/json/core";
export function container(
  value: unknown,
): value is Record<string, unknown> | unknown[] {
  return (
    value !== null && typeof value === "object" && !isLosslessNumber(value)
  );
}
export function copyValue(value: unknown): string {
  if (typeof value === "string") return value;
  return stringify(value, null, 2) ?? "";
}
export function childPath(parent: string, key: string | number): string {
  if (typeof key === "number") return `${parent}[${key}]`;
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(key)
    ? `${parent}.${key}`
    : `${parent}[${escapeJsonString(key)}]`;
}
export function summary(value: unknown): string {
  if (isLosslessNumber(value)) return value.value;
  if (container(value))
    return `${Array.isArray(value) ? "[…]" : "{…}"} ${Object.keys(value).length}`;
  if (typeof value === "string")
    return escapeJsonString(
      value.length > 80 ? value.slice(0, 80) + "…" : value,
    );
  return stringify(value) ?? "";
}
