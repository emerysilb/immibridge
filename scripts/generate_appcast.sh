#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$ROOT_DIR/tools/sparkle/bin}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:?Set SPARKLE_PRIVATE_KEY to the Sparkle private key path}"
GITHUB_REPO="${GITHUB_REPO:?Set GITHUB_REPO like 'owner/repo'}"
TAG="${TAG:-v${VERSION:-}}"
ASSETS_DIR="${ASSETS_DIR:-$ROOT_DIR/build}"
APPCAST_PATH="${APPCAST_PATH:-$ROOT_DIR/docs/appcast.xml}"

if [[ -z "$TAG" ]]; then
    echo "Set TAG (e.g. v1.0.3) or VERSION before generating the appcast."
    exit 1
fi

if [[ ! -x "$SPARKLE_TOOLS_DIR/generate_appcast" ]]; then
    echo "Sparkle tools not found at $SPARKLE_TOOLS_DIR"
    exit 1
fi

mkdir -p "$(dirname "$APPCAST_PATH")"

"$SPARKLE_TOOLS_DIR/generate_appcast" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY" \
    --link "https://github.com/${GITHUB_REPO}/releases" \
    --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/${TAG}/" \
    -o "$APPCAST_PATH" \
    "$ASSETS_DIR"

echo "Appcast generated at $APPCAST_PATH"
