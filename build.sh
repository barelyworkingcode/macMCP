#!/bin/bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"

echo "Building macMCP..."
xcrun swift build -c release

BIN=".build/release/macmcp"

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep -o '"[^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    codesign --force --sign "$IDENTITY" --options runtime "$BIN"
else
    echo "No Developer ID found, ad-hoc signing"
    codesign --force --sign - "$BIN"
fi

# Install to ~/.local/bin
mkdir -p "$INSTALL_DIR"
cp "$BIN" "$INSTALL_DIR/macmcp"
echo "Installed: $INSTALL_DIR/macmcp"

# Register with Relay (best-effort, relay may not be installed)
RELAY="/Applications/Relay.app/Contents/MacOS/relay"
if [ -x "$RELAY" ]; then
    "$RELAY" mcp register --name macMCP --command "$INSTALL_DIR/macmcp"
else
    echo "Relay not found at $RELAY, skipping registration"
fi
