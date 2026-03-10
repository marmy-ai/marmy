#!/bin/bash
set -euo pipefail

# MacMarmy Build + Sign + Notarize Pipeline
# Usage: ./scripts/build-pkg.sh
#
# Required environment variables for signing/notarization:
#   DEVELOPER_ID_APP    - "Developer ID Application: Name (TEAMID)"
#   DEVELOPER_ID_PKG    - "Developer ID Installer: Name (TEAMID)"
#   APPLE_ID            - Apple ID email for notarytool
#   APPLE_ID_PASSWORD   - App-specific password for notarytool
#   APPLE_TEAM_ID       - Team ID for notarytool

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MACOS_DIR="$PROJECT_ROOT/macos/MarmyMenuBar"
AGENT_DIR="$PROJECT_ROOT/agent"
BUILD_DIR="$PROJECT_ROOT/build"
APP_NAME="MacMarmy"
PKG_VERSION="${PKG_VERSION:-1.0.0}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Pre-flight checks ---
command -v xcodebuild >/dev/null || error "xcodebuild not found"
command -v cargo >/dev/null || error "cargo not found"

SIGN_APP="${DEVELOPER_ID_APP:-}"
SIGN_PKG="${DEVELOPER_ID_PKG:-}"
APPLE_ID="${APPLE_ID:-}"
APPLE_ID_PASSWORD="${APPLE_ID_PASSWORD:-}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"

if [ -z "$SIGN_APP" ]; then
    warn "DEVELOPER_ID_APP not set — will build unsigned"
    UNSIGNED=true
else
    UNSIGNED=false
fi

# --- Clean build dir ---
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Step 1: Build the Xcode project ---
info "Building $APP_NAME.app (Release)..."
xcodebuild \
    -project "$MACOS_DIR/MarmyMenuBar.xcodeproj" \
    -scheme MarmyMenuBar \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/derived" \
    PRODUCT_NAME="$APP_NAME" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    clean build 2>&1 | tail -5

APP_PATH=$(find "$BUILD_DIR/derived" -name "$APP_NAME.app" -type d | head -1)
[ -d "$APP_PATH" ] || error "Failed to find $APP_NAME.app in build output"
info "Built: $APP_PATH"

# --- Step 2: Build agent binary (Apple Silicon) ---
info "Building agent binary (arm64)..."
cd "$AGENT_DIR"

cargo build --release --target aarch64-apple-darwin 2>&1 | tail -3

AGENT_BIN="$AGENT_DIR/target/aarch64-apple-darwin/release/marmy-agent"
[ -f "$AGENT_BIN" ] || error "Agent binary not found at $AGENT_BIN"
info "Agent binary: $(file "$AGENT_BIN")"

# --- Step 3: Replace agent binary in app bundle ---
cp "$AGENT_BIN" "$APP_PATH/Contents/MacOS/marmy-agent"
chmod +x "$APP_PATH/Contents/MacOS/marmy-agent"
info "Agent binary placed in app bundle"

# --- Step 4: Code sign ---
if [ "$UNSIGNED" = false ]; then
    info "Signing $APP_NAME.app with: $SIGN_APP"

    # Sign the agent binary first
    codesign --force --options runtime \
        --sign "$SIGN_APP" \
        "$APP_PATH/Contents/MacOS/marmy-agent"

    # Sign the whole app
    codesign --deep --force --options runtime \
        --sign "$SIGN_APP" \
        --entitlements "$MACOS_DIR/MarmyMenuBar/MacMarmy.entitlements" \
        "$APP_PATH"

    codesign --verify --deep --strict "$APP_PATH"
    info "Code signing verified"
else
    # Ad-hoc sign for local testing
    codesign --deep --force --sign - "$APP_PATH"
    warn "Ad-hoc signed (not suitable for distribution)"
fi

# --- Step 5: Build .pkg ---
STAGE_DIR="$BUILD_DIR/pkg-stage"
mkdir -p "$STAGE_DIR/Applications"
cp -R "$APP_PATH" "$STAGE_DIR/Applications/"

PKG_UNSIGNED="$BUILD_DIR/$APP_NAME-$PKG_VERSION-unsigned.pkg"
PKG_SIGNED="$BUILD_DIR/$APP_NAME-$PKG_VERSION.pkg"

info "Building .pkg..."

# Generate component plist and disable bundle relocation
COMPONENT_PLIST="$BUILD_DIR/component.plist"
pkgbuild --analyze --root "$STAGE_DIR" "$COMPONENT_PLIST"
# Disable relocation so the app always installs to /Applications
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"

pkgbuild \
    --root "$STAGE_DIR" \
    --component-plist "$COMPONENT_PLIST" \
    --identifier "com.marmy.macmarmy" \
    --version "$PKG_VERSION" \
    --install-location "/" \
    --scripts "$SCRIPT_DIR/pkg-scripts" \
    "$PKG_UNSIGNED"

# --- Step 6: Sign .pkg ---
if [ "$UNSIGNED" = false ] && [ -n "$SIGN_PKG" ]; then
    info "Signing .pkg with: $SIGN_PKG"
    productsign --sign "$SIGN_PKG" "$PKG_UNSIGNED" "$PKG_SIGNED"
    rm "$PKG_UNSIGNED"
else
    mv "$PKG_UNSIGNED" "$PKG_SIGNED"
    warn "Package not signed"
fi

info "Package: $PKG_SIGNED"

# --- Step 7: Notarize ---
if [ "$UNSIGNED" = false ] && [ -n "$APPLE_ID" ] && [ -n "$APPLE_ID_PASSWORD" ]; then
    info "Submitting for notarization..."
    xcrun notarytool submit "$PKG_SIGNED" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_ID_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait

    info "Stapling notarization ticket..."
    xcrun stapler staple "$PKG_SIGNED"

    info "Notarization complete!"
else
    if [ "$UNSIGNED" = false ]; then
        warn "APPLE_ID / APPLE_ID_PASSWORD not set — skipping notarization"
    fi
fi

echo ""
info "Build complete: $PKG_SIGNED"
info "Size: $(du -h "$PKG_SIGNED" | cut -f1)"
