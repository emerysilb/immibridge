#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT_DIR="$ROOT_DIR/ImmiBridge"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
DESTINATION="${DESTINATION:-generic/platform=macOS}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.xcodebuild}"
OUTPUT_APP_DIR="${OUTPUT_APP_DIR:-$ROOT_DIR/build/ImmiBridge.app}"
# Optional: specify architectures (e.g., "arm64 x86_64" for universal binary)
ARCHS="${ARCHS:-}"

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
XCODE_ARGS=(
    -project "$PROJECT_DIR/ImmiBridge.xcodeproj"
    -scheme ImmiBridge
    -configuration Release
    -derivedDataPath "$DERIVED_DATA_PATH"
    -destination "$DESTINATION"
)

# Add ARCHS if specified (for universal binary)
if [[ -n "$ARCHS" ]]; then
    echo "Architectures: $ARCHS"
    XCODE_ARGS+=("ARCHS=$ARCHS" "ONLY_ACTIVE_ARCH=NO")
fi

xcodebuild "${XCODE_ARGS[@]}" build

# Copy the built app to the build directory
rm -rf "$APP_DIR"
mkdir -p "$(dirname "$APP_DIR")"
cp -R "$DERIVED_DATA_PATH/Build/Products/Release/ImmiBridge.app" "$APP_DIR"

# Re-sign if a custom identity is provided (for notarization)
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    echo "Re-signing with identity: $CODESIGN_IDENTITY"

    # Sign all Sparkle framework components from innermost to outermost
    SPARKLE_DIR="$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B"

    if [[ -d "$SPARKLE_DIR" ]]; then
        # 1. Sign XPC services
        for xpc in "$SPARKLE_DIR/XPCServices/"*.xpc; do
            if [[ -d "$xpc" ]]; then
                echo "  Signing XPC service: $(basename "$xpc")"
                codesign --force --options runtime --timestamp \
                    --sign "$CODESIGN_IDENTITY" "$xpc"
            fi
        done

        # 2. Sign Updater.app
        if [[ -d "$SPARKLE_DIR/Updater.app" ]]; then
            echo "  Signing nested app: Updater.app"
            codesign --force --options runtime --timestamp \
                --sign "$CODESIGN_IDENTITY" "$SPARKLE_DIR/Updater.app"
        fi

        # 3. Sign Autoupdate executable
        if [[ -f "$SPARKLE_DIR/Autoupdate" ]]; then
            echo "  Signing executable: Autoupdate"
            codesign --force --options runtime --timestamp \
                --sign "$CODESIGN_IDENTITY" "$SPARKLE_DIR/Autoupdate"
        fi
    fi

    # 4. Sign the Sparkle framework itself
    if [[ -d "$APP_DIR/Contents/Frameworks/Sparkle.framework" ]]; then
        echo "  Signing framework: Sparkle.framework"
        codesign --force --options runtime --timestamp \
            --sign "$CODESIGN_IDENTITY" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
    fi

    # 5. Sign the main app
    codesign --force --options runtime --timestamp \
        --entitlements "$PROJECT_DIR/ImmiBridge/ImmiBridge.entitlements" \
        --sign "$CODESIGN_IDENTITY" "$APP_DIR"
fi

echo ""
echo "Built: $APP_DIR"
echo ""
echo "To install, copy to /Applications:"
echo "  cp -r '$APP_DIR' /Applications/"
