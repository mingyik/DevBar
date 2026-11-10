import { defineConfig } from "vite";

export default defineConfig({
  build: {
    outDir: "dist",
    emptyOutDir: true,
    // Vite 默认注入的 modulepreload polyfill 会调用 fetch，违反不联网红线。
    modulePreload: false,
  },
});
