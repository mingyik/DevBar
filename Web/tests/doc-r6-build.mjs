/** Run from Web: node tests/doc-r6-build.mjs. Measures the web module before native integration. */
import { build } from "vite";
import { Buffer } from "node:buffer";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve, join } from "node:path";
import { gzipSync } from "node:zlib";
const output = mkdtempSync(join(tmpdir(), "devbar-r6-bundle-"));
const chunks = [];
await build({
  configFile: false,
  build: {
    outDir: output,
    modulePreload: false,
    minify: true,
    rollupOptions: {
      input: {
        document: resolve("src/doc/document.ts"),
        highlight: resolve("src/doc/highlight.ts"),
      },
      preserveEntrySignatures: "strict",
      output: { format: "es" },
      plugins: [
        {
          name: "measure",
          generateBundle(_options, bundle) {
            for (const [name, chunk] of Object.entries(bundle))
              if (chunk.type === "chunk") {
                const modules = Object.keys(chunk.modules);
                chunks.push({
                  name,
                  bytes: Buffer.byteLength(chunk.code),
                  gzip: gzipSync(chunk.code).byteLength,
                  groups: [
                    ...new Set(
                      modules.flatMap((id) =>
                        id.includes("@shikijs/langs/")
                          ? ["shiki-languages"]
                          : /shiki|oniguruma-to-es|regex-recursion|regex-utilities/.test(
                                id,
                              )
                            ? ["shiki-core"]
                            : id.includes("mermaid/")
                              ? ["mermaid"]
                              : [],
                      ),
                    ),
                  ],
                  imports: chunk.imports,
                  dynamicImports: chunk.dynamicImports,
                });
              }
          },
        },
      ],
    },
  },
});
chunks.sort((a, b) => b.bytes - a.bytes);
function closure(roots) {
  const found = new Map();
  function visit(name) {
    if (found.has(name)) return;
    const chunk = chunks.find((c) => c.name === name);
    if (!chunk) return;
    found.set(name, chunk);
    chunk.imports.forEach(visit);
  }
  roots.forEach(visit);
  return {
    files: [...found.keys()],
    bytes: [...found.values()].reduce((s, c) => s + c.bytes, 0),
    gzip: [...found.values()].reduce((s, c) => s + c.gzip, 0),
  };
}
const budgets = {
  shikiCore: closure(
    chunks
      .filter((c) => c.name.startsWith("assets/highlight-"))
      .map((c) => c.name),
  ),
  shikiLanguages: closure(
    chunks
      .filter((c) => c.groups.includes("shiki-languages"))
      .map((c) => c.name),
  ),
  mermaidFirstLoad: closure(
    chunks
      .filter((c) => c.name.startsWith("assets/mermaid.core-"))
      .map((c) => c.name),
  ),
};
writeFileSync(
  "../Samples/R6-bundle.json",
  JSON.stringify(
    {
      budgets,
      method:
        "Vite production ES module build, minified, gzip level default; shared chunks counted once in total",
      total: chunks.reduce(
        (a, c) => ({ bytes: a.bytes + c.bytes, gzip: a.gzip + c.gzip }),
        { bytes: 0, gzip: 0 },
      ),
      chunks,
    },
    null,
    2,
  ) + "\n",
);
