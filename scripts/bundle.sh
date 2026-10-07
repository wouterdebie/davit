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
# The SDK goes to the link as -isysroot. AppKit picks the window design from the
# SDK version recorded in the binary (26+ gets Liquid Glass). Xcode 27's default
# SwiftPM build system links through clang with --sysroot, which clang reads no
# version from, so the binary recorded the deployment target (15.0) as its SDK
# and the app came out in the pre-Tahoe design. Check with:
#   vtool -show-build dist/Davit.app/Contents/MacOS/Davit | grep sdk
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
swift build -c release \
  -Xswiftc -Xclang-linker -Xswiftc -isysroot \
  -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

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
    <!-- Sparkle. The appcast ships as a release asset so the feed needs no
         separate hosting; davit.app still serves the legacy appcast.json for
         clients older than the Sparkle switchover. SUPublicEDKey is shared with
         Don't Miss on purpose: one signing key, one mechanism. Sparkle reads
         exactly one key and has no rotation path, so this value is permanent. -->
    <key>SUFeedURL</key><string>https://github.com/wouterdebie/davit/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>sQaiI9b/3VZCmzwNNRBCsDHm7uZ09UwG8ZdgtcVQkNQ=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <!-- 86400s, matching the daily cadence the previous updater used. -->
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
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

echo "==> Embedding Sparkle.framework"
# ditto, not cp: the framework is a versioned bundle of symlinks, and a flattened
# copy fails `codesign --verify --deep` in a way that only shows up at install.
ditto "$BUILD_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"

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

bash "$ROOT/scripts/sign.sh" "$APP"

echo "==> Done: $APP"
