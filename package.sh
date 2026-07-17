#!/bin/bash
# Build a shareable zip with a STABLE name: dist/MacLock.zip
# (stable name so https://github.com/<repo>/releases/latest/download/MacLock.zip
#  always resolves — GitHub does NOT support wildcards in that URL).
# Contents (flat, under a "MacLock" folder): MacLock.app + Install.command
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
APP="/Applications/MacLock.app"
STAGE="dist/MacLock"
ZIP="dist/MacLock.zip"

rm -rf dist
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

cat > "$STAGE/Install.command" <<'EOF'
#!/bin/bash
# MacLock installer — double-click, or run:  bash Install.command
set -e
cd "$(dirname "$0")"
APP="MacLock.app"
DEST="/Applications"
echo "==> Installing $APP to $DEST …"
mkdir -p "$DEST"
pkill -x MacLock 2>/dev/null || true
sleep 1
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true
open "$DEST/$APP"
echo "==> Done. MacLock is running in your menu bar (padlock icon)."
echo "==> Grant Accessibility when prompted so it can block the keyboard."
EOF
chmod +x "$STAGE/Install.command"

# ditto keeps the app bundle intact; --keepParent puts everything under "MacLock/".
( cd dist && ditto -c -k --keepParent MacLock MacLock.zip )
echo "Packaged: $ZIP (version $VERSION)"
