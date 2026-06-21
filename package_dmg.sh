#!/bin/bash
# Builds "Double Finder.app" (via package_app.sh) and wraps it into a
# drag-to-install .dmg using only built-in tools (hdiutil) — zero external deps.
# Produces ./.dist/Double Finder.dmg (volume shows the app + an Applications alias).
# Usage: ./package_dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Double Finder"
DIST=".dist"
APPDIR="$DIST/$APP.app"
DMG="$DIST/$APP.dmg"
VOL="$APP"

echo "==> Build the .app"
./package_app.sh

echo "==> Stage DMG contents (app + Applications symlink)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APPDIR" "$STAGE/$APP.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Create compressed disk image"
rm -f "$DMG"
hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG"

echo "==> Ad-hoc code signing the disk image"
codesign --force --sign - "$DMG"

echo "==> Done"
echo "    $DMG  ($(du -h "$DMG" | cut -f1))"
hdiutil imageinfo "$DMG" | grep -E "^Format:|Checksum Type:" || true
codesign -dv "$DMG" 2>&1 | grep -E "Identifier|Signature" || true
