#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

echo "== swift format lint =="
swift format lint --strict -r Sources Tests

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
node --test Scripts/gen-tokens.test.ts
node Scripts/gen-tokens.ts --check

echo "== swift literal colors =="
color_hits="$(
  find Sources Tests -name '*.swift' -not -path '*/Generated/*' -print0 |
    xargs -0 grep -nE \
      -e 'Color\(red:' \
      -e 'NSColor\(calibratedRed:' \
      -e 'NSColor\(red:' \
      -e '#colorLiteral' \
      -e 'rgba?\(' \
      -e 'hsla?\(' \
      -e '#[0-9A-Fa-f]{3,8}' || true
)"
color_hits="$(printf '%s\n' "$color_hits" | grep -vE '#[eE]xpect\b|#require\b|#available\b|#selector\b|#file(ID|Path)?\b|#line\b|#function\b|#warning\b|#error\b|#column\b|#sourceLocation\b|#if\b|#elseif\b|#else\b|#endif\b' || true)"
if [[ -n "$color_hits" ]]; then
  printf '%s\n' "$color_hits" >&2
  echo "业务代码出现字面颜色（Generated/ 与 design/ 除外）" >&2
  exit 1
fi
