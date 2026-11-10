# AGENTS.md · DevBar 实现者须知

> 给 Codex / Grok 等实现者。每次开工前完整读一遍。

## 项目一句话

DevBar 是一个 macOS 菜单栏小工具（内部自用），四个大块：剪贴板、工具（JSON / URL / Base64 / 时间戳）、文稿（Markdown + Mermaid）、截图录屏。方向是**快捷、极致、小而美**。

## 文档

| 文件 | 作用 |
|---|---|
| `菜单栏工具方案.md` | 产品方案（第 9 版，定稿）。**产品行为以它为准** |
| `docs/实现规格.md` | 施工图：工程结构、接口、算法、任务单。**工程做法以它为准** |
| `docs/审核清单.md` | 审核标准。交付前自己先按它检查一遍 |
| `docs/UI基准.md` | 面板外观标准（玻璃、页签栏、卡片），**改界面前必读**；与实现规格 §6.2、§6.3 冲突时以它为准 |
| `docs/分工与轮次.md` | 谁做哪一轮、工作目录与分支、谁审核 |
| `docs/审核记录/` | 每轮的审核结论，含「并入下一轮」的事项 |
| `docs/验证记录/` | 第 1 期验证结论 |
| `Reference/Vorssaint/` | 参考源码（GPL-3.0），**只读，不参与构建** |

## 工作方式

**分工、轮次、工作目录、分支、谁审核，见 `docs/分工与轮次.md`。**

1. 只做分配给你的这一轮任务（`docs/分工与轮次.md` §4），任务内容按 `docs/实现规格.md` §10。
2. **只在自己的工作目录和分支上工作**（Grok：`~/Desktop/DevBar-grok`；Codex：`~/Desktop/DevBar-codex`）。不在 `~/Desktop/DevBar` 里改代码，不自己合并进 `main`。
3. 只改本轮任务涉及的目录；需要改公共文件时在回报里单独列出。
4. 做完运行 `Scripts/check.sh`，提交时逐个列出文件（不用 `git add -A` / `git add .`），不修改 git 作者配置。按 `docs/实现规格.md` §11 的格式回报，开头写明轮次、分支名、提交号。
5. 回报后停下，**审核通过、合并进 `main` 前不开始下一轮**。
6. 上一轮审核记录里「并入下一轮」的小问题，在你的下一轮里一并处理。
7. 规格有歧义或做不到：停下来，在回报的「与规格的差异」里写清楚，不要自行扩展或删减功能。

## 红线（违反任何一条，审核直接不通过）

1. **不加功能。** 不加回已删的功能：树编辑、JSON 查询 / 排序 / 表格视图、文件打开保存、导出、独立编辑窗口、搜索剪贴板、置顶、窗口截图、全屏截图、标注、录屏剪辑、GIF、自动滚动长图、直接粘贴（模拟按键）。
2. **不联网。** Swift 不发外部请求；Web 不用 `fetch` / `XMLHttpRequest` / `WebSocket` / `EventSource`。
3. **只有黑白。** 业务代码不写字面颜色值，只用 `design/tokens.json` 生成的变量。唯一的彩色例外：剪贴板里颜色值的色块。识别颜色文本、必须写颜色字面量或颜色正则时，同一行加上 `// devbar:allow-color`，字面颜色检查会跳过该行。
4. **不猜改内容。** 自动行为不覆盖、不改写用户内容：不合法的 JSON 不自动修复；编辑区有内容时不自动导入；数字识别只用于排版。
5. **JSON 数字无损。** `Web/src/tools/`、`Web/src/tree/` 禁止原生 `JSON.parse` / `JSON.stringify`，只用 lossless-json。JSON 正文跨桥只作为字符串，Swift 不解析。
6. **安全设置不放宽。** CSP 不加 `unsafe-eval` / `wasm-unsafe-eval`；不用 `eval` / `new Function`；Mermaid 保持 `securityLevel: "strict"`。
7. **不需要辅助功能权限。** 不调用 `AXIsProcessTrusted`、不模拟按键（`CGEvent` post）。
8. **不用 Vorssaint 的品牌。** 名字、图标、bundle id、文案都不能出现在 DevBar 里。从 Reference 抽取的代码保留原 GPL 版权头，并加一行 `// Adapted for DevBar.`。
9. **不记录用户内容。** 日志里不出现剪贴板、工具、文稿的内容，只记事件和长度。
10. **依赖锁版本。** npm 写死版本号（不用 `^` `~`），Swift 包用 `.exact`。新增依赖必须在回报里说明理由，并经审核同意。

## 常用命令

```bash
Scripts/check.sh                 # 全部检查：lint + 构建 + 测试 + tokens 一致性
Scripts/build-app.sh             # 组装 build/DevBar.app（debug）
Scripts/build-app.sh release     # release 构建
swift test                       # 只跑 Swift 测试
cd Web && npm test               # 只跑 Web 测试
cd Web && npm run build          # 只构建前端
node Scripts/gen-tokens.ts       # 由 design/tokens.json 重新生成各端变量（以实际脚本运行方式为准）
```

签名：设置环境变量 `DEVBAR_SIGN_IDENTITY` 为本机的 Apple Development 证书名，权限才不会每次构建后失效。

## 代码约定

- Swift 6 严格并发；UI 类型 `@MainActor`；存储用 `actor`；状态用 `@Observable`。
- `DevBarCore` 不 import AppKit / SwiftUI / WebKit / ScreenCaptureKit。
- 界面文字中文，集中在 `Sources/DevBar/Strings.swift` 和 `Web/src/strings.ts`。
- Web 不用 UI 框架；TypeScript `strict`；编辑器内容的修改都走 CodeMirror 事务（带 `userEvent`），保证可撤销。
- 提交信息以任务编号开头，例如 `T2.3 剪贴板列表界面`。

## 回报格式

见 `docs/实现规格.md` §11。必须包含：做了什么、与规格的差异、`check.sh` 输出末尾、验收项逐条证据、遗留问题。
