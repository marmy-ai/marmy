#!/bin/bash
# Builds Marmy Desktop.app from the Swift package.
#
#   ./Scripts/build-app.sh [release|debug]
#
# Output: build/Marmy Desktop.app  (the build/ directory is git-ignored)
#
# The bundle is ad-hoc signed by default, which is enough to run it locally.
# macOS ties microphone and speech-recognition permission to the signing
# identity, so an ad-hoc rebuild asks again; set MARMY_SIGN_IDENTITY to a stable
# Developer ID or Apple Development identity to keep those grants:
#
#   MARMY_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./Scripts/build-app.sh
set -euo pipefail

CONFIG="${1:-release}"
PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Marmy Desktop"
BUILD_DIR="$PKG_DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"

cd "$PKG_DIR"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

for tool in MarmyDesktop marmy-agent-launch; do
  if [[ ! -x "$BIN_PATH/$tool" ]]; then
    echo "error: $tool was not built at $BIN_PATH" >&2
    exit 1
  fi
done

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_PATH/MarmyDesktop" "$CONTENTS/MacOS/MarmyDesktop"
# The launch trampoline lives beside the app binary: tmux starts it, it reads a
# launch spec and becomes the agent CLI.
cp "$BIN_PATH/marmy-agent-launch" "$CONTENTS/MacOS/marmy-agent-launch"

# SwiftTerm ships a Metal shader bundle; the terminal needs it at runtime.
shopt -s nullglob
for bundle in "$BIN_PATH"/*.bundle; do
  cp -R "$bundle" "$CONTENTS/Resources/"
done
shopt -u nullglob

# Third-party licence.
if [[ -f "$PKG_DIR/.build/checkouts/SwiftTerm/LICENSE" ]]; then
  cp "$PKG_DIR/.build/checkouts/SwiftTerm/LICENSE" "$CONTENTS/Resources/SwiftTerm-LICENSE.txt"
fi

# App icon, reused read-only from the existing menu-bar app's assets.
ICON_SRC="$PKG_DIR/../MarmyMenuBar/MarmyMenuBar/Assets.xcassets/AppIcon.appiconset"
if [[ -d "$ICON_SRC" ]] && command -v iconutil >/dev/null 2>&1; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    src="$ICON_SRC/icon_${size}x${size}.png"
    [[ -f "$src" ]] || continue
    cp "$src" "$ICONSET/icon_${size}x${size}.png"
    double=$((size * 2))
    if [[ -f "$ICON_SRC/icon_${double}x${double}.png" ]]; then
      cp "$ICON_SRC/icon_${double}x${double}.png" "$ICONSET/icon_${size}x${size}@2x.png"
    fi
  done
  iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns" 2>/dev/null || \
    echo "note: could not build AppIcon.icns; continuing without an icon" >&2
  rm -rf "$(dirname "$ICONSET")"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>MarmyDesktop</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>ai.marmy.desktop</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Marmy Desktop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.4.2</string>
    <key>CFBundleVersion</key><string>6</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Marmy listens while you hold Space so you can dictate a message to the selected agent.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Marmy turns what you say into text and puts it into the selected agent's own prompt, for you to read and send.</string>
</dict>
</plist>
PLIST

# No App Sandbox: Marmy drives your own tmux server and reads the folders your
# agents work in. The microphone entitlement is what dictation needs.
ENTITLEMENTS="$BUILD_DIR/MarmyDesktop.entitlements"
cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT

SIGN_IDENTITY="${MARMY_SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
  "$CONTENTS/MacOS/marmy-agent-launch" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$APP" >/dev/null

echo "built $APP (signed with: $SIGN_IDENTITY)"
echo "open it with:  open \"$APP\""
