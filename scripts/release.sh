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
DMG_UNIVERSAL_PATH="$ROOT_DIR/build/ImmiBridge-${VERSION}.dmg"
DMG_ARM64_PATH="$ROOT_DIR/build/ImmiBridge-${VERSION}-arm64.dmg"
DMG_X86_64_PATH="$ROOT_DIR/build/ImmiBridge-${VERSION}-x86_64.dmg"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$ROOT_DIR/tools/sparkle/bin}"
# Set to "universal" for single universal binary, "separate" for arch-specific DMGs
BUILD_MODE="${BUILD_MODE:-universal}"

sync_version_metadata() {
    local plist_path="$ROOT_DIR/ImmiBridge/ImmiBridge/UI/Info.plist"
    local pbxproj_path="$ROOT_DIR/ImmiBridge/ImmiBridge.xcodeproj/project.pbxproj"

    echo "==> Syncing app version metadata to v${VERSION}..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$plist_path"
    perl -pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${VERSION};/g" "$pbxproj_path"

    if [[ -n "${SPARKLE_FEED_URL:-}" ]]; then
        /usr/libexec/PlistBuddy -c "Set :SUFeedURL ${SPARKLE_FEED_URL}" "$plist_path"
    else
        echo "Warning: SPARKLE_FEED_URL not set; Sparkle updates will be disabled."
    fi

    if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
        /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${SPARKLE_PUBLIC_KEY}" "$plist_path"
    else
        echo "Warning: SPARKLE_PUBLIC_KEY not set; Sparkle updates will be disabled."
    fi
}

generate_appcast() {
    if [[ -z "${SPARKLE_PRIVATE_KEY:-}" || -z "${GITHUB_REPO:-}" ]]; then
        echo "Skipping appcast: SPARKLE_PRIVATE_KEY and GITHUB_REPO are required."
        return
    fi

    if [[ ! -x "$SPARKLE_TOOLS_DIR/generate_appcast" ]]; then
        echo "Skipping appcast: Sparkle tools not found at $SPARKLE_TOOLS_DIR."
        return
    fi

    local assets_dir="$ROOT_DIR/build/appcast-assets"
    rm -rf "$assets_dir"
    mkdir -p "$assets_dir"

    # Use the universal DMG for appcast (Sparkle doesn't support multiple arch-specific DMGs)
    if [[ -f "$DMG_UNIVERSAL_PATH" ]]; then
        cp "$DMG_UNIVERSAL_PATH" "$assets_dir/"
    else
        echo "Warning: Universal DMG not found, using arm64 DMG for appcast"
        cp "$DMG_ARM64_PATH" "$assets_dir/"
    fi

    echo "==> Generating Sparkle appcast..."
    TAG="v${VERSION}" ASSETS_DIR="$assets_dir" SPARKLE_TOOLS_DIR="$SPARKLE_TOOLS_DIR" \
        "$ROOT_DIR/scripts/generate_appcast.sh"
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
    # Use staging dir and unique volume name to avoid permission issues with notarized apps
    local staging_dir="$ROOT_DIR/build/dmg-staging-${arch}"
    rm -rf "$staging_dir"
    mkdir -p "$staging_dir"
    cp -R "$app_dir" "$staging_dir/"
    xattr -cr "$staging_dir"
    hdiutil create -volname "ImmiBridge-${arch}" -srcfolder "$staging_dir" -ov -format UDZO "$dmg_path"
    rm -rf "$staging_dir"

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

build_universal_and_notarize() {
    local app_dir="$ROOT_DIR/build/ImmiBridge.app"
    local zip_path="$ROOT_DIR/build/ImmiBridge-${VERSION}.zip"
    local dmg_path="$DMG_UNIVERSAL_PATH"
    local derived_data_path="$ROOT_DIR/.xcodebuild-universal"

    echo "==> Building ImmiBridge v${VERSION} (universal: arm64 + x86_64)..."
    rm -rf "$derived_data_path"
    export CODESIGN_IDENTITY
    # Build for "Any Mac" which creates a universal binary
    DESTINATION="generic/platform=macOS" \
        DERIVED_DATA_PATH="$derived_data_path" \
        OUTPUT_APP_DIR="$app_dir" \
        ARCHS="arm64 x86_64" \
        "$ROOT_DIR/scripts/build_ui_app_bundle.sh"

    echo ""
    echo "==> Verifying universal binary..."
    local main_binary="$app_dir/Contents/MacOS/ImmiBridge"
    if [[ -f "$main_binary" ]]; then
        lipo -info "$main_binary"
    fi

    echo ""
    echo "==> Verifying code signature (universal)..."
    codesign --verify --deep --strict --verbose=2 "$app_dir"

    echo ""
    echo "==> Creating ZIP for notarization (universal)..."
    rm -f "$zip_path"
    ditto -c -k --keepParent "$app_dir" "$zip_path"

    echo ""
    echo "==> Submitting for notarization (universal)..."
    xcrun notarytool submit "$zip_path" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait

    echo ""
    echo "==> Stapling notarization ticket (universal)..."
    xcrun stapler staple "$app_dir"

    echo ""
    echo "==> Verifying notarization (universal)..."
    spctl --assess --type execute --verbose "$app_dir"

    echo ""
    echo "==> Creating DMG (universal)..."
    rm -f "$dmg_path"
    # Use staging dir and unique volume name to avoid permission issues with notarized apps
    local staging_dir="$ROOT_DIR/build/dmg-staging"
    rm -rf "$staging_dir"
    mkdir -p "$staging_dir"
    cp -R "$app_dir" "$staging_dir/"
    xattr -cr "$staging_dir"
    hdiutil create -volname "ImmiBridge-Install" -srcfolder "$staging_dir" -ov -format UDZO "$dmg_path"
    rm -rf "$staging_dir"

    echo ""
    echo "==> Notarizing DMG (universal)..."
    xcrun notarytool submit "$dmg_path" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait

    xcrun stapler staple "$dmg_path"

    rm -f "$zip_path"
}

sync_version_metadata

if [[ "$BUILD_MODE" == "separate" ]]; then
    # Build separate arch-specific DMGs (legacy mode)
    build_and_notarize "arm64"
    build_and_notarize "x86_64"
    generate_appcast

    echo ""
    echo "================================================"
    echo "Release complete!"
    echo "DMG (arm64): $DMG_ARM64_PATH"
    echo "DMG (x86_64): $DMG_X86_64_PATH"
    echo ""
    echo "Upload to GitHub:"
    echo "  gh release create v${VERSION} '$DMG_ARM64_PATH' '$DMG_X86_64_PATH' --title 'v${VERSION}' --generate-notes"
    echo "================================================"
else
    # Build universal binary (default, recommended for Sparkle)
    build_universal_and_notarize
    generate_appcast

    echo ""
    echo "================================================"
    echo "Release complete!"
    echo "DMG (universal): $DMG_UNIVERSAL_PATH"
    echo ""
    echo "Upload to GitHub:"
    echo "  gh release create v${VERSION} '$DMG_UNIVERSAL_PATH' --title 'v${VERSION}' --generate-notes"
    echo "================================================"
fi
