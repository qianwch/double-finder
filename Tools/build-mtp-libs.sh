#!/bin/bash
# Builds libusb + libmtp (both LGPL-2.1) from the pinned upstream tarballs into
# vendor/mtp/, for the Android/MTP backend. Not committed (build products).
#
# Why not `brew install libmtp`: Homebrew builds every bottle for the macOS it
# runs on, so a libmtp.9.dylib taken from a macOS 15 machine carries
# LC_BUILD_VERSION minos 15.0 — and dyld refuses to load it on macOS 13/14
# ("built for macOS 15.0 which is newer than running OS"). The app links libmtp
# directly, so that would sink the whole app on the versions the README
# promises. Building here with MACOSX_DEPLOYMENT_TARGET pinned to the package's
# own deployment target (13.0) gives dylibs that load everywhere the app does,
# regardless of the build machine. Package.swift and package_app.sh prefer
# vendor/mtp/ when it exists and fall back to the Homebrew prefixes otherwise.
#
# The two tarballs stay under vendor/mtp/src/ — they are the LGPL "corresponding
# source" the CI attaches to every release next to the DMGs.
#
#   Tools/build-mtp-libs.sh            # build if missing
#   Tools/build-mtp-libs.sh --force    # rebuild from scratch
set -euo pipefail

DEPLOYMENT_TARGET="13.0"   # keep in sync with Package.swift `.macOS(.v13)` / Info.plist

LIBUSB_VERSION="1.0.30"
LIBUSB_FILE="libusb-${LIBUSB_VERSION}.tar.bz2"
LIBUSB_URL="https://github.com/libusb/libusb/releases/download/v${LIBUSB_VERSION}/${LIBUSB_FILE}"
LIBUSB_SHA256="fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"

LIBMTP_VERSION="1.1.23"
LIBMTP_FILE="libmtp-${LIBMTP_VERSION}.tar.gz"
LIBMTP_URL="https://downloads.sourceforge.net/project/libmtp/libmtp/${LIBMTP_VERSION}/${LIBMTP_FILE}"
LIBMTP_SHA256="74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/mtp"
SRC="$DEST/src"
MTP_LIB="$DEST/lib/libmtp.9.dylib"
USB_LIB="$DEST/lib/libusb-1.0.0.dylib"

if [ -f "$MTP_LIB" ] && [ -f "$USB_LIB" ] && [ "${1:-}" != "--force" ]; then
    echo "libmtp + libusb already built: $DEST/lib"
    echo "    $(otool -l "$MTP_LIB" | grep -A3 -m1 LC_BUILD_VERSION | grep minos | tr -s ' ')"
    exit 0
fi

fetch() { # url file sha256
    local url="$1" file="$SRC/$2" sha="$3"
    if [ ! -f "$file" ]; then
        echo "==> Downloading $url"
        curl -fL --retry 3 --progress-bar -o "$file.tmp" "$url"
        mv "$file.tmp" "$file"
    fi
    local actual
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    if [ "$actual" != "$sha" ]; then
        echo "!! checksum mismatch for $file" >&2
        echo "   expected $sha" >&2
        echo "   actual   $actual" >&2
        exit 1
    fi
}

mkdir -p "$SRC"
fetch "$LIBUSB_URL" "$LIBUSB_FILE" "$LIBUSB_SHA256"
fetch "$LIBMTP_URL" "$LIBMTP_FILE" "$LIBMTP_SHA256"

# Wipe previous build products but keep the verified tarballs.
find "$DEST" -mindepth 1 -maxdepth 1 ! -name src -exec rm -rf {} +

