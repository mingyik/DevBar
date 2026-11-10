export function timestamp(
  input: string,
  timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone,
) {
  if (!/^(?:\d{10}|\d{13}|\d{16})$/.test(input)) return null;
  const seconds = BigInt(input.slice(0, 10));
  if (seconds < 946684800n || seconds >= 4102444800n) return null;
  const fraction = input.slice(10);
  const date = new Date(Number(seconds) * 1000);
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
    timeZoneName: "longOffset",
  }).formatToParts(date);
  const part = (name: string) =>
    parts.find((p) => p.type === name)?.value ?? "";
  const suffix = fraction ? `.${fraction}` : "";
  const offset = part("timeZoneName").replace("GMT", "") || "+00:00";
  const local = `${part("year")}-${part("month")}-${part("day")} ${part("hour")}:${part("minute")}:${part("second")}${suffix}`;
  return {
    local,
    utc: date.toISOString().slice(0, 19).replace("T", " ") + suffix + " UTC",
    iso: local.replace(" ", "T") + offset,
    timeZone,
    offset,
  };
}
