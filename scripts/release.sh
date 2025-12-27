#!/usr/bin/env bash
set -euo pipefail

# Release script for ImmiBridge
# Creates a notarized DMG for GitHub distribution
#
# Usage:
#   ./scripts/release.sh
#
# The script automatically loads configuration from .env if present.
# See .env.example for required variables.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Load .env file if it exists
if [[ -f "$ROOT_DIR/.env" ]]; then
    echo "Loading configuration from .env..."
    set -a
    source "$ROOT_DIR/.env"
    set +a
fi

# Check required environment variables
: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to your Developer ID Application certificate}"
: "${APPLE_ID:?Set APPLE_ID to your Apple ID email}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to your Apple Developer Team ID}"
: "${APPLE_APP_PASSWORD:?Set APPLE_APP_PASSWORD to an app-specific password}"

APP_DIR="$ROOT_DIR/build/ImmiBridge.app"
VERSION="${VERSION:-0.1.0}"
DMG_NAME="ImmiBridge-${VERSION}.dmg"
DMG_PATH="$ROOT_DIR/build/$DMG_NAME"
ZIP_PATH="$ROOT_DIR/build/ImmiBridge.zip"

echo "==> Building ImmiBridge v${VERSION}..."
export CODESIGN_IDENTITY
"$ROOT_DIR/scripts/build_ui_app_bundle.sh"

echo ""
echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo ""
echo "==> Creating ZIP for notarization..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo ""
echo "==> Submitting for notarization (this may take a few minutes)..."
xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

echo ""
echo "==> Stapling notarization ticket..."
xcrun stapler staple "$APP_DIR"

echo ""
echo "==> Verifying notarization..."
spctl --assess --type execute --verbose "$APP_DIR"

echo ""
echo "==> Creating DMG..."
rm -f "$DMG_PATH"
hdiutil create -volname "ImmiBridge" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"

echo ""
echo "==> Notarizing DMG..."
xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

xcrun stapler staple "$DMG_PATH"

# Cleanup
rm -f "$ZIP_PATH"

echo ""
echo "================================================"
echo "Release complete!"
echo "DMG: $DMG_PATH"
echo ""
echo "Upload to GitHub:"
echo "  gh release create v${VERSION} '$DMG_PATH' --title 'v${VERSION}' --generate-notes"
echo "================================================"
