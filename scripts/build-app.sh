#!/bin/bash
# build-app.sh — Build, assemble, and sign Orator.app
#
# Why xcodebuild instead of `swift build`: MLX requires its Metal shaders
# compiled into default.metallib, which only Xcode's build system does.
#
# Usage: scripts/build-app.sh [--sign "Developer ID Application: Name (TEAM)"]

set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY=""
if [ "${1:-}" = "--sign" ]; then
  SIGN_IDENTITY="${2:?identity required after --sign}"
fi

MODEL_SRC=$(find ~/.cache/huggingface/hub/models--prince-canuma--Kokoro-82M/snapshots -name "kokoro-v1_0.safetensors" 2>/dev/null | head -1)
[ -n "$MODEL_SRC" ] || { echo "ERROR: kokoro-v1_0.safetensors not found in HuggingFace cache"; exit 1; }

echo "==> Building (xcodebuild, Release)…"
xcodebuild -scheme Orator -configuration Release \
  -destination 'platform=macOS' -derivedDataPath .build/xcode build -quiet

PRODUCTS=".build/xcode/Build/Products/Release"
APP="build/Orator.app"

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$PRODUCTS/Orator" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp -R "$PRODUCTS/PackageFrameworks/"*.framework "$APP/Contents/Frameworks/"
cp -R "$PRODUCTS/mlx-swift_Cmlx.bundle" "$APP/Contents/Resources/"
[ -d "$PRODUCTS/KokoroSwift_KokoroSwift.bundle" ] && cp -R "$PRODUCTS/KokoroSwift_KokoroSwift.bundle" "$APP/Contents/Resources/"
[ -d "$PRODUCTS/MisakiSwift_MisakiSwift.bundle" ] && cp -R "$PRODUCTS/MisakiSwift_MisakiSwift.bundle" "$APP/Contents/Resources/"
cp Resources/voices.npz "$APP/Contents/Resources/"

echo "==> Copying model (312MB, real copy — no symlinks)…"
cp "$MODEL_SRC" "$APP/Contents/Resources/kokoro-v1_0.safetensors"

if [ -f Resources/Orator.icns ]; then
  cp Resources/Orator.icns "$APP/Contents/Resources/"
fi

echo "==> Fixing rpath (SPM binaries expect ../lib)…"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Orator" 2>/dev/null || true

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Signing frameworks…"
  for fw in "$APP/Contents/Frameworks/"*.framework; do
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$fw"
  done
  echo "==> Signing app (hardened runtime)…"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  echo "==> Verifying…"
  codesign --verify --deep --strict "$APP" && echo "    signature OK"
else
  echo "==> Ad-hoc signing (local dev only — TCC trust will NOT survive rebuilds)…"
  codesign --force --deep --sign - "$APP"
fi

du -sh "$APP"
echo "==> Done: $APP"
