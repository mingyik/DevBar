# 系统操作图标

copy.png：macOS SF Symbol `doc.on.doc`。clear.png：macOS SF Symbol `eraser`。

由 AppKit 的 NSImage(systemSymbolName:accessibilityDescription:)、18pt regular 配置渲染，24pt 画布、2× PNG。Web 只使用 alpha 蒙版，以 currentColor 跟随主题；图标不含业务颜色。复制成功仍暂时显示对勾。仅作为 macOS 应用内操作图标使用。

capture.png：macOS SF Symbol `viewfinder.rectangular`，仅用于文稿截全图，不作为复制操作。

save.svg：保留原软盘路径，描边由 1.5 调细为 1.1，24×24 viewBox。只用于文稿保存按钮，通过 alpha 蒙版跟随 currentColor；显示尺寸、正常色与禁用色不变。
