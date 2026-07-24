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

# Notarize + staple the APP FIRST, before it goes into the DMG. Stapling the
# DMG alone is not enough: once the user drags Orator.app to /Applications,
# that copy carries no ticket of its own, so Gatekeeper must do an ONLINE
# check on first launch — which fails on a captive/blocked network with the
# infamous "Orator is damaged and can't be opened." Stapling the app makes it
# self-verifying offline forever.
if [ "${1:-}" = "--notarize" ]; then
  PROFILE="${2:-notarytool}"
  APPZIP="build/Orator-notarize.zip"
  echo "==> Zipping app for notarization…"
  rm -f "$APPZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$APPZIP"
  echo "==> Submitting app for notarization (waits for Apple)…"
  xcrun notarytool submit "$APPZIP" --keychain-profile "$PROFILE" --wait
  rm -f "$APPZIP"
  echo "==> Stapling ticket to the app…"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP" && echo "    app notarized + stapled"
fi

echo "==> Staging…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating ${DMG} ..."
hdiutil create -volname "Orator" -srcfolder "$STAGE" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGE"

# Staple the DMG too (belt and braces) so the disk image itself verifies
# offline. The app inside is already stapled above.
if [ "${1:-}" = "--notarize" ]; then
  PROFILE="${2:-notarytool}"
  echo "==> Submitting DMG for notarization (waits for Apple)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  echo "==> Stapling ticket to the DMG…"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG" && echo "    DMG notarized + stapled"
fi

du -h "$DMG"
echo "==> Done: $DMG"
