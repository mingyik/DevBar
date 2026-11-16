# AGENTS.md · DevBar 实现者须知

> 给项目维护者与编码助手。每次开工前完整读一遍。

## 项目一句话

DevBar 是一个 macOS 菜单栏小工具（内部自用），四个大块：剪贴板、工具（JSON / URL / Base64 / 二维码，各占一页）、文稿（Markdown + Mermaid）、截图与长图。方向是**快捷、极致、小而美**。

## 文档

| 文件 | 作用 |
|---|---|
| `菜单栏工具方案.md` | 当前产品方案。**需求方最新明确要求优先；文档与代码不一致时先核对，不按旧描述回退已确认功能** |
| `docs/UI基准.md` | 面板外观标准（玻璃、页签栏、卡片），**改界面前必读** |
| `docs/菜单栏图标隐藏.md` | 菜单栏图标隐藏的排查与修复记录 |

## 工作方式

**历史轮次已结束，后续按需求方当前任务开展维护。**

1. 只做需求方当前分配的任务，产品行为以当前方案为准，实现以代码和当前任务要求为准。
2. **【2026-11-12 需求方决定】Codex 直接在 `~/Desktop/DevBar` 的 `main` 上工作并提交**，不再走分支和合并；每个提交只做一件事，工作区不要长时间留着未提交的改动。提交时只提交自己改的文件，不碰别人未提交的改动。
3. 只改当前任务涉及的目录；需要改公共文件时在回报里单独列出。
4. 做完运行 `Scripts/check.sh`，提交时逐个列出文件（不用 `git add -A` / `git add .`），不修改 git 作者配置。回报写明改动、验证结果、遗留问题；已提交时附分支名和提交号。
5. 完成任务后报告改动与实际验证结果；仅在需求方要求或需要保留排查方法时新增验证文档，避免堆积阶段回报。审核提出的 P1 优先修复。
6. 审核提出的问题按当前任务范围处理。
7. 需求有歧义或做不到：在回报里写清楚，不要自行扩展或删减功能。

## 红线（违反任何一条，审核直接不通过）

1. **不擅自加功能。** 仅按需求方授权范围维护。已确认支持截图标注、Markdown / Mermaid 文件打开与保存、Markdown 分栏编辑预览和预览图片导出，不因历史禁令移除。保持取消的功能：录屏、录音、GIF、钉图、自动滚动长图、窗口截图、全屏截图、OCR、分享，以及 JSON 树编辑、查询、排序和表格视图。模拟粘贴仅允许红线 7 中的路径。
2. **不联网。** Swift 不发外部请求；Web 不用 `fetch` / `XMLHttpRequest` / `WebSocket` / `EventSource`。
3. **只有黑白。** 业务代码不写字面颜色值，只用 `design/tokens.json` 生成的变量。彩色例外：剪贴板里颜色值的色块；**代码高亮、JSON 树、Mermaid 图用库自带的彩色主题**（R8 需求方决定：CodeMirror defaultHighlightStyle / One Dark，Shiki github-light / github-dark，Mermaid default / dark；颜色来自库主题，业务代码仍不得写字面颜色）。**剪贴板序号的蓝灰色**（设计变量 `clipboard.index`）和**拖到菜单栏顶部删除时的系统红色提示**（需求方 2026-11-12 确认，红色所在行加 `// devbar:allow-color`）。**设置页原生 Switch 的系统强调色**（由系统和当前外观决定，不强制绿色）。**截图选区和调整点蓝色、标注工具颜色及已确认的选择/悬浮强调色**也属于现有授权范围，优先复用现有变量。除这些以外，面板本身、按钮、排版仍只有黑白，不得新增其他颜色。识别颜色文本、必须写颜色字面量或颜色正则时，同一行加上 `// devbar:allow-color`，字面颜色检查会跳过该行。
4. **不猜改内容。** 自动行为不覆盖、不改写用户内容：不合法的 JSON 不自动修复；编辑区有内容时不自动导入；数字识别只用于排版。
5. **JSON 数字无损。** `Web/src/tools/`、`Web/src/tree/` 禁止原生 `JSON.parse` / `JSON.stringify`，只用 lossless-json。JSON 正文跨桥只作为字符串，Swift 不解析。
6. **安全设置不放宽。** CSP 不加 `unsafe-eval` / `wasm-unsafe-eval`；不用 `eval` / `new Function`；Mermaid 保持 `securityLevel: "strict"`。
7. **不需要辅助功能权限。** 不调用 `AXIsProcessTrusted`、不模拟按键（`CGEvent` post）。**唯一例外**（需求方 R9 确认）：剪贴板悬浮卡片按 Enter 确认时，可检查辅助功能授权并向**卡片出现时的前台应用**发送一次 ⌘V（`ClipboardController.pasteSelection`）；前台应用已改变、目标是 DevBar 自身或未授权时不发送。同一路径上还允许**读取该应用焦点控件的类型**（`focusedRole`，只读 `AXRole`，不读内容），仅用于选中条目是文件时决定「转成路径文本粘贴」还是原样粘贴（需求方 2026-11-12 确认）。**新增例外（需求方 2026-11-13 确认）**：剪贴板预选卡片首次出现时，可在已授权的前提下异步读取前台焦点的选区范围及其屏幕坐标，只用于定位卡片，不读取文本、不触发授权弹窗；查询失败回退鼠标位置，鼠标位置无效再回退屏幕居中。其他功能不得新增辅助功能调用或模拟按键。
8. **不用 Vorssaint 的品牌。** 产品名字、图标、bundle id 和界面文案不使用参考项目品牌。参考目录已移除，不参与构建。现有来源代码的版权头与许可声明保留，不因改名、文档清理或大量重写自行删除。
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

签名：`DEVBAR_SIGN_IDENTITY` 显式指定优先；未指定且本机只有一张有效 Apple Development 证书时，构建脚本自动复用它。无证书或多张时退回 ad-hoc并警告。固定签名用于保持应用身份，不能覆盖系统菜单栏可见性开关。

## 代码约定

- Swift 6 严格并发；UI 类型 `@MainActor`；存储用 `actor`；状态用 `@Observable`。
- `DevBarCore` 不 import AppKit / SwiftUI / WebKit / ScreenCaptureKit。
- 界面文字中文，集中在 `Sources/DevBar/Strings.swift` 和 `Web/src/strings.ts`。
- Web 不用 UI 框架；TypeScript `strict`；编辑器内容的修改都走 CodeMirror 事务（带 `userEvent`），保证可撤销。
- 新任务无需沿用历史轮次编号；提交信息准确描述本次改动，每个提交只做一件事。

## 回报格式

回报包含：做了什么、与需求的差异、实际验证结果、遗留问题。未执行的验证不得写成已通过。
