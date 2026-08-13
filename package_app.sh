#!/bin/bash
# Builds "Double Finder.app" into ./.dist for the ARCHITECTURE OF THIS MACHINE
# (arm64 on Apple Silicon, x86_64 on Intel).
#
# It used to build universal, but the Android/MTP backend links libmtp, and
# Homebrew now ships a single bottle (arm64 only) — every other platform builds
# it from source. That makes both halves of a universal dylib unobtainable on
# any one machine, so the app follows the host architecture instead: build on
# an Apple Silicon Mac to ship Apple Silicon, on an Intel Mac to ship Intel.
# Usage: ./package_app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Double Finder"
DIST=".dist"
APPDIR="$DIST/$APP.app"
HOST_ARCH="$(uname -m)"

echo "==> Release build for this host ($HOST_ARCH)"
swift build -c release --arch "$HOST_ARCH"
BIN="$(swift build -c release --arch "$HOST_ARCH" --show-bin-path)/$APP"

echo "==> Assembling $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP"
chmod +x "$APPDIR/Contents/MacOS/$APP"
echo "    binary archs: $(lipo -archs "$APPDIR/Contents/MacOS/$APP")"

echo "==> Bundle Localization resource pack"
RESBUNDLE="$(swift build -c release --arch "$HOST_ARCH" --show-bin-path)/double-finder_double-finder.bundle"
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
        *"$HOST_ARCH"*) : ;;   # covers this host — fine whether or not it's universal
        *x86_64*arm64*|*arm64*x86_64*) : ;;
        *) echo "    !! WARNING: bundled 7zz is NOT universal — encrypted 7z may need Rosetta" ;;
    esac
else
    echo "    !! vendor/sevenzip/7zz missing — encrypted 7z will fall back to a system 7z (brew install sevenzip)"
fi

echo "==> Bundle mermaid.min.js (Lister mermaid rendering; MIT)"
MERMAID="vendor/mermaid/mermaid.min.js"
MERMAID_VER="11.16.1"
if [ ! -f "$MERMAID" ]; then
    echo "    fetching mermaid $MERMAID_VER (not in repo)…"
    mkdir -p vendor/mermaid
    if curl -fsSL --max-time 120 -o "$MERMAID.tmp" \
        "https://cdn.jsdelivr.net/npm/mermaid@${MERMAID_VER}/dist/mermaid.min.js"; then
        mv "$MERMAID.tmp" "$MERMAID"
    else
        rm -f "$MERMAID.tmp"
        echo "    !! download failed — mermaid blocks will show as source (see vendor/mermaid/README.md)"
    fi
fi
if [ -f "$MERMAID" ]; then
    cp "$MERMAID" "$APPDIR/Contents/Resources/mermaid.min.js"
    cp vendor/mermaid/LICENSE "$APPDIR/Contents/Resources/mermaid-License.txt"
    echo "    bundled mermaid.min.js ($(du -h "$MERMAID" | cut -f1))"
fi

echo "==> Bundle plantuml.jar (Lister plantuml rendering; MIT edition; needs a system Java)"
PLANTUML="vendor/plantuml/plantuml.jar"
PLANTUML_VER="1.2026.6"
if [ ! -f "$PLANTUML" ]; then
    echo "    fetching PlantUML $PLANTUML_VER MIT edition (not in repo)…"
    mkdir -p vendor/plantuml
    if curl -fsSL --max-time 180 -o "$PLANTUML.tmp" \
        "https://github.com/plantuml/plantuml/releases/download/v${PLANTUML_VER}/plantuml-mit-${PLANTUML_VER}.jar"; then
        mv "$PLANTUML.tmp" "$PLANTUML"
    else
        rm -f "$PLANTUML.tmp"
        echo "    !! download failed — plantuml blocks fall back to a brew-installed plantuml (see vendor/plantuml/README.md)"
    fi
fi
if [ -f "$PLANTUML" ]; then
    cp "$PLANTUML" "$APPDIR/Contents/Resources/plantuml.jar"
    cp vendor/plantuml/LICENSE "$APPDIR/Contents/Resources/plantuml-License.txt"
    echo "    bundled plantuml.jar ($(du -h "$PLANTUML" | cut -f1))"
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

