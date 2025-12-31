#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$ROOT_DIR/tools/sparkle/bin}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:?Set SPARKLE_PRIVATE_KEY to the Sparkle private key path or '-' for stdin}"
SPARKLE_PRIVATE_KEY_CONTENT="${SPARKLE_PRIVATE_KEY_CONTENT:-}"
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

if [[ "$SPARKLE_PRIVATE_KEY" == "-" ]]; then
    SPARKLE_PRIVATE_KEY_CONTENT="$(printf "%s" "$SPARKLE_PRIVATE_KEY_CONTENT" | tr -d ' \r\n\t')"
    if [[ -z "$SPARKLE_PRIVATE_KEY_CONTENT" ]]; then
        echo "Set SPARKLE_PRIVATE_KEY_CONTENT when using SPARKLE_PRIVATE_KEY='-'."
        exit 1
    fi
    if [[ "${#SPARKLE_PRIVATE_KEY_CONTENT}" -lt 32 ]]; then
        echo "Sparkle private key content looks too short (${#SPARKLE_PRIVATE_KEY_CONTENT} chars)."
        exit 1
    fi
    printf "%s" "$SPARKLE_PRIVATE_KEY_CONTENT" | \
        "$SPARKLE_TOOLS_DIR/generate_appcast" \
            --ed-key-file - \
            --link "https://github.com/${GITHUB_REPO}/releases" \
            --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/${TAG}/" \
            -o "$APPCAST_PATH" \
            "$ASSETS_DIR"
else
    if [[ ! -s "$SPARKLE_PRIVATE_KEY" ]]; then
        echo "Sparkle private key file missing or empty: $SPARKLE_PRIVATE_KEY"
        exit 1
    fi
    "$SPARKLE_TOOLS_DIR/generate_appcast" \
        --ed-key-file "$SPARKLE_PRIVATE_KEY" \
        --link "https://github.com/${GITHUB_REPO}/releases" \
        --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/${TAG}/" \
        -o "$APPCAST_PATH" \
        "$ASSETS_DIR"
fi

echo "Appcast generated at $APPCAST_PATH"
