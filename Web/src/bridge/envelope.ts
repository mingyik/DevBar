export type JSONValue =
  null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };

export type Envelope = {
  v: number;
  id: string;
  type: string;
  payload: { [key: string]: JSONValue };
};

export function decodeEnvelope(raw: string): Envelope {
  const value = JSON.parse(raw) as Envelope;
  if (
    value.v !== 1 ||
    typeof value.id !== "string" ||
    typeof value.type !== "string"
  ) {
    throw new Error("bad envelope");
  }
  if (
    value.payload === null ||
    typeof value.payload !== "object" ||
    Array.isArray(value.payload)
  ) {
    throw new Error("bad payload");
  }
  return value;
}

export function encodeEnvelope(envelope: Envelope): string {
  return canonical({
    v: envelope.v,
    id: envelope.id,
    type: envelope.type,
    payload: envelope.payload,
  });
}

function canonical(value: JSONValue): string {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number")
    return Number.isInteger(value) ? String(value) : String(value);
  if (typeof value === "string") return quoted(value);
  if (Array.isArray(value))
    return `[${value.map((item) => canonical(item)).join(",")}]`;
  const body = Object.keys(value)
    .sort()
    .map((key) => `${quoted(key)}:${canonical(value[key] ?? null)}`);
  return `{${body.join(",")}}`;
}

function quoted(value: string): string {
  let out = '"';
  for (const char of value) {
    switch (char) {
      case '"':
        out += '\\"';
        break;
      case "\\":
        out += "\\\\";
        break;
      case "\b":
        out += "\\b";
        break;
      case "\f":
        out += "\\f";
        break;
      case "\n":
        out += "\\n";
        break;
      case "\r":
        out += "\\r";
        break;
      case "\t":
        out += "\\t";
        break;
      default:
        out += char;
        break;
    }
  }
  return `${out}"`;
}
