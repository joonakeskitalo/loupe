#!/bin/bash
# Builds Loupe and packages it as a proper macOS .app bundle.
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="Loupe"
BUNDLE="$APP_NAME.app"
BUILD_DIR=".build/$CONFIG"

echo "==> Building ($CONFIG)..."
swift build -c "$CONFIG"

echo "==> Assembling $BUNDLE..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

echo "==> Code signing (ad-hoc) with entitlements..."
codesign --force --deep \
    --sign - \
    --entitlements "Resources/Loupe.entitlements" \
    "$BUNDLE"

echo "==> Done: $(pwd)/$BUNDLE"
echo "    Run with: open $BUNDLE"
