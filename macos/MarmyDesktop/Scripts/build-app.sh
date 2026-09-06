#!/bin/bash
# Builds MarmyDesktop.app from the Swift package.
#
#   ./Scripts/build-app.sh [debug|release]
#
# Output: dist/MarmyDesktop.app
#
# The bundle is ad-hoc signed by default, which is enough to launch it. Set
# MARMY_SIGN_IDENTITY to a real Developer ID / Apple Development identity before
# the phases that ask for microphone and speech permission: TCC grants are tied
# to the signing identity and are dropped on every ad-hoc rebuild.
set -euo pipefail

CONFIG="${1:-release}"
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MarmyDesktop"
DIST="$PKG_DIR/dist"
APP="$DIST/$APP_NAME.app"

cd "$PKG_DIR"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>ai.marmy.desktop</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Marmy Desktop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${MARMY_SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" >/dev/null
echo "built $APP (signed with: $SIGN_IDENTITY)"
