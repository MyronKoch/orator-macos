#!/bin/bash
# make-dmg.sh — Package build/Orator.app into a drag-to-Applications DMG.
#
# Usage: scripts/make-dmg.sh [--notarize [PROFILE]]
#   --notarize [PROFILE]   submit + staple. PROFILE defaults to "notarytool",
#                          the keychain profile convention used by the PAI
#                          DesktopRelease workflow.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Orator.app"
[ -d "$APP" ] || { echo "ERROR: $APP not found — run scripts/build-app.sh first"; exit 1; }

VERSION=$(defaults read "$(pwd)/$APP/Contents/Info" CFBundleShortVersionString)
DMG="build/Orator-$VERSION.dmg"
STAGE="build/dmg-stage"

echo "==> Staging…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating ${DMG} ..."
hdiutil create -volname "Orator" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

if [ "${1:-}" = "--notarize" ]; then
  PROFILE="${2:-notarytool}"
  echo "==> Submitting for notarization (waits for Apple)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  echo "==> Stapling ticket…"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG" && echo "    notarized + stapled"
fi

du -h "$DMG"
echo "==> Done: $DMG"
