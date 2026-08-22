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
APPCAST_PATH="${APPCAST_PATH:-$ROOT_DIR/docs/appcast.xml}"
PLIST_PATH="$ROOT_DIR/ImmiBridge/ImmiBridge/UI/Info.plist"

# Sparkle compares CFBundleVersion -- NOT the marketing version -- to decide whether an
# update exists. Ship 1.1.0 with the same CFBundleVersion as 1.0.11 and the release
# builds, signs, notarizes and uploads perfectly, and no existing user is ever offered
# it. Nothing errors. So derive it here rather than trusting anyone to remember.
#
# Override with BUILD_NUMBER=n for a re-release of the same build.
resolve_build_number() {
    if [[ -n "${BUILD_NUMBER:-}" ]]; then
        echo "$BUILD_NUMBER"
        return
    fi

    local current last
    current="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST_PATH" 2>/dev/null || echo 0)"
    [[ "$current" =~ ^[0-9]+$ ]] || current=0

    last=0
    if [[ -f "$APPCAST_PATH" ]]; then
        last="$(grep -oE '<sparkle:version>[0-9]+' "$APPCAST_PATH" \
                | grep -oE '[0-9]+' | sort -n | tail -1)"
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
    fi

    # Respect a deliberate manual bump; otherwise take the next one past the last
    # published release.
    if (( current > last )); then
        echo "$current"
    else
        echo $(( last + 1 ))
    fi
}

preflight() {
    echo "==> Preflight..."

    # An "Apple Development" cert builds and runs locally but fails notarization, and
    # Sparkle refuses an update whose signing identity does not match the installed app.
    if [[ "$CODESIGN_IDENTITY" != *"Developer ID Application"* ]]; then
        echo "ERROR: CODESIGN_IDENTITY is '${CODESIGN_IDENTITY}'."
        echo "       Releases must use a 'Developer ID Application' certificate."
        exit 1
    fi

    if [[ -f "$APPCAST_PATH" ]] && grep -q "<sparkle:shortVersionString>${VERSION}<" "$APPCAST_PATH"; then
        echo "WARNING: ${VERSION} is already present in $APPCAST_PATH."
        echo "         Continuing will replace that entry. Set BUILD_NUMBER explicitly if"
        echo "         you mean to re-release."
    fi

    echo "    version:      ${VERSION}"
    echo "    build number: ${BUILD_NUMBER_RESOLVED}  (Sparkle compares this)"
    echo "    identity:     ${CODESIGN_IDENTITY}"
}

# Create DMG from an app bundle using mount/copy approach
# This works around "Operation not permitted" errors with notarized apps
create_dmg() {
    local app_path="$1"
    local dmg_path="$2"
    local volume_name="$3"
    local temp_dmg="${dmg_path%.dmg}-temp.dmg"
    local mount_point="/tmp/immibridge-dmg-$$"

    rm -f "$dmg_path" "$temp_dmg"

    # Create empty writable DMG (150MB should be plenty)
    hdiutil create -size 150m -fs HFS+ -volname "$volume_name" "$temp_dmg"

    # Mount it
    mkdir -p "$mount_point"
    hdiutil attach "$temp_dmg" -mountpoint "$mount_point"

    # Copy app using ditto (preserves everything properly)
    ditto "$app_path" "$mount_point/$(basename "$app_path")"

    # Unmount
    hdiutil detach "$mount_point"
    rmdir "$mount_point" 2>/dev/null || true

    # Convert to compressed read-only DMG
    hdiutil convert "$temp_dmg" -format UDZO -o "$dmg_path"

    # Clean up temp DMG
    rm -f "$temp_dmg"
}

