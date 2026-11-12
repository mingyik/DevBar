# T1.1 Json/Markdown 放大高度

main，需求方2026-11-12要求：放大高度使用屏幕的4/5。

修改：PanelController.reposition使用目标屏幕visibleFrame.height×4/5向下取整，宽度仍640pt；默认尺寸、顶部锚点、可见区域裁剪和文件拖入覆盖层保持原逻辑。UI基准已同步。

检查：Scripts/check.sh退出0，Swift109项、Web350项通过；debug构建、固定开发证书签名校验通过；已安装/Applications/DevBar.app并重启。UI由需求方检查，未声明视觉验收已通过。与规格差异：新要求覆盖旧固定720pt放大高度。

文件：Sources/DevBar/App/PanelController.swift、docs/UI基准.md。

check.sh末尾：

```text
✔ 拦截颜色写法 6 (0.036ms)
✔ 拦截颜色写法 7 (0.0385ms)
✔ 拦截颜色写法 8 (0.038792ms)
✔ 拦截颜色写法 9 (0.076917ms)
✔ 拦截颜色写法 10 (0.063459ms)
✔ 拦截颜色写法 11 (0.035292ms)
✔ 拦截颜色写法 12 (0.034625ms)
✔ 拦截颜色写法 13 (0.025958ms)
✔ 拦截颜色写法 14 (0.02225ms)
✔ 带允许标记的行不报 (0.044ms)
✔ 语义色和普通宏不误报 (0.03375ms)
✔ 宏和颜色在同一行仍拦截颜色 (0.050041ms)
ℹ tests 17
ℹ suites 0
ℹ pass 17
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 67.447375
```