HOST_ARCH="$(uname -m)"
# A bare clang has no sysroot ("ld: library 'System' not found"); give it the
# SDK explicitly, the way xcrun would for an interactive shell.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export CC="$(xcrun -f clang)"
export CFLAGS="-arch $HOST_ARCH -isysroot $SDKROOT -mmacosx-version-min=$DEPLOYMENT_TARGET -O2"
export LDFLAGS="-arch $HOST_ARCH -isysroot $SDKROOT -mmacosx-version-min=$DEPLOYMENT_TARGET"

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "==> Building libusb $LIBUSB_VERSION (arch $HOST_ARCH, macOS >= $DEPLOYMENT_TARGET)"
tar -xjf "$SRC/$LIBUSB_FILE" -C "$BUILD"
(
    cd "$BUILD/libusb-$LIBUSB_VERSION"
    # configure's AC_CHECK_FUNCS is a bare link test against the SDK's .tbd
    # stubs, so any libSystem call the SDK is newer than the deployment target
    # for "exists", gets weak-imported, and resolves to NULL on a macOS that
    # lacks it. The macOS 27 SDK added pipe2(): libusb then called it from
    # usbi_create_event() and every libusb_init() -- i.e. opening Connect to
    # Server (⌘K), which scans for Android devices -- crashed at address 0 on
    # macOS 26 and older (2026-09-16). Force the pipe()+fcntl() fallback,
    # which is what libusb uses on every other macOS anyway.
    export ac_cv_func_pipe2=no
    ./configure --prefix="$DEST" --disable-static --disable-dependency-tracking \
        --disable-silent-rules >configure.log 2>&1 || { cat configure.log; exit 1; }
    make -j"$(sysctl -n hw.ncpu)" >make.log 2>&1 || { tail -50 make.log; exit 1; }
    make install >install.log 2>&1 || { tail -30 install.log; exit 1; }
    cp COPYING "$DEST/libusb-COPYING.txt"
)

echo "==> Building libmtp $LIBMTP_VERSION (arch $HOST_ARCH, macOS >= $DEPLOYMENT_TARGET)"
tar -xzf "$SRC/$LIBMTP_FILE" -C "$BUILD"
(
    cd "$BUILD/libmtp-$LIBMTP_VERSION"
    # Point configure at the libusb just built without needing pkg-config
    # (PKG_CHECK_MODULES honours these and skips the pkg-config probe).
    export PKG_CONFIG_PATH="$DEST/lib/pkgconfig"
    export LIBUSB_CFLAGS="-I$DEST/include/libusb-1.0"
    export LIBUSB_LIBS="-L$DEST/lib -lusb-1.0"
    # --disable-mtpz: Zune DRM support would pull in libgcrypt (Homebrew's
    # formula builds without it too). No udev on macOS.
    ./configure --prefix="$DEST" --disable-static --disable-dependency-tracking \
        --disable-silent-rules --disable-mtpz --with-udev=no \
        >configure.log 2>&1 || { cat configure.log; exit 1; }
    make -j"$(sysctl -n hw.ncpu)" >make.log 2>&1 || { tail -50 make.log; exit 1; }
    make install >install.log 2>&1 || { tail -30 install.log; exit 1; }
    cp COPYING "$DEST/libmtp-COPYING.txt"
)

# The .la files and the unversioned symlinks are libtool noise the app never uses.
rm -f "$DEST"/lib/*.la
rm -rf "$DEST/share" "$DEST/bin"

printf 'libmtp %s\nlibusb %s\ndeployment-target %s\narch %s\n' \
    "$LIBMTP_VERSION" "$LIBUSB_VERSION" "$DEPLOYMENT_TARGET" "$HOST_ARCH" > "$DEST/VERSION"

echo "==> Verifying deployment target"
for lib in "$MTP_LIB" "$USB_LIB"; do
    minos="$(otool -l "$lib" | grep -A3 -m1 LC_BUILD_VERSION | awk '/minos/{print $2}')"
    echo "    $(basename "$lib"): archs $(lipo -archs "$lib"), minos $minos"
    if [ "$minos" != "$DEPLOYMENT_TARGET" ]; then
        echo "!! $(basename "$lib") was built for macOS $minos, expected $DEPLOYMENT_TARGET" >&2
        exit 1
    fi
    # A weak import means configure found a libSystem call the SDK has but the
    # deployment target does not guarantee; on an older macOS it binds to NULL
    # and the first call crashes (pipe2 on the macOS 27 SDK, see above).
    weak="$(nm -mu "$lib" | grep 'weak external' || true)"
    if [ -n "$weak" ]; then
        echo "!! $(basename "$lib") weak-imports symbols missing on macOS $DEPLOYMENT_TARGET:" >&2
        echo "$weak" >&2
        exit 1
    fi
done
echo "    $DEST"
