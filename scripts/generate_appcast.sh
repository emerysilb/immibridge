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
    if [[ -z "$SPARKLE_PRIVATE_KEY_CONTENT" ]]; then
        echo "Set SPARKLE_PRIVATE_KEY_CONTENT when using SPARKLE_PRIVATE_KEY='-'."
        exit 1
    fi
    cleaned_key="$(python3 - <<'PY'
import base64
import os
import sys

raw = os.environ.get("SPARKLE_PRIVATE_KEY_CONTENT", "")
raw = "".join(raw.split())
raw = raw.strip("\"'")
if not raw:
    print("Sparkle private key content is empty after normalization.", file=sys.stderr)
    raise SystemExit(1)
try:
    decoded = base64.b64decode(raw, validate=True)
except Exception:
    print("Sparkle private key content is not valid base64.", file=sys.stderr)
    raise SystemExit(2)
if len(decoded) != 32:
    print(f"Sparkle private key decoded length {len(decoded)} (expected 32).", file=sys.stderr)
    raise SystemExit(3)
print(raw)
PY
)"
    if [[ -z "$cleaned_key" ]]; then
        echo "Sparkle private key content is empty after normalization."
        exit 1
    fi
    printf "%s\n" "$cleaned_key" | \
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
