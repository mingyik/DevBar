# 面板存储与内存回报

分支 main，代码提交范围 b7cde6b–9546dae。

## 做了什么

- b7cde6b：统一数据目录、兼容旧数据与按文件原样迁移；方案初稿。
- 4f4d88a：Paste 上限5–30条，默认10条；新增淘汰和删除原件/缩略图测试；原件尽可能映射读取。
- 9546dae：数据与截图位置选择、迁移协调、面板改名；切页保存后释放大预览和Paste原件缓存，后台采集只落盘更新索引，不重建已释放缓存；低内存导入准入。

详细规则见 docs/面板数据与内存方案.md。新Paste记录在独立存储actor内异步写原件，再原子提交索引，再更新UI。拖动删除走同一store.remove，删除原件与缩略图；下调上限及新增超限同样清理淘汰数据。

## 与此前讨论的差异

Json/Markdown/QrCode 使用单一 state.json 同时保存原文字符串及状态，不分content.txt与state.json，防止两次写入只成功一次。Paste复用成熟索引+独立原件布局，时间戳用于新原件文件名，不额外创建每条记录的子目录；旧原件名仍兼容。没有新增依赖。

切换释放的是预览与大对象，编辑器原文和撤销状态仍保留；不宣称切页后进程立刻缩到固定数值。数据路径是用户数据，不能当缓存删除。

## 测试与检查

- Scripts/check.sh退出0：Swift109项、Web350项；tokens一致，颜色检查通过。
- 新增临时目录测试：旧布局迁移原样、嵌套/已存在目标拒绝；状态写入失败返回false、保留原文件；当前内存余量准入预算；30条保留/5条淘汰及重开；多表示原件与缩略图删除；原件缓存释放后从磁盘选择恢复及后台采集不重新加载原件。
- 真实WKWebView（Debug，临时隔离状态）：切出Json后树DOM清空；返回重建；19/20位整数及0.1000原文保持；切到原生面板清空，再回来恢复。四项均true，见面板存储-运行时.json。
- Scripts/build-app.sh debug成功，codesign脚本校验通过，产物build/DevBar.app。本机未配置固定签名，脚本提示ad-hoc签名可能影响已有系统授权。
- 本次未安装到/Applications；未对用户真实数据目录做迁移演练。

## 待需求方验证与限制

- 设置页外观、目录选择对话框及真实目录迁移；调小Paste上限实际会删除最旧记录，界面已说明。
- 外置盘/跨卷迁移、磁盘权限拒绝及磁盘写满尚未真机演练；失败反馈及不覆盖已有目标由代码和临时目录测试验证，不写成这些场景实测通过。
- 严重系统内存压力事件仍未真机触发，准入函数使用当前VM页估算，不保证未来分配成功；不宣称达到M1/8GB内存目标。
- 截图位置已用于Json/Markdown截全图；区域/滚动截图正式落盘仍是后续任务。

## check.sh末尾

```text
✔ 拦截颜色写法 6 (0.030042ms)
✔ 拦截颜色写法 7 (0.035583ms)
✔ 拦截颜色写法 8 (0.042125ms)
✔ 拦截颜色写法 9 (0.077666ms)
✔ 拦截颜色写法 10 (0.058584ms)
✔ 拦截颜色写法 11 (0.036458ms)
✔ 拦截颜色写法 12 (0.033917ms)
✔ 拦截颜色写法 13 (0.026125ms)
✔ 拦截颜色写法 14 (0.021958ms)
✔ 带允许标记的行不报 (0.045ms)
✔ 语义色和普通宏不误报 (0.036209ms)
✔ 宏和颜色在同一行仍拦截颜色 (0.057583ms)
ℹ tests 17
ℹ suites 0
ℹ pass 17
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 69.031458
```

## 文件清单

### b7cde6b

- Sources/DevBar/Clipboard/ClipboardController.swift
- Sources/DevBar/Storage/DataLocations.swift
- Sources/DevBar/Web/ScreenStateStore.swift
- Sources/DevBarCore/Clipboard/ClipboardStore.swift
- Tests/DevBarTests/DataLocationsTests.swift
- docs/superpowers/plans/2026-11-12-panel-storage.md

### 4f4d88a

- Sources/DevBarCore/Clipboard/ClipboardStore.swift
- Tests/DevBarCoreTests/ClipboardStoreTests.swift

### 9546dae

- Sources/DevBar/App/FileDrop.swift
- Sources/DevBar/App/PanelController.swift
- Sources/DevBar/App/PanelView.swift
- Sources/DevBar/Clipboard/ClipboardController.swift
- Sources/DevBar/Clipboard/ClipboardMonitor.swift
- Sources/DevBar/Storage/MemoryBudget.swift
- Sources/DevBar/Storage/StorageSettings.swift
- Sources/DevBar/Strings.swift
- Sources/DevBar/Web/ScreenStateStore.swift
- Sources/DevBar/Web/WebHost.swift
- Tests/DevBarTests/ClipboardInteractionTests.swift
- Tests/DevBarTests/DataLocationsTests.swift
- Web/src/editor/editor.ts
- Web/src/main.ts
- Web/src/strings.ts
- Web/tests/r9-runtime.mjs

