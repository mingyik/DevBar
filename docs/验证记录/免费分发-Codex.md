# T7.3 免费分发包

main。用户选择免费分发方式。

新增Scripts/package-free.sh与docs/免费分发说明.md，同步方案与规格。强制DEVBAR_SIGN_IDENTITY=-构建Release，签名结果必须包含Signature=adhoc才能继续；ZIP含DevBar.app与安装说明。未使用Developer ID、未上传公证、未安装或启动此包；本机已安装的版本保持原状。

产物build/DevBar-free-macOS-arm64.zip，约2.8MiB，Apple芯片、macOS26+。已执行bash -n、实际Release构建、codesign严格验证、Signature=adhoc/TeamIdentifier=not set检查及unzip -tq，均通过。Scripts/check.sh退出0（114 Swift、350 Web）。没有新依赖。

待接收者在另一台Mac确认首次Gatekeeper手动放行与升级权限行为；未声称免费包可免弹窗，也不声称解决macOS菜单栏错误归属。说明包含系统要求、安装/更新、保留系统安全设置和可能重授权限的限制。

```text
✔ 拦截颜色写法 6 (0.035208ms)
✔ 拦截颜色写法 7 (0.041458ms)
✔ 拦截颜色写法 8 (0.033208ms)
✔ 拦截颜色写法 9 (0.087625ms)
✔ 拦截颜色写法 10 (0.06875ms)
✔ 拦截颜色写法 11 (0.04125ms)
✔ 拦截颜色写法 12 (0.0325ms)
✔ 拦截颜色写法 13 (0.024541ms)
✔ 拦截颜色写法 14 (0.02125ms)
✔ 带允许标记的行不报 (0.045083ms)
✔ 语义色和普通宏不误报 (0.03275ms)
✔ 宏和颜色在同一行仍拦截颜色 (0.050792ms)
ℹ tests 17
ℹ suites 0
ℹ pass 17
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 69.317333
```
