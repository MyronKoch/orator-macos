#!/bin/bash
# vendor-sherpa.sh - fetch the sherpa-onnx static xcframework and nest its headers.
#
# Why: Xcode copies every static xcframework's Headers/ into the same
# $BUILT_PRODUCTS_DIR/include/. sherpa-onnx and PhononCore (xn-ptts) both ship
# Headers/module.modulemap, so linking both fails with "Multiple commands
# produce .../include/module.modulemap". PhononCore arrives through a package
# we do not control, so sherpa's headers move into Headers/SherpaOnnxC/ instead.
# The module name (SherpaOnnxC) is unchanged, so `import SherpaOnnxC` still works.
#
# Output: Vendor/sherpa-onnx.xcframework (gitignored). Idempotent.

set -euo pipefail
cd "$(dirname "$0")/.."

URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.4/sherpa-onnx-v1.13.4-macos.xcframework.zip"
SHA256="4325d8aed99b94be58969005b19f9626f3f3afc4ebd42378b0aad2b84e233552"
OUT="Vendor/sherpa-onnx.xcframework"
STAMP="Vendor/.sherpa-onnx.sha256"

if [ -d "$OUT" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$SHA256" ]; then
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Fetching sherpa-onnx xcframework…"
curl -fsSL "$URL" -o "$WORK/sherpa.zip"
echo "$SHA256  $WORK/sherpa.zip" | shasum -a 256 -c - >/dev/null \
  || { echo "ERROR: sherpa-onnx zip checksum mismatch"; exit 1; }

mkdir "$WORK/x"
unzip -q "$WORK/sherpa.zip" -d "$WORK/x"
FW=$(find "$WORK/x" -maxdepth 2 -name "*.xcframework" -type d | head -1)
[ -n "$FW" ] || { echo "ERROR: no xcframework in archive"; exit 1; }

# Nest each slice's headers one level down.
for headers in "$FW"/*/Headers; do
  mkdir "$headers/SherpaOnnxC"
  find "$headers" -maxdepth 1 -type f -exec mv {} "$headers/SherpaOnnxC/" \;
done

mkdir -p Vendor
rm -rf "$OUT"
mv "$FW" "$OUT"
echo "$SHA256" > "$STAMP"
echo "==> Vendored $OUT"
