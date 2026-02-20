#!/bin/bash
set -euo pipefail

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

echo "Built: $BIN"
