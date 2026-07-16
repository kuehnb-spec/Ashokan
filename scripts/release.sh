#!/bin/zsh
# Ashokan distribution pipeline: optimized Release build → Developer ID
# signing (hardened runtime) → Apple notarization → staple → zip.
# Degrades gracefully: without a certificate it produces an ad-hoc-signed
# Release zip and says exactly what's missing.
#
# One-time prerequisites for full notarization:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. xcrun notarytool store-credentials AshokanNotary \
#        --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
#
# Usage: scripts/release.sh            (build + sign + notarize + zip)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD)"
APP="build/Build/Products/Release/Ashokan.app"
ZIP="dist/Ashokan-${VERSION}.zip"

echo "== Building Ashokan ${VERSION} (${BUILD_NUMBER}) Release =="
(cd editor && [ -d node_modules ] || npm install --no-audit --no-fund)
(cd editor && npm run build)
cp docs/ROADMAP.html Ashokan/Resources/roadmap.html
xcodegen > /dev/null
xcodebuild -project Ashokan.xcodeproj -scheme Ashokan -configuration Release \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -derivedDataPath build build | tail -2

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')"

mkdir -p dist
if [ -z "$IDENTITY" ]; then
  echo "!! No 'Developer ID Application' certificate found — producing ad-hoc Release zip."
  echo "   (Create one in Xcode > Settings > Accounts > Manage Certificates.)"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Unsigned Release zip: $ZIP"
  exit 0
fi

echo "== Signing with: $IDENTITY =="
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if ! xcrun notarytool history --keychain-profile AshokanNotary > /dev/null 2>&1; then
  echo "!! Signed, but no 'AshokanNotary' keychain profile — skipping notarization."
  echo "   (Run: xcrun notarytool store-credentials AshokanNotary --apple-id … --team-id … --password …)"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Signed (un-notarized) zip: $ZIP"
  exit 0
fi

echo "== Notarizing (this can take a few minutes) =="
NOTARIZE_ZIP="dist/Ashokan-${VERSION}-notarize.zip"
ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile AshokanNotary --wait
rm "$NOTARIZE_ZIP"

echo "== Stapling ticket =="
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP" || true

ditto -c -k --keepParent "$APP" "$ZIP"

echo "== Building DMG (drag-to-Applications installer) =="
DMG="dist/Ashokan-${VERSION}.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Ashokan" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "== Notarizing DMG =="
xcrun notarytool submit "$DMG" --keychain-profile AshokanNotary --wait
xcrun stapler staple "$DMG"

echo "== Done: $DMG + $ZIP (signed, notarized, stapled) =="
echo "Install locally with: rm -rf /Applications/Ashokan.app && ditto -xk $ZIP /Applications/"
