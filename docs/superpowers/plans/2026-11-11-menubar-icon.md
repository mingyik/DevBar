# 菜单栏图标

需求方已确认：采用提供的「测试工具.svg」显示器与代码符号造型，菜单栏使用单色透明背景，适配浅色与深色。应用程序图标不变。

采用现有 PDF 资源加载方式，而非增加 SVG 运行时解析或栅格资源；保留原路径，紧凑排布到 18pt。本轮只换菜单栏图片。

- [x] 将原 SVG 路径生成透明矢量 PDF，加入 MenuBar.imageset。
- [x] 通过 AppIcons 加载模板图片，替换 square.stack。
- [x] 运行项目检查、构建 Release，沿用 local.devbar.app.repaired 安装，验证重启后菜单栏外观。
