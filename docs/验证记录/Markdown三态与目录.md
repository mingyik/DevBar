# Markdown 三态、原文保存与目录窗口

起止提交：`3aac840`（起点）→ `633ff80`（终点）。实现者：Codex。

## 做了什么

- 三态显示：仅编辑 → 仅预览 → 编辑并预览；⌘E 与 ⌘⇧P 走同一循环。模式切换只改显示，不改原文。
- 编辑并预览：主面板保持在原位并切换为预览；左侧新增等宽、无标题栏的纯 Markdown 输入窗口；输入窗口右下角只悬浮清除按钮，输入经桥接同步到主面板预览。顶边对齐、间隔 8pt，空间不足时收窄输入窗口，不移动主窗口。
- 主面板底部：新增「保存原文」按钮；右侧固定按钮随模式切换（编辑/并排=橡皮擦，预览=截全预览图），并排模式的截全按钮只出现在预览窗口。
- 原文保存：Web 用原文与最近一次打开/保存的基准比较脏状态；⌘Z 回到基准即恢复禁用。保存请求只携带文本和不透明 `documentId`，路径和写入权限全在原生。
- 文件关联：选择文件、目录列表、最近打开、拖入统一走原生 `DocumentSession`；保存写回原文件，另存为默认落数据目录 `Markdown/`。保留 BOM 与 CRLF；外部修改、移动、删除或写失败时返回明确状态，不静默覆盖。
- 目录窗口：标题栏左侧按钮开关 260pt 宽玻璃窗口；高度与主面板一致（最小 460）。列表只展示数据存储位置 `Markdown/` 下的非临时 `.md/.markdown/.mmd/.mermaid/.txt` 文件，扁平、无文件夹、无图标；每行两行文字：文件名 13pt、创建时间 11pt。最近打开最多三条，固定三行高度，选中态与主窗口一致。底部居中「选择文件…」。
- 未保存保护：目录、最近、选择文件、拖入替换前询问保存／不保存／取消；保存取消或失败不替换；文件先读取成功再替换编辑器内容，异步读取只让最后一次选择生效。
- 窗口生命周期：主面板隐藏或切页时目录与预览窗口一起隐藏；进入并排模式自动关闭目录窗口；并排退出后目录保持关闭。
- 移除了隐藏面板时因 `memory.flush` 回复失败而弹出的「保存失败」误报，改为只记日志。

## 文件

原生：
- `Sources/DevBarCore/Document/DocumentFile.swift`（BOM/换行/签名/最近列表）
- `Sources/DevBar/Document/DocumentSession.swift`
- `Sources/DevBar/Document/DocumentBrowser.swift`
- `Sources/DevBar/Document/DocumentSidebarView.swift`
- `Sources/DevBar/Document/DocumentWindows.swift`
- `Sources/DevBar/App/PanelController.swift`、`PanelModel.swift`、`PanelView.swift`、`DevBarPanel.swift`、`FileDrop.swift`、`Strings.swift`
- `Sources/DevBar/Web/WebHost.swift`

Web：
- `Web/src/doc/page.ts`、`mode.ts`、`state.ts`、`preview-window.ts`
- `Web/src/editor/page-shell.ts`、`Web/src/main.ts`、`Web/src/preview/export.ts`、`Web/src/strings.ts`、`Web/src/styles/pages.css`

测试与文档：
- `Tests/DevBarCoreTests/DocumentFileTests.swift`
- `Tests/DevBarTests/DocumentSessionTests.swift`
- `Tests/DevBarTests/PanelNavigationTests.swift`
- `Web/tests/doc-save-state.test.ts`、`Web/tests/doc-state.test.ts`
- `菜单栏工具方案.md`、`docs/实现规格.md`、`docs/UI基准.md`

## 与旧规格的差异

