## 审核：R3 Codex——T2.1 剪贴板模型与存储、R2 四条补充修复

结论：**通过**，已合并进 `main`。

分支 `codex/r3`：T2.1 `3cb3701`、R2 补充 `11b6a51`。审核方：Claude。

### 已核实

- 改动只在 `Sources/DevBarCore/Clipboard/`、`Tests/DevBarCoreTests/`、`Web/src/tools/`、`Web/tests/`，没有改公共文件和依赖。
- `DevBarCore` 只 import `Foundation`、`CryptoKit`，没有 AppKit。
- 存储实现对照规格 §7.1、§7.2：原始表示全部保存、按原类型写回；SHA-256 判重时长度前缀防拼接碰撞；10 条上限与文件删除；图片合计超过 20MB 拒收并回调一次；索引先写 `.tmp` 再 `replaceItemAt`；启动时丢弃缺文件条目、清理孤立文件；blob 文件名做了路径越界检查；写入失败时删掉已写的文件。
- 在临时副本里合并到最新 `main` 后运行 `Scripts/check.sh`：退出码 0，Swift 43 项、Web 164 项通过。
- R2 四条补充逐条复测：`[TODO] fix` → `text`；词典误判 0；`AAECAwQFBgc=` → 二进制 8 字节；`%FF%41` → `%FFA`、错误 `[0,3)`。
- **没有矫枉过正**：正常的 Base64（`SGVsbG8gV29ybGQ=`、`dGVzdA==`、中文内容 `5L2g5aW95LiW55WM`、`eyJhIjoxfQ==`）仍识别为 Base64；`{"a":`、`[1, 2`、`{ name: 1` 仍是「可修复的 JSON」；`Username`、`Password` 是普通文本。

### 并入下一轮（Codex，R4，先做这一条）

**索引损坏时存储初始化直接抛错**（规格没写这种情况，属于规格漏洞）：

- 复现：在存储目录里放一个内容为 `not json` 的 `index.json`、没有 `.tmp`，`ClipboardStore(directory:)` 抛出 `invalidIndex`。
- 后果：Grok 在 R4 接上剪贴板监听后，只要索引损坏一次，剪贴板历史就再也用不了，直到用户手动删文件。
- 要求：索引损坏且没有可用的 `.tmp` 时，把坏文件改名为 `index.json.corrupt-<时间>` 保留现场，从空历史开始，并通过回调通知界面轻提示一次「剪贴板历史已损坏，已重新开始」；补测试。规格 §7.2 已同步。

### 其他

- 「缩略图由调用方生成后传入」：同意，`DevBarCore` 不依赖图像库，符合分层。
- `npm ci` 报告开发依赖中有 10 个中等级别的安全提示，均来自构建 / 测试工具链，不进应用包；第 7 期分发前统一看一次。
