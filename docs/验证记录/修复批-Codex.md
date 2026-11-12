# 修复批回报（Codex）

分支：main。代码提交范围：c2e8490–6aef376（基于 f62b101）。JSON 折叠已提前独立提交为25c527b，不混入本批。

## 做了什么

- T2.4：抽出直接粘贴纯逻辑；未授权时原位提示“已复制”；系统请求只触发一次；设置页显示授权状态并在重新激活时无提示刷新。卡片关闭清空目标进程。
- T4.4：仅修正 mindmap 连线、深色根文字与 timeline 块的可读性；保留作者指定颜色，更新四组 23 图样张。
- T1.4 / T4.6：隐藏 60 秒或收到 warning/critical 时保存并清理缓存，最多等待一秒，释放旧 WKWebView；打开时恢复。离屏导出忙碌时延后释放。不改变持久化用户内容。
- 新增 Mermaid FIFO 缓存上限：64 项且估算 UTF-16 文本 8 MiB；清理 Shiki 高亮器与 Markdown、JSON、QR 预览缓存；释放悬停预览和缩略图。
- 公共改动：WebHost、PanelController、main.ts、实现规格 §5.4；新增 Debug 隔离测量场景 mem-idle / mem-daily，以及 memory 的隐藏恢复验证参数。

## 内存实测与限制

2026-11-12，Mac16,1，16 GiB，macOS 26.7.2（25G332），Debug；非 M1 / 8 GB，不能作目标机器验收通过。

每个场景独立启动测试进程，使用临时状态目录及合成剪贴板记录；主进程 PID 由运行器报告，WebKit PID 用启动前后进程集合差识别（不是按 RSS 猜 footprint）。有两个 WebContent，表中相加；另计 Networking。单位 MiB，取 footprint 的 phys_footprint；进程共享内存可能重复计费，不能把列简单相加当唯一物理占用。

| 场景 | 主进程 | WebContent 合计 | GPU | Networking |
|---|---:|---:|---:|---:|
| mem-idle | 34.56 | 59.86 | 6.70 | 7.25 |
| mem-daily | 38.47 | 79.99 | 70.50 | 7.28 |
| memory | 58.05 | 383.91 | 79.06 | 5.64 |

- idle：启动后无内容；daily：三条合成历史与短 JSON 树（初次采样尚未加入短文稿，后补测见后续说明）；memory：23 图样张、10 种代码与 2,097,169 字节 JSON、QR，包含缓存清理后恢复。
- 三次 `memory_pressure -S -l warn` 均退出 255：`kern.memorypressure_manual_trigger failed : Operation not permitted`。原始数据包含命令后采样，但它不代表压力后的回收结果，系统压力验收未完成。
- R9 原记录 304 MB 与本次压力场景不可直接作优化前后对照：Debug 状态、清理后再渲染次数及采样时点不同。本次没有达到 250 MB，不能宣称内存优化达标。
- 隐藏释放与重开验证结果另附。不得以 unit test 替代系统压力实测。

## 缓存上限与释放时机

| 对象 | 上限 / 保留范围 | 释放 |
|---|---|---|
| Mermaid SVG | 64 项、估算字符串 8 MiB | memory.flush；模块代码留在 JS 模块缓存，销毁 WebView 后释放 |
| Shiki | 一个高亮器、15 语言、2 主题 | flush dispose；动态模块不能单独卸载 |
| Markdown | 当前文稿一份源码/HTML 缓存 | flush 清缓存、DOM |
| JSON 树 | 当前 JSON 的树，未设额外 DOM 节点总上限；200 分批构建 | flush 清 DOM 与分析结果；Worker 每次完成/取消即终止 |
| QR | 当前一份 PNG 与 DOM | flush 清理，显示时恢复 |
| 离屏导出 | 一个 WKWebView；导出尺寸另有限制 | hidden flush；忙碌则结束后释放 |
| 剪贴板缩略图 | 最多 10 条，最长边 320px | hidden flush 后清理，打开重新读取 |
| 悬停预览 | 一个视图、图像最长边 1200px；文本内容缓存最多20项且每项≤128000 UTF-8字节，尺寸缓存20项 | hidden flush 清视图/内容/尺寸缓存 |
| 历史原始 payload | 最多10条；图片每条≤20MiB，文本无额外字节上限 | 保留以保证快捷切换；这是仍可能占大量内存的来源，未改为按需磁盘读取 |

## 辅助功能全部调用点

都在 ClipboardController.swift：