- 方案 §6 原写「当前是两态，第三种模式尚未实现」；按需求改为三态并补扩展预览窗口。
- 方案 §6.1 原写「只读内容，不保存回源文件」；改为保留关联并支持写回，外部修改时拒绝覆盖。
- 目录窗口原需求为「当前文件所在目录的目录树」；需求方 2026-11-14 修正为「数据存储位置下 Markdown 文件夹的扁平文件列表」，且不显示文件夹、不显示图标、每行文件名 + 创建时间。旧目录树实现已删除。
- 目录窗口高度原定固定 460；需求方 2026-11-14 追加「最小高度与右侧面板一致」。
- ⌘⇧P 原为保留未用；现在与 ⌘E 一样触发三态循环。

## 检查

`Scripts/check.sh` 通过：Swift 150 项、Web 354 项，格式、tokens、颜色检查均通过。

## 实际验证

- 三态：源 → 预览 → 并排循环正常；并排时主面板原位切换为预览，左侧出现无标题栏输入窗口，两窗等宽（各 480）且顶边对齐；在左侧输入会实时更新右侧预览，清除按钮清空两侧内容；主面板模式按钮显示下一步动作（编辑→眼睛、预览→分栏、分栏→铅笔）。
- 目录窗口：开关正常；高度与主面板同为 600；只列 `~/Library/Application Support/DevBar/Markdown` 下的文件；保存新文稿后行内显示文件名和创建时间，无图标、无文件夹。
- 保存：打开 `/tmp/devbar-test.md` 后修改，文件名旁出现「有未保存修改」，保存后文件内容更新、标记消失；另存为默认目录为 `DevBar/Markdown`，保存后目录列表刷新并选中。
- 最近打开：显示已打开文件，当前文稿高亮；超过三条的裁剪与去重由单元测试覆盖。
- 单位测试：BOM/CRLF 保存、外部修改拒写、最近去重上限、脏状态与撤销回基准、模式循环、⌘E/⌘⇧P 路由。

## 待需求方验证

- 真实外部修改/删除/失权下的提示弹窗与拒绝覆盖（本次只有单元测试）。
- 保存／不保存／取消三选弹窗在真实切换文件时的交互。
- 浅色、深色主题下的预览窗口与目录窗口外观；彩色壁纸透出。
- 多屏、屏幕边缘与超大文本下的窗口收窄/移位。
- 大目录列表（Markdown 文件夹内大量文件）滚动与异步加载手感。
- 长文并排输入时预览合并渲染的流畅度。

## 未解决

- 并排输入窗口依赖第二个 WebView；大量输入时通过 120ms 合并同步。
- 保存期间连续编辑时按钮会暂时禁用，保存完成后仍能正确保持新的未保存状态；未做并发多窗口保存。


## 2026-11-14 审核修复

- P1 并排输入漏同步：编辑器增加 `devbarEditorText`/`devbarEditorFlush`；保存、切换文件、隐藏或退出分栏前直接读取左侧编辑器当前文本并推给主面板。`doc.editorText` 携带 `documentId`，原生与主面板都丢弃身份不匹配的旧消息。
- P2 并排导出退出预览：`export()` 不再调用模式循环；split/preview 直接渲染当前预览并导出，只有 source（正常不可达）临时显示预览后恢复。
- P2 大文件保存卡界面：BOM/换行编码、签名校验和原子写入移到后台 `Task.detached`，主线程只处理保存面板与最终状态。


## 2026-11-14 复核打回修复

- P1 退出分栏同步被跳过：模式切换改为异步处理。Web 退出分栏前先发 `doc.flushEditor` 并等待编辑器快照；原生在收到 `doc.mode` 后再次读取快照校验文本一致才切模式，否则恢复 `split`。分页、隐藏面板、打开目录都会 await 快照同步；失败时保留分栏或回退页面。
- P1 首次保存后左侧身份失效：`DocumentSession` 保存后返回实际 documentId；原生立即调用 `setEditorIdentity` 更新输入窗身份，并回读保存期间的新文本推给主面板；保存回复携带 `currentText` 供 Web 校正基准。验证：首次另存为后继续在左侧输入，右侧预览与“未保存”状态均正常更新。
- 保留并复核：并排导出不退出模式；编码/签名/原子写入仍在后台 `Task.detached`。
