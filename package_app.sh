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

# VLCKit (libVLC framework, LGPL-2.1) gives the media player its decoders.
# Not in git: fetch it before the build so Package.swift links it. A failed
# download is not fatal — the app then plays AVFoundation's formats only.
if [ ! -d vendor/VLCKit/VLCKit.xcframework ]; then
    Tools/fetch-vlckit.sh || echo "    !! VLCKit not available — media player limited to AVFoundation formats"
fi

# libmtp + libusb (LGPL-2.1) for the Android/MTP backend, built from source
# with the deployment target pinned to 13.0 (see Tools/build-mtp-libs.sh for
# why a Homebrew bottle must not be shipped). Package.swift links vendor/mtp
# when it exists, but SwiftPM does not notice the directory appearing, so a
# release binary linked earlier against brew must be relinked: drop it.
BIN="$(swift build -c release --arch "$HOST_ARCH" --show-bin-path)/$APP"
if [ ! -f vendor/mtp/lib/libmtp.9.dylib ]; then
    if Tools/build-mtp-libs.sh; then
        rm -f "$BIN"
    else
        echo "    !! vendor/mtp build failed — falling back to Homebrew libmtp (release-unsafe on older macOS)"
    fi
fi

echo "==> Release build for this host ($HOST_ARCH)"
swift build -c release --arch "$HOST_ARCH"

echo "==> Assembling $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/$APP"
chmod +x "$APPDIR/Contents/MacOS/$APP"
echo "    binary archs: $(lipo -archs "$APPDIR/Contents/MacOS/$APP")"

echo "==> Bundle the plugin API dylib (DoubleFinderPluginKit)"
# The public plugin API is a real dynamic library (PluginKit/ package): the
# executable references @rpath/libDoubleFinderPluginKit.dylib and every
# .dfplugin bundle links the same install name, so one copy in Frameworks
# serves both. The rpath is added here (not only in the libmtp block below)
# because the app must find PluginKit even when libmtp wasn't bundled.
KIT_LIB="$(swift build -c release --arch "$HOST_ARCH" --show-bin-path)/libDoubleFinderPluginKit.dylib"
if [ ! -f "$KIT_LIB" ]; then
    echo "ERROR: $KIT_LIB not found — PluginKit did not build, aborting packaging"
    exit 1
fi
mkdir -p "$APPDIR/Contents/Frameworks" "$APPDIR/Contents/PlugIns"
cp "$KIT_LIB" "$APPDIR/Contents/Frameworks/libDoubleFinderPluginKit.dylib"
chmod u+w "$APPDIR/Contents/Frameworks/libDoubleFinderPluginKit.dylib"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APPDIR/Contents/MacOS/$APP" 2>/dev/null || true
echo "    bundled libDoubleFinderPluginKit.dylib ($(lipo -archs "$APPDIR/Contents/Frameworks/libDoubleFinderPluginKit.dylib"))"

echo "==> Bundle VLCKit (libVLC media decoding; LGPL-2.1, dynamically linked framework)"
# Must precede the icon export below, which RUNS the binary: it links
# @rpath/VLCKit.framework and dyld resolves that through the rpath added above.
VLCKIT_FW="vendor/VLCKit/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework"
VLCKIT_BUNDLED=0
if otool -L "$APPDIR/Contents/MacOS/$APP" | grep -q "VLCKit.framework"; then
    if [ ! -d "$VLCKIT_FW" ]; then
        echo "ERROR: the binary links VLCKit but $VLCKIT_FW is missing (run Tools/fetch-vlckit.sh)"
        exit 1
    fi
    FW_DST="$APPDIR/Contents/Frameworks/VLCKit.framework"
    rm -rf "$FW_DST"
    ditto "$VLCKIT_FW" "$FW_DST"
    # Runtime needs the binary and Resources only: drop headers / modules and
    # thin the fat binary to the host architecture (~81 MB → ~40 MB).
    rm -rf "$FW_DST/Versions/A/Headers" "$FW_DST/Versions/A/PrivateHeaders" "$FW_DST/Versions/A/Modules" \
           "$FW_DST/Headers" "$FW_DST/PrivateHeaders" "$FW_DST/Modules"
    FW_BIN="$FW_DST/Versions/A/VLCKit"
    if [ "$(lipo -archs "$FW_BIN" | wc -w | tr -d ' ')" != "1" ]; then
        lipo -thin "$HOST_ARCH" "$FW_BIN" -output "$FW_BIN.thin" && mv "$FW_BIN.thin" "$FW_BIN"
    fi
    VLCKIT_BUNDLED=1
    echo "    bundled VLCKit $(cat vendor/VLCKit/VERSION 2>/dev/null || echo unknown) ($(lipo -archs "$FW_BIN"), $(du -sh "$FW_DST" | cut -f1))"
