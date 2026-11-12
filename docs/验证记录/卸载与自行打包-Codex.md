# T7.3 卸载与自行打包

2026-11-12，main。需求方要求卸载本机DevBar、删除此前打包结果，改为自己执行免费打包脚本。

已退出/Applications/DevBar.app对应进程，注销已安装及项目build副本的LaunchServices记录，删除/Applications/DevBar.app、项目build/（含旧ZIP和暂存应用）、.build/及Web/dist/。源码、node_modules、用户保存的数据与系统授权配置保留。

新增根目录打包.command，双击转调已有Scripts/package-free.sh；免费分发说明同步。脚本强制ad-hoc Release打包，不安装、不启动、不公证。产物会在下一次用户执行脚本时生成到build/。

验证：三个脚本bash -n通过；卸载路径和旧build不存在。打包脚本上一轮已实际构建及验签通过，本轮没有再次运行构建/check.sh，以免重新生成用户明确要求删除的产物。无新依赖。
