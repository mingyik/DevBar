# Markdown 同步失败与换行比较修复

任务 T4.1，分支 main，本次提交的父提交为 c0eb244；保留同期已提交的界面调整。

## 做了什么

- 切换文稿前区分无法确认、无修改、有修改三种状态。分栏编辑器快照读取失败或主面板修改状态读取失败时，阻止替换现有文稿。
- 保存确认读取分栏文本失败时，不再回退使用主面板旧文本。
- 异步确认后检查打开操作的 generation，丢弃已过时的打开请求。
- 退出分栏的快照比较只统一 CRLF/CR/LF，仍拒绝文字或末尾换行数量不同的内容；保存编码和源文本保持原逻辑。

## 与规格的差异

无。

## 检查与证据

- Scripts/check.sh 退出码 0：Swift 152 项、Web 355 项通过，格式、tokens 与颜色检查通过。
- 新增 documentReplacementFailsClosedWhenSnapshotOrStatusUnavailable：覆盖快照失败但旧状态为 clean、状态读取失败、正常 dirty/clean 以及非分栏场景。
- 新增 documentEditorComparisonAllowsOnlyNewlineDifferences：覆盖换行等价、文字不同、末尾换行不同、混合换行原文编码不变。
- git diff --check 通过。

## 待需求方验证

- 实际 CRLF 文件在未编辑的情况下进入和退出分栏。
- 编辑器 WebContent 异常时切换文件，现有文稿不被替换。
- 本轮未重新安装应用，已安装版本不包含本次修复。

## 遗留问题

未发现本次范围内的其他阻塞项；真实窗口与异常进程操作尚未人工验收。
