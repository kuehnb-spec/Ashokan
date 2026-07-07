#!/bin/zsh
# Build Ashokan from a clean checkout:
#   1. bundle the ProseMirror editing core (needs node; skipped if the
#      committed bundle is present and node is missing)
#   2. generate the Xcode project from project.yml
#   3. build the app
#
# Result: build/Build/Products/Debug/Ashokan.app
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v npm >/dev/null; then
  (cd editor && [ -d node_modules ] || npm install --no-audit --no-fund)
  (cd editor && npm run build)
elif [ ! -f Ashokan/Resources/editor.js ]; then
  echo "error: node/npm not found and Ashokan/Resources/editor.js is missing" >&2
  exit 1
fi

xcodegen
xcodebuild -project Ashokan.xcodeproj -scheme Ashokan -configuration Debug \
  -derivedDataPath build build | tail -3
echo "App: build/Build/Products/Debug/Ashokan.app"
