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

VERSION="${VERSION:-0.1.0}"
DMG_ARM64_PATH="$ROOT_DIR/build/ImmiBridge-${VERSION}-arm64.dmg"
DMG_X86_64_PATH="$ROOT_DIR/build/ImmiBridge-${VERSION}-x86_64.dmg"

sync_version_metadata() {
    local plist_path="$ROOT_DIR/ImmiBridge/ImmiBridge/UI/Info.plist"
    local pbxproj_path="$ROOT_DIR/ImmiBridge/ImmiBridge.xcodeproj/project.pbxproj"

    echo "==> Syncing app version metadata to v${VERSION}..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$plist_path"
    perl -pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${VERSION};/g" "$pbxproj_path"
}

build_and_notarize() {
    local arch="$1"
    local app_dir="$ROOT_DIR/build/ImmiBridge-${arch}.app"
    local zip_path="$ROOT_DIR/build/ImmiBridge-${VERSION}-${arch}.zip"
    local dmg_path="$ROOT_DIR/build/ImmiBridge-${VERSION}-${arch}.dmg"
    local derived_data_path="$ROOT_DIR/.xcodebuild-${arch}"

    echo "==> Building ImmiBridge v${VERSION} (${arch})..."
    rm -rf "$derived_data_path"
    export CODESIGN_IDENTITY
    DESTINATION="platform=macOS,arch=${arch}" \
        DERIVED_DATA_PATH="$derived_data_path" \
        OUTPUT_APP_DIR="$app_dir" \
        "$ROOT_DIR/scripts/build_ui_app_bundle.sh"

    echo ""
    echo "==> Verifying code signature (${arch})..."
    codesign --verify --deep --strict --verbose=2 "$app_dir"

    echo ""
    echo "==> Creating ZIP for notarization (${arch})..."
    rm -f "$zip_path"
    ditto -c -k --keepParent "$app_dir" "$zip_path"

    echo ""
    echo "==> Submitting for notarization (${arch})..."
    xcrun notarytool submit "$zip_path" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait

    echo ""
    echo "==> Stapling notarization ticket (${arch})..."
    xcrun stapler staple "$app_dir"

    echo ""
    echo "==> Verifying notarization (${arch})..."
    spctl --assess --type execute --verbose "$app_dir"

    echo ""
    echo "==> Creating DMG (${arch})..."
    rm -f "$dmg_path"
    hdiutil create -volname "ImmiBridge (${arch})" -srcfolder "$app_dir" -ov -format UDZO "$dmg_path"

    echo ""
    echo "==> Notarizing DMG (${arch})..."
    xcrun notarytool submit "$dmg_path" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait

    xcrun stapler staple "$dmg_path"

    rm -f "$zip_path"
}

sync_version_metadata
build_and_notarize "arm64"
build_and_notarize "x86_64"

echo ""
echo "================================================"
echo "Release complete!"
echo "DMG (arm64): $DMG_ARM64_PATH"
echo "DMG (x86_64): $DMG_X86_64_PATH"
echo ""
echo "Upload to GitHub:"
echo "  gh release create v${VERSION} '$DMG_ARM64_PATH' '$DMG_X86_64_PATH' --title 'v${VERSION}' --generate-notes"
echo "================================================"
