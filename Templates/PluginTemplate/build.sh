#!/bin/bash
# Builds __NAME__.dfplugin into ./.dist. With --install, also copies it to
# ~/Library/Application Support/Double Finder/Plugins (loaded at the next
# launch, or via Settings ▸ Plugins ▸ Rescan).
set -euo pipefail
cd "$(dirname "$0")"

NAME="__NAME__"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/lib${NAME}.dylib"

BUNDLE=".dist/${NAME}.dfplugin"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp "$BIN" "$BUNDLE/Contents/MacOS/$NAME"
chmod u+w "$BUNDLE/Contents/MacOS/$NAME"
# The bundle must resolve @rpath/libDoubleFinderPluginKit.dylib against the
# HOST's copy, never against the one SwiftPM built here: strip every rpath.
for rp in $(otool -l "$BUNDLE/Contents/MacOS/$NAME" | awk '/LC_RPATH/{getline; getline; print $2}'); do
    install_name_tool -delete_rpath "$rp" "$BUNDLE/Contents/MacOS/$NAME" 2>/dev/null || true
done
install_name_tool -id "@rpath/$NAME" "$BUNDLE/Contents/MacOS/$NAME"
codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true
echo "built $BUNDLE"

if [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Library/Application Support/Double Finder/Plugins"
    mkdir -p "$DEST"
    rm -rf "$DEST/${NAME}.dfplugin"
    cp -R "$BUNDLE" "$DEST/"
    echo "installed to $DEST/${NAME}.dfplugin"
fi
