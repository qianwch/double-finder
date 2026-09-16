#!/bin/bash
# Fetches the VLCKit binary framework (libVLC for macOS, LGPL-2.1) that the
# built-in media player links, into vendor/VLCKit/. Not committed (88 MB
# download, ~420 MB unpacked); Package.swift picks it up when present and
# builds the player without it otherwise (AVFoundation formats only).
#
#   Tools/fetch-vlckit.sh            # download + unpack if missing
#   Tools/fetch-vlckit.sh --force    # re-download
set -euo pipefail

VLCKIT_VERSION="3.7.3"
VLCKIT_FILE="VLCKit-${VLCKIT_VERSION}-319ed2c0-79128878.tar.xz"
VLCKIT_URL="https://download.videolan.org/pub/cocoapods/prod/${VLCKIT_FILE}"
VLCKIT_SHA256="019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/VLCKit"
XC="$DEST/VLCKit.xcframework"

if [ -d "$XC" ] && [ "${1:-}" != "--force" ]; then
    echo "VLCKit already present: $XC"
    exit 0
fi

mkdir -p "$DEST"
TAR="$DEST/$VLCKIT_FILE"
if [ ! -f "$TAR" ] || [ "${1:-}" = "--force" ]; then
    echo "==> Downloading $VLCKIT_URL"
    curl -fL --progress-bar -o "$TAR.tmp" "$VLCKIT_URL"
    mv "$TAR.tmp" "$TAR"
fi

echo "==> Verifying checksum"
ACTUAL="$(shasum -a 256 "$TAR" | awk '{print $1}')"
if [ "$ACTUAL" != "$VLCKIT_SHA256" ]; then
    echo "!! checksum mismatch for $TAR" >&2
    echo "   expected $VLCKIT_SHA256" >&2
    echo "   actual   $ACTUAL" >&2
    exit 1
fi

echo "==> Unpacking"
TMP="$(mktemp -d)"
# COPYFILE_DISABLE: without it bsdtar materializes the archive's AppleDouble
# entries as ._* files *inside* the framework, and codesign then refuses it
# ("unsealed contents present in the root directory of an embedded framework").
# The framework stays unsigned, and dyld SIGKILLs anything that maps it
# (EXC_BAD_ACCESS / CODESIGNING "Invalid Page"). Belt and braces: sweep any
# that slipped in, here or through a file-sync round trip.
COPYFILE_DISABLE=1 tar -xJf "$TAR" -C "$TMP"
PKG="$(find "$TMP" -maxdepth 1 -type d -name 'VLCKit*' | head -1)"
rm -rf "$XC"
mv "$PKG/VLCKit.xcframework" "$XC"
cp "$PKG/COPYING.txt" "$DEST/COPYING.txt"
[ -f "$PKG/NEWS.txt" ] && cp "$PKG/NEWS.txt" "$DEST/NEWS.txt"
echo "$VLCKIT_VERSION" > "$DEST/VERSION"
rm -rf "$TMP"

# VideoLAN ships the framework with the install name
# @loader_path/../Frameworks/VLCKit.framework/Versions/A/VLCKit, which only
# resolves inside an .app. Make it @rpath-relative so the bare `swift build`
# executable (rpath @loader_path, SwiftPM copies the framework next to it) and
# the packaged app (rpath @executable_path/../Frameworks) both find it, then
# re-sign ad hoc — the edit voids VideoLAN's signature and dyld refuses
# unsigned code on Apple silicon.
FW="$XC/macos-arm64_x86_64/VLCKit.framework"
find "$XC" \( -name '._*' -o -name '.DS_Store' \) -delete
install_name_tool -id "@rpath/VLCKit.framework/Versions/A/VLCKit" "$FW/Versions/A/VLCKit"
codesign --force --sign - "$FW" || codesign --force --deep --sign - "$FW"
codesign -v "$FW" || { echo "ERROR: VLCKit.framework did not sign cleanly — see the ._* note above"; exit 1; }
echo "    $XC"
echo "    $(lipo -archs "$XC/macos-arm64_x86_64/VLCKit.framework/VLCKit") · VLCKit $VLCKIT_VERSION"
