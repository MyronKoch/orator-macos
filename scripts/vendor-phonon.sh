#!/bin/bash
# vendor-phonon.sh - fetch the Phonon 31M Core ML bundle that ships inside Orator.
#
# Phonon 31M English (gradium/phonon-31m-en) and its voices (gradium/phonon-voices)
# are Apache-2.0. NEVER substitute a Phonon 40M bundle: those weights are
# CC BY-NC 4.0 and cannot ship in Orator.
#
# Output: Vendor/PhononModels (gitignored, ~163 MB unpacked). Idempotent.

set -euo pipefail
cd "$(dirname "$0")/.."

URL="https://github.com/gradium-ai/xn-ptts/releases/download/v0.4.0/phonon-31m-en-coreml.zip"
SHA256="10f3a99fd39256db44f826267ef21d78cca959b16c0554926344c09fde27b436"
OUT="Vendor/PhononModels"
STAMP="Vendor/.phonon-models.sha256"

if [ -f "$OUT/bundle.json" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$SHA256" ]; then
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "==> Fetching Phonon 31M Core ML bundle (137 MB)…"
curl -fsSL "$URL" -o "$WORK/phonon.zip"
echo "$SHA256  $WORK/phonon.zip" | shasum -a 256 -c - >/dev/null \
  || { echo "ERROR: Phonon bundle checksum mismatch"; exit 1; }

mkdir "$WORK/x"
unzip -q "$WORK/phonon.zip" -d "$WORK/x"
BUNDLE=$(dirname "$(find "$WORK/x" -name bundle.json | head -1)")
[ -f "$BUNDLE/bundle.json" ] || { echo "ERROR: no bundle.json in archive"; exit 1; }

mkdir -p Vendor
rm -rf "$OUT"
mv "$BUNDLE" "$OUT"
echo "$SHA256" > "$STAMP"
echo "==> Vendored $OUT"
