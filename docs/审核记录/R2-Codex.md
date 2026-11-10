## 审核：R2 Codex——T3.2 类型识别、T3.5 URL、T3.6 Base64 与时间戳

结论：**通过**，已合并进 `main`。

分支 `codex/r2`：T3.2 `ea6e344`、T3.5 `56e6cd1`、T3.6 `7f15a88`。审核方：Claude。

### 已核实

- 改动只在 `Web/src/tools/`、`Web/tests/` 和公共文件 `Web/package.json`、`package-lock.json`。
- 新依赖：`lossless-json 4.3.3`（MIT）、`jsonrepair 3.15.0`（ISC），版本锁死，许可证已在 npm 上核对。
- `src/tools/` 里没有 `JSON` 标识符；URL 编码手写，没有用 `encodeURIComponent` / `new URL()`；时间戳用 BigInt 拆整秒、小数部分按字符串拼接，不经过浮点。
- 在临时副本里把 `codex/r2` 合并到最新 `main` 后运行 `Scripts/check.sh`：退出码 0，Swift 21 项、Web 143 项通过。
- 方案 §9.5 的 6 条识别用例自己重跑，结果与回报一致。
- 自己补测的边界：`1700000000123456` 在 `Asia/Shanghai` 得到 `2023-11-15 06:13:20.123456`、ISO `…+08:00`；`encodeComponent("!'()*")` 得到 `%21%27%28%29%2A`；整段编码不会二次编码已有的 `%20`；URL 预览正确拆出 `userinfo`、IPv6 主机 `[::1]`、端口、重复参数和 `+` 转空格。

### 探针发现的问题（规格本身的漏洞，不算实现错误）

实现忠实于当时的规格，以下是规格写得不够严。规格已按下面补严（`docs/实现规格.md` 标「R2 审核补充」），**并入 Codex 下一轮（R3）**修改并补测试：

| # | 现象 | 规格补充 |
|---|---|---|
| 1 | `[TODO] fix bug`、`[ERROR] connection refused`、`{name}` 被判为「无效 JSON」，粘一行日志进来会满屏标错 | §8.3 第 2 条：修不好的内容要「看起来像 JSON 结构」才判为无效 JSON，否则当普通文本 |
| 2 | 系统词典 177,219 个 ≥ 8 字母的单词里，378 个被判成 Base64（其中 323 个是全小写单词，如 `acerbity`），解出来是拉丁、希伯来、阿拉伯字母混杂的乱码。常见开发词汇（username、password、database 等 20 个）都正确 | §8.3 第 6 条：排除全小写 / 首字母大写的纯字母串，排除 C1 控制字符；加词典回归测试，误判 ≤ 10 个 |
| 3 | Base64 解码 `AAECAwQFBgc=` 返回「文本」，内容是 `\u0000`–`\u0007` 控制字符 | §8.8：含控制字符时按二进制处理，不写进编辑区 |
| 4 | URL 解码 `%FF%41`：整串都标成错误，合法的 `%41`（A）也没解出来 | §8.7：错误精确到字节，`%FF%41` → `%FFA`，只标 `%FF` |

### 对「与规格的差异」的意见

- 「URL 错误区间用原输入的 UTF-16 下标、左闭右开」：同意，正好和 CodeMirror 的位置一致。

### 合并后发现：`check.sh` 不会更新过期的依赖

合并后在 `main` 目录第一次运行 `Scripts/check.sh` 失败（`Cannot find package 'lossless-json'`）：`check.sh` 只在 `Web/node_modules` **不存在**时才 `npm ci`，`package-lock.json` 变了也不会重装。补跑 `npm ci` 后退出码 0，Web 143 项通过——代码本身没问题。

**并入下一轮（谁先改 `Scripts/check.sh` 谁处理，R3 默认给 Grok）**：`Web/package-lock.json` 比 `Web/node_modules/.package-lock.json` 新（或后者不存在）时自动 `npm ci`；`Scripts/build-app.sh` 同理。
