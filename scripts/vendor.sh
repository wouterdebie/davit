#!/bin/bash
# Vendors Apple's `container` toolchain into Vendor/container so the app can run
# without a system-wide install. Downloads the official signed installer package
# from the apple/container GitHub release and extracts its payload.
#
# Usage: scripts/vendor.sh [version]     (default: 1.1.0)
#
# Resulting layout (mirrors the official /usr/local install root):
#   Vendor/container/bin/container
#   Vendor/container/libexec/container/...   (apiserver, runtime & network helpers)
#
# The app resolves this copy as a fallback when no system install exists, and
# passes `--install-root` pointing at the vendored root when starting services.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-1.1.0}"
URL="https://github.com/apple/container/releases/download/${VERSION}/container-${VERSION}-installer-signed.pkg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading container ${VERSION} installer"
curl -fL "$URL" -o "$WORK/container.pkg"

echo "==> Extracting payload"
pkgutil --expand-full "$WORK/container.pkg" "$WORK/expanded"

PAYLOAD="$(find "$WORK/expanded" -type d -name Payload | head -1)"
if [ -z "$PAYLOAD" ]; then
  echo "error: could not find Payload in the installer package" >&2
  exit 1
fi

rm -rf Vendor/container
mkdir -p Vendor/container
# Payload mirrors the /usr/local install root (bin/, libexec/)
cp -R "$PAYLOAD/." Vendor/container/

echo "==> Vendored into Vendor/container:"
find Vendor/container -maxdepth 2 -type d
echo
echo "Now run: scripts/bundle.sh --vendor"
