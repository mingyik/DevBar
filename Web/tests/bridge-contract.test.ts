import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { decodeEnvelope, encodeEnvelope } from "../src/bridge/envelope.ts";

const names = ["app.ready.json", "state.save.json", "theme.set.json"];

describe("bridge contract", () => {
  for (const name of names) {
    it(name, () => {
      const raw = readFileSync(
        new URL(`../../Samples/bridge/${name}`, import.meta.url).pathname,
        "utf8",
      ).trim();
      expect(encodeEnvelope(decodeEnvelope(raw))).toBe(raw);
    });
  }
});
