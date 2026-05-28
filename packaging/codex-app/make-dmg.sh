#!/usr/bin/env bash
# Package the "Redpen" wrapper .app into a drag-to-Applications .dmg.
# Builds the .app first if it is missing.
#
# Output: packaging/codex-app/build/Redpen.dmg
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build"
APP="$OUT/Red Pen.app"
DMG="$OUT/Red Pen.dmg"
VOL="Red Pen"

command -v hdiutil >/dev/null || { echo "hdiutil not found"; exit 1; }

if [ ! -d "$APP" ]; then
  echo "==> .app not found, building it"
  bash "$HERE/build.sh"
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

echo "==> staging"
cp -R "$APP" "$stage/"
ln -s /Applications "$stage/Applications"

echo "==> creating dmg"
rm -f "$DMG"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$stage" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

echo "Built: $DMG"
