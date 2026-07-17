#!/bin/bash
# MacLock — public installer. Always installs the latest release.
#
#   curl -fsSL https://raw.githubusercontent.com/haonguyenstech/maclock/master/install.sh | bash
#
# Public repo, no token required. Run it again any time to update.
set -e

REPO="haonguyenstech/maclock"
API="https://api.github.com/repos/$REPO/releases/latest"
APP="MacLock.app"

# Prefer /Applications (shows in Launchpad + Applications folder); fall back to
# ~/Applications if /Applications isn't writable (non-admin users).
if mkdir -p /Applications 2>/dev/null && [ -w /Applications ]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

echo "==> Looking up the latest version…"
JSON=$(/usr/bin/curl -fsSL -H "Accept: application/vnd.github+json" "$API")
TAG=$(printf '%s' "$JSON" | /usr/bin/sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
ZIPURL=$(printf '%s' "$JSON" \
  | /usr/bin/grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 \
  | /usr/bin/sed 's/.*"\(https[^"]*\)"/\1/')
[ -n "$ZIPURL" ] || { echo "❌ No release asset found at $API"; exit 1; }
echo "==> Latest version: ${TAG:-unknown}"

TMP=$(mktemp -d)
echo "==> Downloading…"
/usr/bin/curl -fsSL -o "$TMP/app.zip" "$ZIPURL"
/usr/bin/ditto -x -k "$TMP/app.zip" "$TMP/x"
SRC=$(/usr/bin/find "$TMP/x" -maxdepth 4 -name "$APP" | head -1)
[ -n "$SRC" ] || { echo "❌ '$APP' not found inside the download"; exit 1; }

echo "==> Installing to $DEST …"
mkdir -p "$DEST"
pkill -x MacLock 2>/dev/null || true
sleep 1
rm -rf "$DEST/$APP"
/usr/bin/ditto "$SRC" "$DEST/$APP"
# Remove a stale copy from the other Applications folder to avoid duplicates.
[ "$DEST" = "/Applications" ] && rm -rf "$HOME/Applications/$APP" 2>/dev/null || true
# Strip the Gatekeeper quarantine flag so the app opens without warnings.
/usr/bin/xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true
rm -rf "$TMP"

open "$DEST/$APP"
echo ""
echo "✅ Done! Look for the padlock icon in your menu bar."
echo "   • Grant Accessibility (System Settings → Privacy → Accessibility) so it can block the keyboard."
echo "   • Right-click the icon → Settings… to set a shortcut, dim timer, and Launch at Login."