else
    echo "    not linked — media player limited to AVFoundation formats"
fi

echo "==> Bundle Localization resource pack"
RESBUNDLE="$(swift build -c release --arch "$HOST_ARCH" --show-bin-path)/double-finder_double-finder.bundle"
if [ -d "$RESBUNDLE" ]; then
    cp -R "$RESBUNDLE" "$APPDIR/Contents/Resources/"
    echo "    bundled $(basename "$RESBUNDLE") ($(find "$RESBUNDLE" -name '*.json' | wc -l | tr -d ' ') json packs)"
else
    echo "ERROR: resource bundle not found at $RESBUNDLE — localization pack missing, aborting packaging"
    exit 1
fi

echo "==> Project licence files (Apache-2.0 LICENSE + NOTICE + third-party attributions)"
cp LICENSE "$APPDIR/Contents/Resources/LICENSE.txt"
cp NOTICE "$APPDIR/Contents/Resources/NOTICE.txt"
cp THIRD-PARTY.md "$APPDIR/Contents/Resources/THIRD-PARTY.md"

echo "==> 7-Zip licence (the 7z engine is compiled in from Sources/CSevenZip; LGPL-2.1 §6 requires the full licence text)"
cp Sources/CSevenZip/7zip/DOC/License.txt "$APPDIR/Contents/Resources/sevenzip-License.txt"
cp Sources/CSevenZip/7zip/DOC/copying.txt "$APPDIR/Contents/Resources/sevenzip-LGPL-2.1.txt"

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

# The repository Info.plist carries placeholders (0.0.0 / 0); the real version
# is stamped from git here. CFBundleShortVersionString comes from the newest
# release tag ("1.0.10" or "v1.0.10" — the rolling "latest" prerelease tag is
# not a version and must not match), CFBundleVersion from the commit count
# (monotonic, what macOS compares), DFGitRevision from the short sha.
# DF_VERSION=x.y.z overrides the tag lookup for tarball builds with no git
# history. Needs the full history + tags: CI checks out with fetch-depth 0.
echo "==> Version stamp"
if [ -n "${DF_VERSION:-}" ]; then
    SHORT_VER="$DF_VERSION"
else
    SHORT_VER="$(git describe --tags --abbrev=0 --match '[0-9]*' --match 'v[0-9]*' 2>/dev/null || true)"
    SHORT_VER="${SHORT_VER#v}"
    if [ -z "$SHORT_VER" ]; then
        echo "    !! no release tag reachable and DF_VERSION not set — keeping the 0.0.0 placeholder"
        SHORT_VER="0.0.0"
    fi
fi
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
GIT_REV="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then GIT_REV="$GIT_REV-dirty"; fi
plutil -replace CFBundleShortVersionString -string "$SHORT_VER" "$APPDIR/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUM" "$APPDIR/Contents/Info.plist"
plutil -replace DFGitRevision -string "$GIT_REV" "$APPDIR/Contents/Info.plist"
echo "    $SHORT_VER ($BUILD_NUM) $GIT_REV"

# The icon export below RUNS the binary, and the rpath added for the PluginKit
# dylib above already invalidated the linker's ad-hoc signature — macOS then
# refuses to exec it ("Killed: 9"). Re-sign before running it; the final
# codesign --deep at the end signs the finished bundle again anyway.
codesign --force --sign - "$APPDIR/Contents/MacOS/$APP" 2>/dev/null || true

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
# Prefer the build from Tools/build-mtp-libs.sh: it is compiled with the
# deployment target pinned to 13.0, whereas a Homebrew bottle carries the
# build machine's macOS as its minimum and dyld refuses to load it on anything
# older ("built for macOS 15.0 which is newer than running OS") — which would
# sink the whole app on macOS 13/14, Android or not.
if [ -f "vendor/mtp/lib/libmtp.9.dylib" ] && [ -f "vendor/mtp/lib/libusb-1.0.0.dylib" ]; then
    MTP_PREFIX="$PWD/vendor/mtp"; USB_PREFIX="$PWD/vendor/mtp"; MTP_ORIGIN=vendored
