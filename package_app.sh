#!/bin/bash
# Builds a universal (x86_64 + arm64) "Double Finder.app" into ./.dist.
# Usage: ./package_app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Double Finder"
DIST=".dist"
APPDIR="$DIST/$APP.app"

echo "==> Universal release build (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP"

echo "==> Assembling $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP"
chmod +x "$APPDIR/Contents/MacOS/$APP"
echo "    binary archs: $(lipo -archs "$APPDIR/Contents/MacOS/$APP")"

echo "==> Bundle Localization resource pack"
RESBUNDLE="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/double-finder_double-finder.bundle"
if [ -d "$RESBUNDLE" ]; then
    cp -R "$RESBUNDLE" "$APPDIR/Contents/Resources/"
    echo "    bundled $(basename "$RESBUNDLE") ($(find "$RESBUNDLE" -name '*.json' | wc -l | tr -d ' ') json packs)"
else
    echo "ERROR: resource bundle not found at $RESBUNDLE — localization pack missing, aborting packaging"
    exit 1
fi

echo "==> Bundle 7zz (for encrypted 7z; libarchive can't decrypt those)"
SEVENZIP="vendor/sevenzip/7zz"
# Not committed to git — fetch the official universal build on first package.
SEVENZIP_VER="24.09"
if [ ! -x "$SEVENZIP" ]; then
    echo "    fetching official universal 7zz $SEVENZIP_VER (not in repo)…"
    mkdir -p vendor/sevenzip
    tmp="$(mktemp -d)"
    url="https://github.com/ip7z/7zip/releases/download/${SEVENZIP_VER}/7z${SEVENZIP_VER//./}-mac.tar.xz"
    if curl -fsSL --max-time 120 -o "$tmp/7z.tar.xz" "$url" && tar -xf "$tmp/7z.tar.xz" -C "$tmp" 2>/dev/null; then
        cp "$tmp/7zz" "$SEVENZIP"; chmod +x "$SEVENZIP"
        [ -f "$tmp/License.txt" ] && cp "$tmp/License.txt" vendor/sevenzip/License.txt
        echo "    downloaded $(lipo -archs "$SEVENZIP")"
    else
        echo "    !! download failed — place a universal 7zz at $SEVENZIP manually (see vendor/sevenzip/README.md)"
    fi
    rm -rf "$tmp"
fi
if [ -x "$SEVENZIP" ]; then
    cp "$SEVENZIP" "$APPDIR/Contents/MacOS/7zz"
    chmod +x "$APPDIR/Contents/MacOS/7zz"
    cp vendor/sevenzip/License.txt "$APPDIR/Contents/Resources/sevenzip-License.txt"
    echo "    7zz archs: $(lipo -archs "$APPDIR/Contents/MacOS/7zz")"
    case "$(lipo -archs "$APPDIR/Contents/MacOS/7zz")" in
        *x86_64*arm64*|*arm64*x86_64*) : ;;
        *) echo "    !! WARNING: bundled 7zz is NOT universal — encrypted 7z may need Rosetta" ;;
    esac
else
    echo "    !! vendor/sevenzip/7zz missing — encrypted 7z will fall back to a system 7z (brew install sevenzip)"
fi

echo "==> Info.plist"
cp Info.plist "$APPDIR/Contents/Info.plist"
plutil -replace CFBundleIconFile -string "AppIcon" "$APPDIR/Contents/Info.plist"

echo "==> App icon (.icns, drawn in code)"
ICONSET="$DIST/AppIcon.iconset"
PNG="$DIST/icon1024.png"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
NC_EXPORT_ICON="$PNG" "$APPDIR/Contents/MacOS/$APP"
gen() { sips -z "$1" "$1" "$PNG" --out "$ICONSET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png
iconutil -c icns "$ICONSET" -o "$APPDIR/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$PNG"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APPDIR"

echo "==> Done"
echo "    $APPDIR"
lipo -info "$APPDIR/Contents/MacOS/$APP"
codesign -dv "$APPDIR" 2>&1 | grep -E "Identifier|Signature" || true
