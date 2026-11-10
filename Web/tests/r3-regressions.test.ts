import { existsSync, readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { detect } from "../src/tools/detect";
import { decode as base64, encode } from "../src/tools/base64";
import { decode as url } from "../src/tools/url";

it("R2 comparison probes", () => {
  const log = detect("[TODO] fix bug");
  const binary = base64("AAECAwQFBgc=");
  const percent = url("%FF%41");
  console.log("R2 comparison", { log, binary, percent });
  expect(log).toEqual({ type: "text" });
  expect(binary).toEqual({ kind: "binary", bytes: 8 });
  expect(percent).toEqual({ text: "%FFA", errors: [{ start: 0, end: 3 }] });
});
it.skipIf(!existsSync("/usr/share/dict/words"))(
  "dictionary false positives <= 10",
  () => {
    const words = readFileSync("/usr/share/dict/words", "utf8")
      .split(/\r?\n/)
      .filter((w) => w.length >= 8);
    const count = words.filter((w) => detect(w).type === "base64").length;
    console.log("dictionary regression", {
      words: words.length,
      falsePositives: count,
    });
    expect(count).toBeLessThanOrEqual(10);
  },
);
it.each(["[ERROR] connection refused", "{name}"])("ordinary log %s", (s) =>
  expect(detect(s)).toEqual({ type: "text" }),
);
it.each(['{"x": @@@ @@@', "[1, @@@ @@@", "{ x: @@@ @@@"])(
  "broken structured content %s",
  (s) => expect(detect(s).type).toBe("json"),
);
it.each(["acerbity", "Acerbity"])("word exclusion %s", (s) =>
  expect(detect(s).type).toBe("text"),
);
it.each(["\u0080hello", "hello\u009f"])("C1 not detected as readable %s", (s) =>
  expect(detect(encode(s)).type).toBe("text"),
);
it.each(["\u0000", "\u0007", "\u001f"])("C0 decoded as binary %s", (s) =>
  expect(base64(encode(s))).toEqual({ kind: "binary", bytes: 1 }),
);
it("tabs and line endings remain text", () =>
  expect(base64(encode("a\t\n\rb"))).toEqual({
    kind: "text",
    text: "a\t\n\rb",
  }));
it.each([
  ["%FF%41", "%FFA", [{ start: 0, end: 3 }]],
  ["%E4%B8%41", "%E4%B8A", [{ start: 0, end: 6 }]],
  ["%41%FF%E4%B8%AD", "A%FF中", [{ start: 3, end: 6 }]],
  ["%C0%AF%41", "%C0%AFA", [{ start: 0, end: 6 }]],
  ["%ED%A0%80%41", "%ED%A0%80A", [{ start: 0, end: 9 }]],
  ["%F4%90%80%80%41", "%F4%90%80%80A", [{ start: 0, end: 12 }]],
])("byte-precise URL %s", (s, text, errors) =>
  expect(url(s)).toEqual({ text, errors }),
);