else
    MTP_PREFIX="$(brew --prefix libmtp 2>/dev/null || echo /opt/homebrew/opt/libmtp)"
    USB_PREFIX="$(brew --prefix libusb 2>/dev/null || echo /opt/homebrew/opt/libusb)"
    MTP_ORIGIN=homebrew
fi
MTP_LIB="$MTP_PREFIX/lib/libmtp.9.dylib"
USB_LIB="$USB_PREFIX/lib/libusb-1.0.0.dylib"
if [ -f "$MTP_LIB" ] && [ -f "$USB_LIB" ]; then
    echo "    source: $MTP_ORIGIN ($MTP_PREFIX)"
    # The executable must actually have been linked against this copy — the
    # load command records the dylib's install name, and the rewrite below keys
    # on it. A stale .build linked against brew while vendor/mtp exists (or the
    # reverse) would otherwise bundle one library and load another.
    MTP_LOAD="$(otool -L "$APPDIR/Contents/MacOS/$APP" | awk '/libmtp\.9\.dylib/{print $1; exit}')"
    if [ "$MTP_LOAD" != "$MTP_LIB" ]; then
        echo "ERROR: the binary links $MTP_LOAD but packaging would bundle $MTP_LIB"
        echo "       rebuild (swift build -c release) so both agree, then package again"
        exit 1
    fi
    USB_LOAD="$(otool -L "$MTP_LIB" | awk '/libusb-1\.0\.0\.dylib/{print $1; exit}')"
    mkdir -p "$APPDIR/Contents/Frameworks"
    cp "$MTP_LIB" "$APPDIR/Contents/Frameworks/libmtp.9.dylib"
    cp "$USB_LIB" "$APPDIR/Contents/Frameworks/libusb-1.0.0.dylib"
    chmod u+w "$APPDIR/Contents/Frameworks/libmtp.9.dylib" "$APPDIR/Contents/Frameworks/libusb-1.0.0.dylib"
    # Resolve both libs from inside the bundle instead of the Homebrew prefix,
    # so the shipped app needs no brew install. Must happen BEFORE codesign.
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APPDIR/Contents/MacOS/$APP" 2>/dev/null || true
    install_name_tool -change "$MTP_LOAD" "@rpath/libmtp.9.dylib" "$APPDIR/Contents/MacOS/$APP"
    install_name_tool -id "@rpath/libmtp.9.dylib" "$APPDIR/Contents/Frameworks/libmtp.9.dylib"
    install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$APPDIR/Contents/Frameworks/libusb-1.0.0.dylib"
    # libmtp itself pulls in libusb — repoint that edge too.
    install_name_tool -change "$USB_LOAD" "@rpath/libusb-1.0.0.dylib" "$APPDIR/Contents/Frameworks/libmtp.9.dylib"
    # LGPL-2.1 compliance: ship the license next to the dynamically linked libs.
    for lic in "$MTP_PREFIX/libmtp-COPYING.txt" "$MTP_PREFIX/COPYING" "$MTP_PREFIX/../../Cellar/libmtp/"*/COPYING; do
        [ -f "$lic" ] && cp "$lic" "$APPDIR/Contents/Frameworks/libmtp-COPYING.txt" && break
    done
    for lic in "$USB_PREFIX/libusb-COPYING.txt" "$USB_PREFIX/COPYING" "$USB_PREFIX/../../Cellar/libusb/"*/COPYING; do
        [ -f "$lic" ] && cp "$lic" "$APPDIR/Contents/Frameworks/libusb-COPYING.txt" && break
    done
    # LGPL-2.1 §4: the shipped dylibs are unmodified builds of the upstream
    # releases; record the exact versions and where the corresponding source
    # lives so a recipient can obtain (and rebuild / replace) them.
    if [ "$MTP_ORIGIN" = vendored ]; then
        MTP_VER="$(awk '/^libmtp /{print $2}' vendor/mtp/VERSION)"
        USB_VER="$(awk '/^libusb /{print $2}' vendor/mtp/VERSION)"
        MTP_BUILT_BY="compiled from the unmodified upstream sources by Tools/build-mtp-libs.sh
