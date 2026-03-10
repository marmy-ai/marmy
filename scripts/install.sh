#!/bin/bash
set -euo pipefail

# MacMarmy Installer
# Usage: curl -fsSL https://marmy.ai/install.sh | bash
#
# This script will:
#   1. Install Homebrew (if not already installed)
#   2. Install tmux via Homebrew (if not already installed)
#   3. Download and install MacMarmy.pkg from GitHub Releases
#   4. Open MacMarmy

APP_NAME="MacMarmy"
REPO="mharajli/marmy"
PKG_NAME="MacMarmy.pkg"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}==>${NC} $1"; }
warn()  { echo -e "${YELLOW}==>${NC} $1"; }
error() { echo -e "${RED}==>${NC} $1"; exit 1; }

echo ""
echo -e "${BOLD}MacMarmy Installer${NC}"
echo "This will install Homebrew (if needed), tmux, and MacMarmy."
echo ""

# --- Check platform ---
[ "$(uname -s)" = "Darwin" ] || error "MacMarmy only runs on macOS"

# --- Detect architecture ---
ARCH=$(uname -m)
case "$ARCH" in
    arm64|aarch64) info "Detected Apple Silicon (arm64)" ;;
    x86_64)        info "Detected Intel (x86_64)" ;;
    *)             error "Unsupported architecture: $ARCH" ;;
esac

# --- Homebrew ---
if command -v brew >/dev/null 2>&1; then
    info "Homebrew found"
else
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add brew to PATH for this session
    if [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -f /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi

    command -v brew >/dev/null 2>&1 || error "Homebrew installation failed"
    info "Homebrew installed"
fi

# --- tmux ---
if command -v tmux >/dev/null 2>&1; then
    info "tmux found ($(tmux -V))"
else
    info "Installing tmux via Homebrew..."
    brew install tmux
    command -v tmux >/dev/null 2>&1 || error "tmux installation failed"
    info "tmux installed ($(tmux -V))"
fi

# --- Get latest release URL ---
info "Fetching latest release..."
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep "browser_download_url.*$PKG_NAME" \
    | head -1 \
    | cut -d '"' -f 4)

[ -n "$DOWNLOAD_URL" ] || error "Could not find $PKG_NAME in latest release"
info "Downloading $APP_NAME..."

# --- Download ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PKG_PATH="$TMPDIR/$PKG_NAME"
curl -fSL --progress-bar "$DOWNLOAD_URL" -o "$PKG_PATH"
info "Downloaded $(du -h "$PKG_PATH" | cut -f1)"

# --- Install ---
info "Installing $APP_NAME (requires sudo)..."
sudo installer -pkg "$PKG_PATH" -target /

# --- Verify ---
if [ -d "/Applications/$APP_NAME.app" ]; then
    echo ""
    info "$APP_NAME installed successfully!"
    info "Opening $APP_NAME..."
    open "/Applications/$APP_NAME.app"
else
    error "Installation failed — $APP_NAME.app not found in /Applications"
fi
