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

# --- Sparkle update archive + appcast (release time) ---
# Sparkle updates ship as a .app ZIP (best delta support); the DMG stays the
# website/first-download artifact. generate_appcast signs each enclosure with
# the EdDSA private key from the login keychain and writes appcast.xml, which is
# committed to master (SUFeedURL points at raw master/appcast.xml). Enclosure
# URLs point at this tag's GitHub release download. Keeping prior versions'
# zips in the updates folder is what lets generate_appcast compute deltas, so a
# code-only update is a small patch rather than the full ~320 MB.
if [ "${1:-}" = "--notarize" ]; then
  GEN=$(find .build/xcode/SourcePackages/artifacts/sparkle -name generate_appcast -path "*/bin/*" 2>/dev/null | head -1)
  if [ -n "$GEN" ]; then
    UPDATES="build/sparkle-updates"
    mkdir -p "$UPDATES"
    echo "==> Building Sparkle update zip + appcast…"
    /usr/bin/ditto -c -k --keepParent "$APP" "$UPDATES/Orator-$VERSION.zip"
    "$GEN" "$UPDATES" \
      --download-url-prefix "https://github.com/MyronKoch/orator-macos/releases/download/v$VERSION/"
    cp "$UPDATES/appcast.xml" appcast.xml
    echo "    appcast.xml written -> commit+push to master; upload $UPDATES/Orator-$VERSION.zip to the release"
  else
    echo "    WARNING: generate_appcast not found (resolve packages first); appcast NOT generated"
  fi
fi

du -h "$DMG"
echo "==> Done: $DMG"