(deployment target macOS $(awk '/^deployment-target /{print $2}' vendor/mtp/VERSION))"
    else
        # Cellar directory names carry a "_N" revision suffix on formula rebuilds
        # (e.g. 1.1.23_1) — the upstream tarball is named after the bare version.
        MTP_VER="$(basename "$(readlink -f "$MTP_PREFIX")")"; MTP_VER="${MTP_VER%%_*}"
        USB_VER="$(basename "$(readlink -f "$USB_PREFIX")")"; USB_VER="${USB_VER%%_*}"
        MTP_BUILT_BY="unmodified builds installed by Homebrew (https://brew.sh)"
    fi
    cat > "$APPDIR/Contents/Frameworks/SOURCES.txt" <<EOF2
The dynamic libraries in this folder are ${MTP_BUILT_BY}
and are licensed under the GNU LGPL 2.1 or later
(see libmtp-COPYING.txt and libusb-COPYING.txt). Double Finder links them
dynamically; you may replace them with your own build of the same library.

libmtp ${MTP_VER}
  https://downloads.sourceforge.net/project/libmtp/libmtp/${MTP_VER}/libmtp-${MTP_VER}.tar.gz
  https://github.com/libmtp/libmtp
  Homebrew formula: https://github.com/Homebrew/homebrew-core/blob/master/Formula/lib/libmtp.rb

libusb ${USB_VER}
  https://github.com/libusb/libusb/releases/download/v${USB_VER}/libusb-${USB_VER}.tar.bz2
  https://github.com/libusb/libusb
  Homebrew formula: https://github.com/Homebrew/homebrew-core/blob/master/Formula/lib/libusb.rb
EOF2
    echo "    recorded libmtp $MTP_VER + libusb $USB_VER sources in Frameworks/SOURCES.txt"
    echo "    bundled libmtp ($(lipo -archs "$APPDIR/Contents/Frameworks/libmtp.9.dylib")) + libusb"
    if ! lipo -archs "$APPDIR/Contents/Frameworks/libmtp.9.dylib" | grep -q "$HOST_ARCH"; then
        echo "    !! WARNING: bundled libmtp does not cover $HOST_ARCH — Android support will fail"
    fi
    # dyld refuses a dylib whose minimum macOS is newer than the running one,
    # so a bundled library newer than the app's own deployment target silently
    # raises the app's real minimum. Compare each against the executable.
    APP_MINOS="$(otool -l "$APPDIR/Contents/MacOS/$APP" | grep -A3 -m1 LC_BUILD_VERSION | awk '/minos/{print $2}')"
    for lib in libmtp.9.dylib libusb-1.0.0.dylib; do
        LIB_MINOS="$(otool -l "$APPDIR/Contents/Frameworks/$lib" | grep -A3 -m1 LC_BUILD_VERSION | awk '/minos/{print $2}')"
        if [ "$(printf '%s\n%s\n' "$APP_MINOS" "$LIB_MINOS" | sort -V | tail -1)" != "$APP_MINOS" ]; then
            echo "    !! WARNING: $lib requires macOS $LIB_MINOS but the app declares $APP_MINOS —"
            echo "       the app will not launch on macOS < $LIB_MINOS. Use Tools/build-mtp-libs.sh for releases."
        fi
    done
    echo "    minimum macOS: app $APP_MINOS, libmtp $(otool -l "$APPDIR/Contents/Frameworks/libmtp.9.dylib" | grep -A3 -m1 LC_BUILD_VERSION | awk '/minos/{print $2}')"
else
    echo "    !! libmtp/libusb not found — the app will NOT launch (run Tools/build-mtp-libs.sh)"
    echo "       looked for: $MTP_LIB"
fi

if [ "$VLCKIT_BUNDLED" = 1 ]; then
    echo "==> VLCKit licence + corresponding-source pointers"
    cp vendor/VLCKit/COPYING.txt "$APPDIR/Contents/Frameworks/VLCKit-COPYING.txt"
    VLCKIT_VER="$(cat vendor/VLCKit/VERSION 2>/dev/null || echo unknown)"
    cat >> "$APPDIR/Contents/Frameworks/SOURCES.txt" <<EOF2

VLCKit ${VLCKIT_VER} (libVLC + VLC modules, LGPL-2.1; see VLCKit-COPYING.txt)
  Double Finder links the unmodified binary framework published by VideoLAN
  (only its install name is made @rpath-relative) and uses it for decoding /
  playback in the built-in media player.
  Binary:  https://download.videolan.org/pub/cocoapods/prod/
  Source:  https://code.videolan.org/videolan/VLCKit  (tag ${VLCKIT_VER})
           https://code.videolan.org/videolan/vlc     (VLC 3.0 branch + contribs)
EOF2
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
