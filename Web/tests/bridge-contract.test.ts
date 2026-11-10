import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { decodeEnvelope, encodeEnvelope } from "../src/bridge/envelope.ts";

const samples = join(dirname(fileURLToPath(import.meta.url)), "../../Samples/bridge");

describe("bridge contract", () => {
  for (const name of readdirSync(samples).filter((file) => file.endsWith(".json"))) {
    it(name, () => {
      const raw = readFileSync(join(samples, name), "utf8").trim();
      const decoded = decodeEnvelope(raw);
      expect(encodeEnvelope(decoded)).toBe(raw);
    });
  }
});
