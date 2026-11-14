# 系统操作图标

copy.png：macOS SF Symbol `doc.on.doc`。clear.png：macOS SF Symbol `eraser`。

由 AppKit 的 NSImage(systemSymbolName:accessibilityDescription:)、18pt regular 配置渲染，24pt 画布、2× PNG。Web 只使用 alpha 蒙版，以 currentColor 跟随主题；图标不含业务颜色。复制成功仍暂时显示对勾。仅作为 macOS 应用内操作图标使用。

capture.png：macOS SF Symbol `viewfinder.rectangular`，仅用于文稿截全图，不作为复制操作。

save.png：按原内联软盘路径绘制的 alpha 蒙版（24pt 画布 2× PNG），只用于文稿保存按钮，颜色与 clear/capture 一样跟随 currentColor。

toggle.png：macOS SF Symbol `repeat`（15pt regular，24pt 画布 2× PNG），用于二维码与文稿页的编辑/预览切换图标按钮。
