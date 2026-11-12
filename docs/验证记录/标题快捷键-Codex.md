# T1.2 面板标题打开快捷键

main。本次修改PanelView与UI基准。

标题后读取KeyboardShortcuts.getShortcut(page.shortcutName)并显示description；未设置隐藏，不再固定显示Cmd+P。初次显示、切页、UserDefaults变化时刷新；设置页面没有专属shortcutName，因此先排除。显示的是面板打开快捷键，而不是Paste卡片的Cmd+Shift+V。标题点击及Cmd+P切页行为不变。

Scripts/check.sh退出0（Swift113、Web350），debug构建与固定签名校验通过；已安装到/Applications并重启。视觉及设置快捷键后的显示由需求方确认。没有新增依赖。

```text
✔ 拦截颜色写法 6 (0.033042ms)
✔ 拦截颜色写法 7 (0.041416ms)
✔ 拦截颜色写法 8 (0.03975ms)
✔ 拦截颜色写法 9 (0.082417ms)
✔ 拦截颜色写法 10 (0.063584ms)
✔ 拦截颜色写法 11 (0.0385ms)
✔ 拦截颜色写法 12 (0.034041ms)
✔ 拦截颜色写法 13 (0.026209ms)
✔ 拦截颜色写法 14 (0.02225ms)
✔ 带允许标记的行不报 (0.050708ms)
✔ 语义色和普通宏不误报 (0.044417ms)
✔ 宏和颜色在同一行仍拦截颜色 (0.04875ms)
ℹ tests 17
ℹ suites 0
ℹ pass 17
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 65.394667
```
