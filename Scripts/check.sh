#!/bin/bash
# 全部检查。tokens 一致性属于 T0.2，本脚本不伪造该项通过。
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

echo "== swift format lint =="
swift format lint -r Sources Tests

echo "== swift build =="
swift build

echo "== swift test =="
swift test

echo "== web =="
(
  cd Web
  if [[ ! -d node_modules ]]; then
    npm ci
  fi
  npm run lint
  npm test
  npm run build
)

echo "== tokens =="
# T0.2 才会加入 Scripts/gen-tokens.ts --check。不要在这里假装比较过产物。
echo "tokens 检查尚未实现，归属 T0.2"
