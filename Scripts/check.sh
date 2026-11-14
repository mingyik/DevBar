#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

echo "== swift format lint =="
swift format lint --strict -r Sources Tests

echo "== web =="
(
  cd Web
  if [[ ! -d node_modules || ! -f node_modules/.package-lock.json || package-lock.json -nt node_modules/.package-lock.json ]]; then
    npm ci
  fi
  npm run lint
  npm test
  npm run build
)

echo "== swift build =="
swift build

echo "== swift test =="
swift test

echo "== tokens =="
node --test Scripts/gen-tokens.test.ts
node Scripts/gen-tokens.ts --check

echo "== swift literal colors =="
node --test Scripts/check-swift-colors.test.ts
node Scripts/check-swift-colors.ts
