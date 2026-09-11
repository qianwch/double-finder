#!/bin/bash
# Scaffolds a Double Finder plugin package from Templates/PluginTemplate.
#
#   Tools/new-plugin.sh <Name> <bundle.id> [destination-dir]
#
# <Name> is the Swift module / principal class / bundle name (letters, digits,
# underscore; must start with a letter). The package lands in
# <destination-dir>/<Name> (default: the current directory) with Package.swift
# pointing at this SDK's PluginKit by relative path.
set -euo pipefail

NAME="${1:-}"; BUNDLE_ID="${2:-}"; DEST_DIR="${3:-.}"
if [ -z "$NAME" ] || [ -z "$BUNDLE_ID" ]; then
    echo "usage: $0 <Name> <bundle.id> [destination-dir]" >&2; exit 2
fi
if ! [[ "$NAME" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]]; then
    echo "error: <Name> must be an identifier (letters, digits, underscore)" >&2; exit 2
fi

SDK="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$SDK/Templates/PluginTemplate"
PLUGINKIT="$SDK/PluginKit"
[ -d "$TEMPLATE" ] || { echo "error: template not found at $TEMPLATE" >&2; exit 1; }
[ -f "$PLUGINKIT/Package.swift" ] || { echo "error: PluginKit not found at $PLUGINKIT" >&2; exit 1; }

mkdir -p "$DEST_DIR"
DEST="$(cd "$DEST_DIR" && pwd)/$NAME"
[ -e "$DEST" ] && { echo "error: $DEST already exists" >&2; exit 1; }

cp -R "$TEMPLATE" "$DEST"
mv "$DEST/Sources/__NAME__" "$DEST/Sources/$NAME"
mv "$DEST/Sources/$NAME/__NAME__.swift" "$DEST/Sources/$NAME/$NAME.swift"

REL="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$PLUGINKIT" "$DEST")"
# (python, not sed -i: BSD sed's in-place flag differs between macOS versions)
python3 - "$DEST" "$NAME" "$BUNDLE_ID" "$REL" <<'PY'
import sys, pathlib
dest, name, bundle_id, rel = sys.argv[1:5]
for f in ["Package.swift", "Info.plist", "build.sh", "README.md", f"Sources/{name}/{name}.swift"]:
    p = pathlib.Path(dest) / f
    p.write_text(p.read_text().replace("__PLUGINKIT_PATH__", rel).replace("__BUNDLE_ID__", bundle_id).replace("__NAME__", name))
PY
chmod +x "$DEST/build.sh"

echo "created $DEST"
echo "  PluginKit: $REL"
echo "next:  cd \"$DEST\" && ./build.sh --install"
