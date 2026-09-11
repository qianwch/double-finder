#!/bin/bash
# Packs the plugin SDK: the PluginKit package, the plugin template + scaffolder,
# the development guide and the sample plugin (source only).
# Produces ./.dist/DoubleFinderPluginKit-SDK-<version>.zip
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${DF_VERSION:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git describe --tags --abbrev=0 --match '[0-9]*' --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')"
    [ -z "$VERSION" ] && VERSION="0.0.0"
fi
API="$(grep -E 'public static let apiVersion' PluginKit/Sources/DoubleFinderPluginKit/PluginKit.swift | grep -oE '[0-9]+')"

DIST=".dist"
NAME="DoubleFinderPluginKit-SDK-$VERSION"
STAGE="$DIST/$NAME"
rm -rf "$STAGE" "$DIST/$NAME.zip"
mkdir -p "$STAGE/Examples" "$STAGE/docs" "$STAGE/Tools"

rsync -a --exclude '.build' --exclude '.swiftpm' --exclude 'Package.resolved' PluginKit "$STAGE/"
rsync -a Templates "$STAGE/"
cp Tools/new-plugin.sh "$STAGE/Tools/"
cp docs/plugin-development.md docs/plugin-development.zh-Hans.md "$STAGE/docs/"
rsync -a --exclude '.build' --exclude '.dist' --exclude '.swiftpm' --exclude 'Package.resolved' Examples/SamplePlugin "$STAGE/Examples/"
cp LICENSE "$STAGE/LICENSE"
cat > "$STAGE/README.md" <<EOF2
# Double Finder Plugin SDK $VERSION (plugin API $API)

- PluginKit/                 the DoubleFinderPluginKit package (depend on it by path)
- Templates/PluginTemplate/  a minimal plugin package
- Tools/new-plugin.sh        scaffold a plugin:  Tools/new-plugin.sh MyPlugin com.example.myplugin ~/Developer
- docs/                      plugin development guide (English + 简体中文)
- Examples/SamplePlugin/     reference plugin implementing every extension point

Requires macOS 13+ and Xcode 15+ (Swift 5.9). Plugins must declare
DFPluginAPIVersion = $API in their Info.plist. Apache-2.0, see LICENSE.
EOF2

(cd "$DIST" && rm -f "$NAME.zip" && zip -qr "$NAME.zip" "$NAME")
rm -rf "$STAGE"
echo "==> $DIST/$NAME.zip ($(du -h "$DIST/$NAME.zip" | cut -f1))"
