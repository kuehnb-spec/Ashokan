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

# Bundle the current roadmap so Help > Roadmap always shows the live plan.
cp docs/ROADMAP.html Ashokan/Resources/roadmap.html

xcodegen
# Version from the VERSION file; build number from the git commit count.
MARKETING_VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
xcodebuild -project Ashokan.xcodeproj -scheme Ashokan -configuration Debug \
  MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -derivedDataPath build build | tail -3

# Install where Spotlight, Finder, and the Dock can see it.
DEST=/Applications/Ashokan.app
[ -w /Applications ] || DEST="$HOME/Applications/Ashokan.app"
mkdir -p "$(dirname "$DEST")"
ditto build/Build/Products/Debug/Ashokan.app "$DEST"
echo "Installed: $DEST"
