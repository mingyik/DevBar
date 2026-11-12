# T4.1 Markdown模式快捷键

main。修改DevBarPanel、PanelController、WebHost与Web/main.ts，测试PanelNavigationTests及r9-runtime运行器，方案/UI基准同步。

⌘⇧P原生窗口事件路由仅在Markdown页发送doc.toggleMode；Web等待页面切换完成后调用既有DocPage.togglePreview，与预览/编辑按钮共用模式、持久化和文案。不改变⌘P切页，不创建第三模式或扩展预览窗口。后续三模式仍列为规划。

验证：真实NSEvent断言模式回调调用一次且页面切换零次；完整check.sh通过（114 Swift、350 Web）；真实WKWebView五项断言通过（初始编辑、切预览生成正文、按钮变编辑、再次切回编辑、按钮变预览），见Markdown模式快捷键-运行时.json。debug构建及固定签名验证通过，已安装重启。需求方手动按键和外观待确认。无新增依赖。

```text
✔ 拦截颜色写法 6 (0.030958ms)
✔ 拦截颜色写法 7 (0.034833ms)
✔ 拦截颜色写法 8 (0.042666ms)
✔ 拦截颜色写法 9 (0.089083ms)
✔ 拦截颜色写法 10 (0.066625ms)
✔ 拦截颜色写法 11 (0.040875ms)
✔ 拦截颜色写法 12 (0.037167ms)
✔ 拦截颜色写法 13 (0.0255ms)
✔ 拦截颜色写法 14 (0.023375ms)
✔ 带允许标记的行不报 (0.045792ms)
✔ 语义色和普通宏不误报 (0.034666ms)
✔ 宏和颜色在同一行仍拦截颜色 (0.032667ms)
ℹ tests 17
ℹ suites 0
ℹ pass 17
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 67.648625
```
