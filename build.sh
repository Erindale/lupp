#!/usr/bin/env bash
# Builds Lupp.app. Needs the Command Line Tools only — no Xcode.
set -euo pipefail

VERSION="0.1.0"
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Lupp.app"

echo "→ compiling"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/Lupp"

echo "→ assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lupp"

LUPP_VERSION="$VERSION" swift "$ROOT/Tools/mkplist.swift" "$APP/Contents/Info.plist"

echo "→ icon"
ICONSET="$(mktemp -d)/Lupp.iconset"
swift "$ROOT/Tools/makeicon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Lupp.icns"
rm -rf "$(dirname "$ICONSET")"

# Ad-hoc signature. Enough for this machine; anyone else downloading a built
# copy still meets Gatekeeper, which is why the README says build from source.
codesign --force --sign - "$APP" 2>/dev/null

LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$APP" || true

echo "✓ $APP"
echo "  open it, or drag it to /Applications and use Lupp ▸ Make Lupp the Default Image Viewer…"
