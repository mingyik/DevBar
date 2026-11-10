## 审核：R5 Codex——T3.3 补充（反转义空白）、T4.2 Markdown 预览管线与排版

结论：**通过**，已合并进 `main`。

分支 `codex/r5`：T3.3 补充 `8e61877`、T4.2 `6cf3d5d`。审核方：Claude。

### 已核实

- 新依赖：`markdown-it 15.0.3`（MIT）、`markdown-it-task-lists 2.1.1`（ISC）、`DOMPurify 3.4.17`（Apache-2.0 / MPL-2.0），版本锁死，许可证在 npm 上核对。公共文件只改了 `Web/package.json`、`package-lock.json`。
- 在临时副本里合并到最新 `main` 后运行 `Scripts/check.sh`：退出码 0，Swift 44 项、Web 218 项。正式构建产物里没有开发预览页。
- **管线安全**：markdown-it 输出先放进惰性的 `<template>`（不执行脚本、不加载图片），处理图片和表格后再交 DOMPurify，最后仍在 `<template>` 里拼装。自己在内置浏览器里用 17 种注入写法探测：`<img onerror>`、`javascript:` 链接（Markdown 和 HTML 两种）、`data:text/html` 链接、`<svg><script>`、`<svg onload>`、`<iframe>`、`<style>@import`、`style` 属性里的 `url()`、`<details ontoggle>`、MathML、`<form action>`、`<input type=image>`、伪造的 Mermaid 占位、Mermaid 代码块里的 HTML、`file:` 图片、`data:` SVG 图片——**没有任何脚本执行**，外部地址全部被去掉或替换为占位。
- **表格**：显式对齐先转成 class 再去掉 `style`；数字列识别只加 class，`007`、`12345678901234567890`、`0.1000`、`-42`、`1,234.50`、`+12.5%` 原样显示；显式对齐的数字列不被改成右对齐。
- **链接**：普通点击一律阻止；只有 ⌘ + 左键点击 `http(s)` 链接才回调宿主。
- **反转义补充**：不带引号的输入先去掉首尾空白，错误位置换算回原文，有测试。

### UI 审核（`Screenshots/R5/`，Chromium 静态排版）

整体符合方案 §3.2 和 UI 基准：灰阶、无彩色；标题靠字重区分；引用、任务列表勾选框、行内代码、代码块、分隔线、外部图片占位都到位；表格无竖线、表头加粗、宽表与长代码在卡片内横向滚动；白、黑两套都清楚。

### 并入后续轮次（不阻塞）

| 问题 | 处理 | 并入 |
|---|---|---|
| **长中文单元格在默认面板里被截断**：「长中文与空值」表的描述列按 `max-width: 28em` 撑到比面板还宽，要横向滚动才能读完每一行 | 单元格最大宽度改为随面板变化（例如默认面板约 18em、放大面板 26em，或用 `min(28em, 容器宽度的 70%)`），让长中文在可见宽度内换行；仍保留 `min-width: 4em` | R6 Codex（T4.6 文稿样张与截图）调整 `table.css` 并重截 |
| 白主题下行内代码的底色很淡，几乎看不出 | 行内代码底色改用 `panel.control` 或更深一级 | R6 Codex，同上 |

### 说明

- 截图是 Chromium 里的静态排版，不代表原生玻璃背景和 WKWebView 里的最终效果；WKWebView 集成验收在 R6（Grok 的 T4.1 接入后）。
- 允许原始 HTML 但去掉所有 `style` 属性：同意，比规格写的更严，能防止 CSS 加载外部资源。
- `markdown-it-task-lists 2.1.1` 是较老的插件（多年未更新），目前功能够用；如果之后与 markdown-it 新版本不兼容，再换同等插件。
