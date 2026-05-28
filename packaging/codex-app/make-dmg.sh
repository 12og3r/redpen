#!/usr/bin/env bash
# Package the "Red Pen(Codex)" wrapper .app into a styled drag-to-Applications
# .dmg: a manuscript-themed background (cream paper, red pen arrow), hidden
# toolbar, large icons, and the app + Applications laid out for drag-install.
#
# Styling is done by dmgbuild, which writes the .DS_Store directly (no Finder /
# AppleScript), so this works headless on CI runners. Builds the .app first if
# it is missing. The DMG/volume name stays version-neutral ("Red Pen") so other
# variants can share one image later.
#
# Output: packaging/codex-app/build/Red Pen.dmg
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build"
APP="$OUT/Red Pen(Codex).app"
DMG="$OUT/Red Pen.dmg"
VOL="Red Pen"

WIN_W=660; WIN_H=440; ICON=128
APP_X=175; APP_Y=205
APPS_X=485; APPS_Y=205
WIN_X=320; WIN_Y=150

for t in qlmanage sips swift tiffutil; do
  command -v "$t" >/dev/null || { echo "$t not found"; exit 1; }
done
command -v dmgbuild >/dev/null || {
  echo "dmgbuild not found. Install it with: python3 -m pip install dmgbuild"; exit 1; }

[ -d "$APP" ] || { echo "==> .app not found, building it"; bash "$HERE/build.sh"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> rendering background"
qlmanage -t -s $((WIN_W * 2)) -o "$work" "$HERE/assets/dmg-background.svg" >/dev/null 2>&1
IN="$work/dmg-background.svg.png" OUT="$work/bg@2x.png" W=$((WIN_W*2)) H=$((WIN_H*2)) \
  swift "$HERE/crop_top.swift"
sips -z "$WIN_H" "$WIN_W" "$work/bg@2x.png" --out "$work/bg.png" >/dev/null
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$work/background.tiff" >/dev/null 2>&1

echo "==> building dmg"
rm -f "$DMG"
APP="$APP" BG="$work/background.tiff" \
  WIN_W=$WIN_W WIN_H=$WIN_H WIN_X=$WIN_X WIN_Y=$WIN_Y ICON=$ICON \
  APP_X=$APP_X APP_Y=$APP_Y APPS_X=$APPS_X APPS_Y=$APPS_Y \
  dmgbuild -s "$HERE/dmgbuild-settings.py" "$VOL" "$DMG" >/dev/null

echo "Built: $DMG"
