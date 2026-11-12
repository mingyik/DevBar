#!/bin/bash
# 双击运行：生成免费分发包，不安装、不启动应用。
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
exec "$root/Scripts/package-free.sh"
