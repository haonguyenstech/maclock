#!/bin/bash
# Build + publish a new MacLock version to GitHub Releases (public repo).
# Usage: bump CFBundleShortVersionString in Info.plist, then: ./release.sh
set -euo pipefail
cd "$(dirname "$0")"

REPO="haonguyenstech/maclock"

./package.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
ZIP="dist/MacLock.zip"   # stable asset name

echo ""
echo "Releasing v$VERSION to github.com/$REPO …"
gh release create "v$VERSION" "$ZIP" \
  --repo "$REPO" \
  --title "v$VERSION" \
  --notes "MacLock v$VERSION — a native-style lock screen with Touch ID unlock." \
  || { echo "Release v$VERSION may already exist. Bump the version in Info.plist first."; exit 1; }

echo "✅ Released: https://github.com/$REPO/releases/tag/v$VERSION"
