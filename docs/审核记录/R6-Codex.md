## 审核：R6 Codex——T4.2 排版补充、T4.3 Shiki、T4.4 Mermaid 与灰阶配色、T4.7 纯 Mermaid 识别

结论：**通过**，已合并进 `main`（合并提交 `df4caef`）。

分支 `codex/r6`，比较范围 `50bfb1d..5646b38`：`88d88fa` T4.2 排版补充、`78a43b0` T4.3 Shiki、`8d6fc1e` T4.4 Mermaid 与灰阶配色、`7145668` T4.7 纯 Mermaid 识别 / 预览与异步提交保护、`5646b38` 样张、布局比较及回报。审核方：Claude。

### 已核实

- **检查脚本**：
  - 在 `5646b38` 的临时副本里运行 `Scripts/check.sh`，退出码 0，Swift 44 项、Web 309 项。
  - 合并进 `main` 后：`Web/package.json` 与 T1.4 的 CodeMirror 依赖冲突，按并集合并，锁文件重新生成。重跑退出码 0，Swift 47 项、Web 312 项。
- **Shiki**：
  - 用的是 `shiki/core` + `createJavaScriptRegexEngine()`，15 种指定语言单独引入，主题用生成的白、黑两份。
  - 高亮器首次需要时创建，之后复用。创建失败只提示一次，之后显示转义后的原文。
  - 高亮在 DOMPurify 清洗之后，只替换 `pre.code.plain[data-lang]`，不放宽清洗规则。
- **Mermaid 安全**：
  - `securityLevel: "strict"`。`secure` 列表包含 theme、themeVariables、themeCSS、look、fontFamily、darkMode、htmlLabels、layout 等。
  - 浏览器实测：frontmatter 和 `%%{init}%%` 两种写法都改不了主题、外观、字体、暗色、htmlLabels、主色，不需要 `stripThemeConfig`。
  - 作者用 `classDef` / `style` 写的颜色在白、黑两套里都保留。
- **灰阶**：新增设计变量和生成的 `mermaid-vars.ts` 只有灰阶。Journey、Sankey、C4 的适配只在对应图种生效。C4 写了 `Update*Style` 时跳过适配。
- **尺寸与错误**：
  - SVG 按 viewBox 写死宽高，去掉 `max-width`，宽图横向滚动。
  - 一张图出错只在该图位置显示错误卡片，其他图继续渲染。
  - 渲染排成串行队列，因为 Mermaid 的 `initialize` 是全局的。
  - 每个容器有版本号，旧的异步结果不会覆盖新内容或新主题。
- **PNG**：2 倍、不透明背景，base64 前缀正确。只生成图片数据，复制由宿主负责。
- **口径**：
  - 许可证如实写明 elkjs 是 EPL-2.0 或 GPL-3.0 双许可。
  - 体积说明是压缩后 JS 字节，共享块不能相加。
  - 耗时说明是 Chromium 开发服务器、有 HTTP 缓存，不等于 WKWebView 冷启动。

### 布局定案：流程图、状态图都用 **Dagre**

- **尺寸**：对照 `Screenshots/R6/layout-*.png`，两者几乎相同。流程图 622×220 对 630×219，状态图 338×282 对 328×252。
- **ELK 的观感**：折线更规整，但流程图里两条线的箭头挤在终点同一处，没有明显优势。
- **ELK 的成本**：多约 2MB 的按需块，许可证也不在审核清单 A3 允许的范围内。
- **已同步**：规格 §8.13 和方案的「布局显式指定」已改为定案。

### 并入下一轮（Codex，R7 开头）

| 级别 | 问题 | 定位与复现 | 修改 |
|---|---|---|---|
| P2 | ELK 依赖和代码路径留在正式代码里 | `Web/package.json` 的 `@mermaid-js/layout-elk`；`mermaid.ts` 的 `Layout` 类型与 `elk` 懒加载；对照页的 `layout` 参数 | 全部删掉，`LAYOUT` 固定为 `"dagre"`，锁文件同步 |
| P2 | 纯 Mermaid 识别会把普通英文开头的文稿判成图（**规格漏洞，Codex 是按规格实现的**） | 全文以 `timeline of the project…`、`pie charts are…`、`journey to…`、`block …`、`graph is…` 开头时，整篇被当成一张出错的图 | 按规格 §8.11.1 新增的第 3a 条收紧，补对应反例测试 |
| P3 | 未使用的依赖 | `@shikijs/themes 4.6.0`，代码只用生成的主题 | 删掉 |
| P3 | PNG 尺寸上限按 1 倍算，实际画布是 2 倍 | `svgToPngBase64` | 按放大后的宽高检查，并限制单边长度 |
| P3 | C4 适配会覆盖作者在参数里写的颜色 | `Rel(..., $lineColor="…")`、`Person(..., $fontColor=…)` 写的颜色被全局 stroke / fill 换掉 | 源码出现 `$…Color=` 时也跳过适配 |

### 说明

- 这一轮只做网页模块。`devbar://`、WKWebView 里的 JS 正则兼容和耗时、原生玻璃背景、模式按钮与锁定界面，留给接入轮次（R9 文稿界面），不算本轮缺陷。
- 截图是 Chromium 长页静态排版，文件命名不是 UI 基准 §5 的 5 张标准。接入原生面板后按 §5 重截。
- 合并时为了让依赖装上，在 `main` 上重新运行了 `npm ci`。`check.sh` 的自动 `npm ci` 这次没有触发：锁文件是用 `--package-lock-only` 重新生成的，`node_modules` 里的记录可能也被一起更新，以后合并依赖冲突后手动跑一次 `npm ci`。
