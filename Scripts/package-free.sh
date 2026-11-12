#!/bin/bash
# 免费分发：强制 ad-hoc 签名，不使用开发证书、不上传公证、不安装或启动。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
DEVBAR_SIGN_IDENTITY=- Scripts/build-app.sh release
app="$root/build/DevBar.app"
signature="$(codesign --display --verbose=2 "$app" 2>&1)"
case "$signature" in
  *Signature=adhoc*) ;;
  *) echo "签名不是 ad-hoc，停止打包" >&2; exit 1 ;;
esac
codesign --verify --deep --strict "$app"
architecture="$(lipo -archs "$app/Contents/MacOS/DevBar")"
staging="$root/build/DevBar-Free"
archive="$root/build/DevBar-free-macOS-${architecture// /-}.zip"
rm -rf "$staging"
mkdir -p "$staging"
ditto "$app" "$staging/DevBar.app"
cp "$root/docs/免费分发说明.md" "$staging/安装说明.md"
rm -f "$archive"
ditto -c -k --sequesterRsrc --keepParent "$staging" "$archive"
echo "免费分发包：$archive"
