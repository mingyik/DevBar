#!/bin/bash
# 组装 build/DevBar.app。不安装、不启动。
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "用法: Scripts/build-app.sh [debug|release]" >&2
  exit 1
fi

config="${1:-debug}"
case "$config" in
  debug|release) ;;
  *)
    echo "用法: Scripts/build-app.sh [debug|release]" >&2
    exit 1
    ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

web_needs_build() {
  if [[ ! -f Web/dist/index.html ]]; then
    return 0
  fi
  local newer
  newer="$(
    find Web \
      \( -path Web/node_modules -o -path Web/dist \) -prune \
      -o -type f -newer Web/dist -print -quit
  )"
  [[ -n "$newer" ]]
}

if web_needs_build || [[ ! -d Web/node_modules || ! -f Web/node_modules/.package-lock.json || Web/package-lock.json -nt Web/node_modules/.package-lock.json ]]; then
  echo "== web build =="
  (
    cd Web
    if [[ ! -d node_modules || ! -f node_modules/.package-lock.json || package-lock.json -nt node_modules/.package-lock.json ]]; then
      npm ci
    fi
    npm run build
  )
else
  echo "== web build =="
  echo "Web/dist 已存在且源码未变，跳过"
fi

echo "== swift build -c $config =="
swift build -c "$config"
bin_dir="$(swift build -c "$config" --show-bin-path)"
binary="$bin_dir/DevBar"
if [[ ! -x "$binary" ]]; then
  echo "找不到可执行文件: $binary" >&2
  exit 1
fi

app="$root/build/DevBar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Web" "$app/Contents/Resources/Licenses"
cp "$binary" "$app/Contents/MacOS/DevBar"
chmod +x "$app/Contents/MacOS/DevBar"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$root/Resources/AppIcon/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp -R "$root/Web/dist/." "$app/Contents/Resources/Web/"
cp -R "$root/Resources/Licenses/." "$app/Contents/Resources/Licenses/"
printf 'APPL????' > "$app/Contents/PkgInfo"

# Desktop 上的 com.apple.provenance 会使 codesign --strict 失败。
xattr -cr "$app"

identity="${DEVBAR_SIGN_IDENTITY:-}"
if [[ -n "$identity" ]]; then
  sign_args=(--force --sign "$identity" --strip-disallowed-xattrs)
  if [[ "$config" == "release" && "$identity" == *"Developer ID"* ]]; then
    sign_args+=(--options runtime --timestamp)
  fi
  codesign "${sign_args[@]}" "$app"
else
  echo "警告：权限可能每次构建后失效" >&2
  codesign --force --sign - --strip-disallowed-xattrs "$app"
fi

codesign --verify --deep --strict "$app"
echo "已组装 $app"
