# JSON 与保存按钮整体禁用态

T3.4 / T4.1，main。

- JSON 转换按钮、Markdown 原文保存按钮在 disabled 状态下整体 opacity 0.45，包括文字/图标、边框和背景，保持禁止点击。
- 这两个按钮使用各自正常前景色参与整体透明度合成，不再叠加单独的禁用前景色；其他按钮不变。
- 浏览器 computed style 已验证浅色和深色，两按钮 disabled 为 true、opacity 为 0.45。
- Scripts/check.sh 退出码 0，Swift 153 项、Web 355 项通过。
- Release 构建及签名校验通过，替换安装 /Applications/DevBar.app 并启动；视觉由需求方确认。