sync_version_metadata() {
    local plist_path="$ROOT_DIR/ImmiBridge/ImmiBridge/UI/Info.plist"
    local pbxproj_path="$ROOT_DIR/ImmiBridge/ImmiBridge.xcodeproj/project.pbxproj"

    echo "==> Syncing app version metadata to v${VERSION} (build ${BUILD_NUMBER_RESOLVED})..."
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$plist_path"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER_RESOLVED}" "$plist_path"
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

    # Everything this catches fails SILENTLY in production: the release uploads fine and
    # existing installs are simply never offered it.
    echo ""
    echo "==> Verifying appcast..."
    "$ROOT_DIR/scripts/verify_appcast.py" \
        --appcast "$APPCAST_PATH" \
        --assets "$assets_dir" \
        --version "$VERSION" \
        --build "$BUILD_NUMBER_RESOLVED" \
        --tag "v${VERSION}"
}

# Guard against shipping a DMG built before the version bump.
verify_dmg_contents() {
    local dmg_path="$1"
    local mount_point="/tmp/immibridge-verify-$$"

    echo ""
    echo "==> Verifying app inside the DMG..."
    mkdir -p "$mount_point"
    hdiutil attach "$dmg_path" -mountpoint "$mount_point" -nobrowse -quiet
    local plist="$mount_point/ImmiBridge.app/Contents/Info.plist"
    local short build
    # Read with a fallback so a bad bundle cannot leave the image mounted under `set -e`.
    short="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || echo '<unreadable>')"
    build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist" 2>/dev/null || echo '<unreadable>')"
    hdiutil detach "$mount_point" -quiet
    rmdir "$mount_point" 2>/dev/null || true

    if [[ "$short" != "$VERSION" || "$build" != "$BUILD_NUMBER_RESOLVED" ]]; then
        echo "ERROR: DMG contains ${short} (build ${build}),"
        echo "       expected ${VERSION} (build ${BUILD_NUMBER_RESOLVED})."
        exit 1
    fi
    echo "    DMG contains ${short} (build ${build})"
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
    create_dmg "$app_dir" "$dmg_path" "ImmiBridge"

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
    create_dmg "$app_dir" "$dmg_path" "ImmiBridge"

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

release_instructions() {
    echo ""
    echo "================================================"
    echo "Release built: v${VERSION} (build ${BUILD_NUMBER_RESOLVED})"
    for dmg in "$@"; do
        echo "  $dmg"
    done
    echo ""
    echo "1. Commit the version bump -- the build metadata was rewritten in place and is"
    echo "   NOT yet committed:"
    echo "     git add ImmiBridge/ImmiBridge/UI/Info.plist \\"
    echo "             ImmiBridge/ImmiBridge.xcodeproj/project.pbxproj docs/appcast.xml"
    echo "     git commit -m 'Bump version to ${VERSION} (build ${BUILD_NUMBER_RESOLVED})'"
    echo "     git push"
    echo ""
    echo "2. Publish the release:"
    echo -n "     gh release create v${VERSION}"
    for dmg in "$@"; do
        echo -n " '$dmg'"
    done
    echo " --title 'v${VERSION}' --generate-notes"
    echo ""
    echo "   Publishing the release triggers .github/workflows/appcast.yml, which"
    echo "   regenerates and commits docs/appcast.xml from the uploaded DMG. Until that"
    echo "   lands, existing installs will not see this version."
    echo "================================================"
}

BUILD_NUMBER_RESOLVED="$(resolve_build_number)"
preflight
sync_version_metadata

if [[ "$BUILD_MODE" == "separate" ]]; then
    # Build separate arch-specific DMGs (legacy mode)
    build_and_notarize "arm64"
    build_and_notarize "x86_64"
    verify_dmg_contents "$DMG_ARM64_PATH"
    verify_dmg_contents "$DMG_X86_64_PATH"
    generate_appcast

    release_instructions "$DMG_ARM64_PATH" "$DMG_X86_64_PATH"
else
    # Build universal binary (default, recommended for Sparkle)
    build_universal_and_notarize
    verify_dmg_contents "$DMG_UNIVERSAL_PATH"
    generate_appcast

    release_instructions "$DMG_UNIVERSAL_PATH"
fi
