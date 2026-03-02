#!/bin/bash
set -euo pipefail

# Build the Rust agent binary and copy it into the app bundle.
# This script is intended to be run as an Xcode "Run Script" build phase.

# Ensure cargo is in PATH (Xcode doesn't source shell profiles)
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# When run from Xcode, SRCROOT is set. Otherwise, derive from script location.
if [ -n "${SRCROOT:-}" ]; then
    REPO_ROOT="$(cd "$SRCROOT/../.." && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
fi

AGENT_DIR="$REPO_ROOT/agent"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    arm64)
        RUST_TARGET="aarch64-apple-darwin"
        ;;
    x86_64)
        RUST_TARGET="x86_64-apple-darwin"
        ;;
    *)
        echo "error: Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

echo "Building marmy-agent for $RUST_TARGET..."
echo "Agent dir: $AGENT_DIR"

# Build the Rust binary
cd "$AGENT_DIR"
cargo build --release --target "$RUST_TARGET"

# Determine the output location
if [ -n "${BUILT_PRODUCTS_DIR:-}" ]; then
    # Running inside Xcode
    DEST_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/MacOS"
else
    # Running standalone — put it in a local build dir
    DEST_DIR="$SCRIPT_DIR/../build/MarmyMenuBar.app/Contents/MacOS"
fi

mkdir -p "$DEST_DIR"
cp "$AGENT_DIR/target/$RUST_TARGET/release/marmy-agent" "$DEST_DIR/marmy-agent"

echo "Copied marmy-agent to $DEST_DIR"