- pasteSelection：先验证前台 PID，AXIsProcessTrusted() 无提示检查；仅第一次未授权 Enter 调用 AXIsProcessTrustedWithOptions(prompt:true)。
- focusedRole：仅 Enter、已授权、文件条目、目标非 Finder 时调用。AXUIElementCreateApplication、SetMessagingTimeout(0.3)、CopyAttributeValue 读取 focused element / AXRole；不读内容。
- 同一路径仅允许决策通过时构造两次 CGEvent（⌘V down/up）并 postToPid；发送前复查前台 PID。
- refreshDirectPasteAuthorization：设置页显示及应用重新激活时调用无提示 AXIsProcessTrusted()。需求方已明确允许此例外，但 AGENTS 红线7文字尚未同步，须审核方合并文档。

## 非黑白颜色全部类别

- 色块：ClipboardListView、ClipboardController，解析用户颜色值。
- 库主题：CodeMirror、JSON 树、Shiki、Mermaid；局部修复取库主题变量，不加业务字面颜色。
- clipboard.index：DesignTokens，悬浮卡片序号蓝灰。
- 系统红：ClipboardDragView 的菜单栏删除阴影、侧线、删除图标。
- **另有已有蓝色例外未写入当前红线3**：ClipboardListView 的悬浮光晕、选中左线，ClipboardDragView 拖拽左线。需求方此前明确要求保留蓝色；本批未删视觉效果，也不能声称“只有当前红线列出的例外”。请审核方把已确认的蓝色用途同步到红线。

## 测试与检查

- Scripts/check.sh：通过；Swift 103、Web 350 项，含新增缓存预算与高亮器 dispose/recreate 测试。
- 真实 WKWebView memory 场景：JSON、文稿、QR 预览清理后重新生成成功，22 张合法 Mermaid 恢复，错误图仍独立报错。
- Web 构建仍有已有大块体积与 CodeMirror 无效动态 import 警告；未新增依赖。

## 待需求方验证与遗留

- 辅助功能未授权/拒绝/授权后的真实目标应用 Enter 粘贴及设置状态刷新。
- Mermaid 四组样张最终视觉确认。
- M1 / 8 GB 内存验收、系统 warn/critical 事件实测与严格同口径优化前后数据：尚未完成，不能写通过。

## 最后复核

- 真实隐藏65秒后：hiddenReleaseOccurred=true；重开 readyAfterReopen=true、restoredDiagramCount=22。证据：修复批-隐藏恢复.json。
- 日常场景已补入短文稿并重新构建补测，数据见修复批-日常补测.json。上表保留初次采样，补测未再次运行无权限的系统压力命令。
- 最后一次完整 check.sh 退出0，输出末尾如下。

```text
✔ 拦截颜色写法 6 (0.0345ms)
✔ 拦截颜色写法 7 (0.037167ms)
✔ 拦截颜色写法 8 (0.039ms)
✔ 拦截颜色写法 9 (0.078792ms)
✔ 拦截颜色写法 10 (0.060042ms)
✔ 拦截颜色写法 11 (0.035083ms)
✔ 拦截颜色写法 12 (0.034083ms)
✔ 拦截颜色写法 13 (0.025917ms)
✔ 拦截颜色写法 14 (0.023167ms)
✔ 带允许标记的行不报 (0.044917ms)
✔ 语义色和普通宏不误报 (0.034ms)
✔ 宏和颜色在同一行仍拦截颜色 (0.062292ms)
ℹ tests 17
ℹ suites 0
ℹ pass 17
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 66.142583
```

## 内存提交文件清单（6aef376）

- Sources/DevBar/App/PanelController.swift
- Sources/DevBar/Clipboard/ClipboardController.swift
- Sources/DevBar/Clipboard/ClipboardHoverPreview.swift
- Sources/DevBar/Debug/R9UICheck.swift
- Sources/DevBar/Web/PreviewImage.swift
- Sources/DevBar/Web/WebHost.swift
- Web/src/bounded-text-cache.ts
- Web/src/doc/document.ts
- Web/src/doc/highlight.ts
- Web/src/doc/mermaid.ts
- Web/src/doc/page.ts
- Web/src/doc/preview.ts
- Web/src/main.ts
- Web/src/qr/page.ts
- Web/src/tools/json/page.ts
- Web/tests/memory.test.ts
- Web/tests/r9-runtime.mjs
- "docs/\345\256\236\347\216\260\350\247\204\346\240\274.md"
