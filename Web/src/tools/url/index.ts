const unreserved = /^[A-Za-z0-9._~-]$/;
const reserved = /^[:/?#[\]@!$&'()*+,;=]$/;
const hex = /^[0-9a-f]{2}$/i;
function escaped(c: string) {
  return Array.from(
    new TextEncoder().encode(c),
    (b) => "%" + b.toString(16).toUpperCase().padStart(2, "0"),
  ).join("");
}
export function encodeComponent(s: string) {
  return Array.from(s, (c) => (unreserved.test(c) ? c : escaped(c))).join("");
}
export function encodeWhole(s: string) {
  let out = "";
  for (let i = 0; i < s.length;) {
    if (s[i] === "%" && hex.test(s.slice(i + 1, i + 3))) {
      out += s.slice(i, i + 3);
      i += 3;
      continue;
    }
    const c = String.fromCodePoint(s.codePointAt(i)!);
    out += unreserved.test(c) || reserved.test(c) ? c : escaped(c);
    i += c.length;
  }
  return out;
}
/** Error ranges are half-open UTF-16 offsets into the original input. */
export function decode(s: string) {
  let text = "";
  const errors: { start: number; end: number }[] = [];
  for (let i = 0; i < s.length;) {
    if (s[i] !== "%") {
      text += s[i++];
      continue;
    }
    const start = i;
    const bytes: number[] = [];
    while (s[i] === "%" && hex.test(s.slice(i + 1, i + 3))) {
      bytes.push(Number.parseInt(s.slice(i + 1, i + 3), 16));
      i += 3;
    }
    if (bytes.length) {
      try {
        text += new TextDecoder("utf-8", { fatal: true }).decode(
          new Uint8Array(bytes),
        );
      } catch {
        text += s.slice(start, i);
        errors.push({ start, end: i });
      }
    } else {
      i = Math.min(i + 3, s.length);
      text += s.slice(start, i);
      errors.push({ start, end: i });
    }
  }
  return { text, errors };
}
export function preview(s: string) {
  const m =
    /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/.exec(
      s,
    );
  if (!m) return null;
  const [, scheme, authority, path, query = "", fragment = ""] = m;
  const at = authority.lastIndexOf("@");
  const userinfo = at < 0 ? "" : authority.slice(0, at);
  const server = authority.slice(at + 1);
  const hostPort = server.startsWith("[")
    ? /^(\[[^\]]*\])(?::(.*))?$/.exec(server)
    : /^([^:]*)(?::(.*))?$/.exec(server);
  if (!hostPort) return null;
  const queryDecode = (v: string) => decode(v.replace(/\+/g, " ")).text;
  const parameters =
    query === ""
      ? []
      : query.split("&").map((item) => {
          const i = item.indexOf("=");
          return {
            key: queryDecode(i < 0 ? item : item.slice(0, i)),
            value: queryDecode(i < 0 ? "" : item.slice(i + 1)),
          };
        });
  return {
    scheme,
    userinfo,
    host: hostPort[1],
    port: hostPort[2] ?? "",
    path,
    query,
    fragment,
    parameters,
  };
}
