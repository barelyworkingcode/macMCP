#!/bin/bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/bin"
APP_BUNDLE="$INSTALL_DIR/macmcp.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"

echo "Building macMCP..."
xcrun swift build -c release

BIN=".build/release/macmcp"

# Create .app bundle structure. LSUIElement=true keeps it out of Dock,
# Launchpad, and Cmd+Tab. The bundle exists solely so macOS TCC can
# show permission prompts (Location Services, etc.).
mkdir -p "$MACOS_DIR"
cp "$BIN" "$MACOS_DIR/macmcp"
cp Sources/macMCP/Info.plist "$CONTENTS/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep -o '"[^"]*"' | head -1 | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    codesign --force --sign "$IDENTITY" --options runtime "$APP_BUNDLE"
else
    echo "No Developer ID found, ad-hoc signing"
    codesign --force --sign - "$APP_BUNDLE"
fi

echo "Installed: $APP_BUNDLE"

# Symlink the binary so existing PATH-based invocations still work.
ln -sf "macmcp.app/Contents/MacOS/macmcp" "$INSTALL_DIR/macmcp"

# Request TCC permissions interactively. macOS only shows permission prompts
# when the process runs from an interactive terminal — not when spawned as a
# stdio subprocess. Running this here means the user grants permissions once
# during install, and they work through Relay going forward.
echo ""
echo "Requesting macOS permissions (approve any system dialogs that appear)..."
"$MACOS_DIR/macmcp" --request-permissions
echo ""

# Register with Relay (best-effort, relay may not be installed)
RELAY="/Applications/Relay.app/Contents/MacOS/relay"
if [ -x "$RELAY" ]; then
    "$RELAY" mcp register --name macMCP --command "$MACOS_DIR/macmcp"
else
    echo "Relay not found at $RELAY, skipping registration"
fi
