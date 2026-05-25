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
# PkgInfo is the legacy 8-byte type/creator file; LaunchServices refuses to
# `open` bundles without it (manifests as Finder/open returning error -600).
printf "APPL????" > "$CONTENTS/PkgInfo"

# Code signing -- mirrors relay's pattern so the cdhash stays stable across
# rebuilds (TCC keys grants off the designated requirement when Developer ID
# signed, vs cdhash when ad-hoc -- the latter re-prompts every build).
# RELAY_SIGN_IDENTITY lets you pin a specific cert when multiple are present.
IDENTITY="${RELAY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep -o '"[^"]*"' | head -1 | tr -d '"' || true)}"
if [ -n "$IDENTITY" ]; then
    echo "Signing with: $IDENTITY"
    SIGN_ARGS=(--force --sign "$IDENTITY" --entitlements macmcp.entitlements --options runtime --timestamp)
else
    echo "No Developer ID found, ad-hoc signing"
    # Ad-hoc can't --timestamp (no cert authority), but runtime + entitlements stay on for parity.
    SIGN_ARGS=(--force --sign - --entitlements macmcp.entitlements --options runtime)
fi
# Sign inner binary first, then the bundle (innermost-first is the codesign rule).
codesign "${SIGN_ARGS[@]}" "$MACOS_DIR/macmcp"
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "Installed: $APP_BUNDLE"

# Symlink the binary so existing PATH-based invocations still work.
ln -sf "macmcp.app/Contents/MacOS/macmcp" "$INSTALL_DIR/macmcp"

# Request TCC permissions interactively. Launching via `open` makes macmcp
# the responsible process for TCC attribution (running the binary directly
# would attribute prompts to whatever shell is the parent, e.g. iTerm).
# Calendars/Contacts/Reminders panes in modern macOS have no manual + button,
# so the prompt must be triggered from macmcp itself or those grants are
# unreachable.
echo ""
echo "Requesting macOS permissions (approve any system dialogs that appear)..."
open "$APP_BUNDLE" --args --request-permissions
# Brief pause to let prompts surface before the script exits.
sleep 2
echo ""

# Register with Relay (best-effort, relay may not be installed)
RELAY="/Applications/Relay.app/Contents/MacOS/relay"
if [ -x "$RELAY" ]; then
    "$RELAY" mcp register --name macMCP --command "$MACOS_DIR/macmcp"
else
    echo "Relay not found at $RELAY, skipping registration"
fi
