#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="${LOGITECH_SIGN_IDENTITY:-logitech-switcher-dev}"
PRODUCT="${1:-logitech-switcher}"

# Certificates made before the rename are still valid for signing.
if [ -z "${LOGITECH_SIGN_IDENTITY:-}" ] && ! security find-identity -p codesigning | grep -q "\"$NAME\"" \
    && security find-identity -p codesigning | grep -q '"logi-switch-dev"'; then
    NAME="logi-switch-dev"
fi

if ! security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "build: signing identity '$NAME' not found, run scripts/make-signing-cert.sh" >&2
    exit 20
fi

swift build -c release --product "$PRODUCT"
bin=".build/release/$PRODUCT"
codesign --force --sign "$NAME" --identifier "local.logitech-switcher.$PRODUCT" "$bin"
codesign --display --verbose=2 "$bin" 2>&1 | grep -E "Identifier|Authority|Signature"
echo "$bin"

# The zip carries the signed binary and install scripts to a Mac without a toolchain.
if [ "$PRODUCT" = "logitech-switcher" ]; then
    rm -rf dist/logitech-switcher dist/logitech-switcher.zip
    mkdir -p dist/logitech-switcher
    cp "$bin" scripts/install.sh scripts/uninstall.sh dist/logitech-switcher/
    ditto -c -k --keepParent dist/logitech-switcher dist/logitech-switcher.zip
    echo "dist/logitech-switcher.zip"
fi
