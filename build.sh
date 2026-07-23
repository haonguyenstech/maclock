#!/bin/bash
# Build and install MacLock.app into /Applications (universal, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MacLock"
BUNDLE="/Applications/$APP_NAME.app"

mkdir -p build

echo "Compiling (universal: arm64 + x86_64)…"
for ARCH in arm64 x86_64; do
  swiftc -O \
    -target "$ARCH-apple-macos14.0" \
    Sources/main.swift \
    -o "build/MacLock-$ARCH" \
    -framework AppKit \
    -framework SwiftUI \
    -framework LocalAuthentication \
    -framework ServiceManagement \
    -framework IOKit \
    -framework Carbon
done
lipo -create -output build/MacLock build/MacLock-arm64 build/MacLock-x86_64

if [ ! -f AppIcon.icns ]; then
  echo "Generating icon…"
  swift gen-icon.swift
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi

echo "Bundling…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp build/MacLock "$BUNDLE/Contents/MacOS/MacLock"
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Prefer the stable self-signed identity (created by ./setup-signing.sh) so the
# app's designated requirement — and therefore its TCC/Accessibility grant —
# survives every rebuild/update. Fall back to ad-hoc if it isn't installed.
SIGN_ID="MacLock Code Signing"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  echo "Signing (stable identity: $SIGN_ID)…"
  codesign --force --deep --sign "$SIGN_ID" "$BUNDLE"
else
  echo "Signing (ad-hoc — run ./setup-signing.sh for a stable Accessibility grant)…"
  codesign --force --deep --sign - "$BUNDLE"
fi

echo "Done: $BUNDLE"
echo "Launch: open \"$BUNDLE\""
