#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT_DIR="$ROOT_DIR/ImmiBridge"
APP_DIR="$ROOT_DIR/build/ImmiBridge.app"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

echo "Building ImmiBridge..."

# Build with xcodebuild
xcodebuild -project "$PROJECT_DIR/ImmiBridge.xcodeproj" \
    -scheme ImmiBridge \
    -configuration Release \
    -derivedDataPath "$ROOT_DIR/.xcodebuild" \
    build

# Copy the built app to the build directory
rm -rf "$APP_DIR"
mkdir -p "$ROOT_DIR/build"
cp -R "$ROOT_DIR/.xcodebuild/Build/Products/Release/ImmiBridge.app" "$APP_DIR"

# Re-sign if a custom identity is provided (for notarization)
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    echo "Re-signing with identity: $CODESIGN_IDENTITY"
    codesign --force --deep --options runtime \
        --entitlements "$PROJECT_DIR/ImmiBridge/ImmiBridge.entitlements" \
        --sign "$CODESIGN_IDENTITY" "$APP_DIR"
fi

echo ""
echo "Built: $APP_DIR"
echo ""
echo "To install, copy to /Applications:"
echo "  cp -r '$APP_DIR' /Applications/"
