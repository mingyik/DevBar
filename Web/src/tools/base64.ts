export type Decoded =
  | { kind: "text"; text: string }
  | { kind: "binary"; bytes: number }
  | { kind: "invalid" };
export function encode(text: string): string {
  return btoa(
    Array.from(new TextEncoder().encode(text), (b) =>
      String.fromCharCode(b),
    ).join(""),
  );
}
export function decode(text: string): Decoded {
  const s = text.replace(/\s/g, "");
  if (!/^(?:[A-Za-z0-9+/]*|[A-Za-z0-9_-]*)={0,2}$/.test(s))
    return { kind: "invalid" };
  const bare = s.replace(/=+$/, "");
  if (bare.length % 4 === 1 || (s.includes("=") && s.length % 4 !== 0))
    return { kind: "invalid" };
  try {
    const raw = atob(
      bare
        .replace(/-/g, "+")
        .replace(/_/g, "/")
        .padEnd(Math.ceil(bare.length / 4) * 4, "="),
    );
    const bytes = Uint8Array.from(raw, (c) => c.charCodeAt(0));
    try {
      return {
        kind: "text",
        text: new TextDecoder("utf-8", { fatal: true }).decode(bytes),
      };
    } catch {
      return { kind: "binary", bytes: bytes.length };
    }
  } catch {
    return { kind: "invalid" };
  }
}
