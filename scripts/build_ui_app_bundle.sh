#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT_DIR="$ROOT_DIR/ImmiBridge"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
DESTINATION="${DESTINATION:-generic/platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.xcodebuild}"
OUTPUT_APP_DIR="${OUTPUT_APP_DIR:-$ROOT_DIR/build/ImmiBridge.app}"

if [[ "$OUTPUT_APP_DIR" = /* ]]; then
    APP_DIR="$OUTPUT_APP_DIR"
else
    APP_DIR="$ROOT_DIR/$OUTPUT_APP_DIR"
fi

echo "Building ImmiBridge..."
echo "Destination: $DESTINATION"
echo "Derived data: $DERIVED_DATA_PATH"
echo "Output: $APP_DIR"

# Build with xcodebuild
xcodebuild -project "$PROJECT_DIR/ImmiBridge.xcodeproj" \
    -scheme ImmiBridge \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "$DESTINATION" \
    build

# Copy the built app to the build directory
rm -rf "$APP_DIR"
mkdir -p "$(dirname "$APP_DIR")"
cp -R "$DERIVED_DATA_PATH/Build/Products/Release/ImmiBridge.app" "$APP_DIR"

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