# Done after the icon export above, which runs the binary: install_name_tool
# invalidates the ad-hoc signature the linker applied, and macOS refuses to
# exec a binary whose signature no longer matches (SIGKILL). The final
# codesign --deep below re-signs the app and both dylibs.
echo "==> Bundle libmtp + libusb (Android/MTP backend; LGPL-2.1, dynamically linked)"
MTP_PREFIX="$(brew --prefix libmtp 2>/dev/null || echo /opt/homebrew/opt/libmtp)"
USB_PREFIX="$(brew --prefix libusb 2>/dev/null || echo /opt/homebrew/opt/libusb)"
MTP_LIB="$MTP_PREFIX/lib/libmtp.9.dylib"
USB_LIB="$USB_PREFIX/lib/libusb-1.0.0.dylib"
if [ -f "$MTP_LIB" ] && [ -f "$USB_LIB" ]; then
    mkdir -p "$APPDIR/Contents/Frameworks"
    cp "$MTP_LIB" "$APPDIR/Contents/Frameworks/libmtp.9.dylib"
    cp "$USB_LIB" "$APPDIR/Contents/Frameworks/libusb-1.0.0.dylib"
    chmod u+w "$APPDIR/Contents/Frameworks/libmtp.9.dylib" "$APPDIR/Contents/Frameworks/libusb-1.0.0.dylib"
    # Resolve both libs from inside the bundle instead of the Homebrew prefix,
    # so the shipped app needs no brew install. Must happen BEFORE codesign.
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APPDIR/Contents/MacOS/$APP" 2>/dev/null || true
    install_name_tool -change "$MTP_LIB" "@rpath/libmtp.9.dylib" "$APPDIR/Contents/MacOS/$APP"
    install_name_tool -id "@rpath/libmtp.9.dylib" "$APPDIR/Contents/Frameworks/libmtp.9.dylib"
    install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$APPDIR/Contents/Frameworks/libusb-1.0.0.dylib"
    # libmtp itself pulls in libusb — repoint that edge too.
    install_name_tool -change "$USB_LIB" "@rpath/libusb-1.0.0.dylib" "$APPDIR/Contents/Frameworks/libmtp.9.dylib"
    # LGPL-2.1 compliance: ship the license next to the dynamically linked libs.
    for lic in "$MTP_PREFIX/COPYING" "$MTP_PREFIX/../../Cellar/libmtp/"*/COPYING; do
        [ -f "$lic" ] && cp "$lic" "$APPDIR/Contents/Frameworks/libmtp-COPYING.txt" && break
    done
    for lic in "$USB_PREFIX/COPYING" "$USB_PREFIX/../../Cellar/libusb/"*/COPYING; do
        [ -f "$lic" ] && cp "$lic" "$APPDIR/Contents/Frameworks/libusb-COPYING.txt" && break
    done
    echo "    bundled libmtp ($(lipo -archs "$APPDIR/Contents/Frameworks/libmtp.9.dylib")) + libusb"
    if ! lipo -archs "$APPDIR/Contents/Frameworks/libmtp.9.dylib" | grep -q "$HOST_ARCH"; then
        echo "    !! WARNING: bundled libmtp does not cover $HOST_ARCH — Android support will fail"
    fi
else
    echo "    !! libmtp/libusb not found — the app will NOT launch (brew install libmtp)"
    echo "       looked for: $MTP_LIB"
fi

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "$APPDIR"

echo "==> Install to ~/Applications"
INSTALL_DIR="$HOME/Applications"
mkdir -p "$INSTALL_DIR"
# Replace any previous install (a running instance may hold the old bundle;
# ditto overwrites in place). --noqtn strips the quarantine flag.
rm -rf "$INSTALL_DIR/$APP.app"
ditto --noqtn "$APPDIR" "$INSTALL_DIR/$APP.app"
echo "    installed $INSTALL_DIR/$APP.app"

echo "==> Done"
echo "    $APPDIR"
lipo -info "$APPDIR/Contents/MacOS/$APP"
otool -L "$APPDIR/Contents/MacOS/$APP" | grep -E "mtp|usb" || true
codesign -dv "$APPDIR" 2>&1 | grep -E "Identifier|Signature" || true
