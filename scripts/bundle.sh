#!/bin/bash
# Builds the release binary and assembles ContainerStack.app.
# Usage: scripts/bundle.sh [--vendor]
#   --vendor  include Vendor/container (populated by scripts/vendor.sh) inside the bundle
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP_NAME="${APP_NAME:-Davit}"
BUNDLE_ID="${BUNDLE_ID:-dev.wouter.davit}"
VERSION="${VERSION:-0.1.0}"
BUILD_DIR="$ROOT/.build/release"
APP="$ROOT/dist/$APP_NAME.app"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILD_DIR/ContainerStack" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>UI for Apple's open-source container platform.</string>
    <key>CFBundleURLTypes</key>
    <array>
      <dict>
        <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
        <key>CFBundleURLSchemes</key><array><string>davit</string></array>
      </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> Installing app icon"
# Committed artwork (icon/davit.svg is the master; regenerate with icon/regenerate.py).
cp "$ROOT/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Menu bar template glyph (NSImage(named: "DavitTemplate") — the "Template"
# suffix makes AppKit treat it as a template image).
cp "$ROOT/icon/menubar/DavitTemplate.png" \
   "$ROOT/icon/menubar/DavitTemplate@2x.png" \
   "$ROOT/icon/menubar/DavitTemplate@3x.png" "$APP/Contents/Resources/"

if [ "${1:-}" = "--vendor" ]; then
  if [ -d "$ROOT/Vendor/container" ]; then
    echo "==> Vendoring container toolchain into bundle"
    mkdir -p "$APP/Contents/Resources/vendor"
    cp -R "$ROOT/Vendor/container/." "$APP/Contents/Resources/vendor/"
  else
    echo "warning: Vendor/container not found — run scripts/vendor.sh first" >&2
  fi
fi

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Codesigning with Developer ID (hardened runtime)"
  codesign --force --options runtime --timestamp -s "$CODESIGN_IDENTITY" "$APP"
else
  echo "==> Codesigning (ad-hoc)"
  codesign --force --deep -s - "$APP"
fi

echo "==> Done: $APP"
