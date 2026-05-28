#!/usr/bin/env bash
# Package the "Red Pen" wrapper .app into a styled drag-to-Applications .dmg:
# a manuscript-themed background (cream paper, red pen arrow), hidden toolbar,
# large icons, and the app + Applications laid out for drag-install.
# Builds the .app first if it is missing.
#
# Output: packaging/codex-app/build/Red Pen.dmg
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build"
APP="$OUT/Red Pen(Codex).app"
DMG="$OUT/Red Pen.dmg"
RW="$OUT/.rw.dmg"
VOL="Red Pen"

WIN_W=660; WIN_H=440; ICON=128
APP_X=175; APP_Y=205
APPS_X=485; APPS_Y=205
WIN_X=320; WIN_Y=150

for t in hdiutil qlmanage sips swift tiffutil osascript; do
  command -v "$t" >/dev/null || { echo "$t not found"; exit 1; }
done

[ -d "$APP" ] || { echo "==> .app not found, building it"; bash "$HERE/build.sh"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> rendering background"
qlmanage -t -s $((WIN_W * 2)) -o "$work" "$HERE/assets/dmg-background.svg" >/dev/null 2>&1
IN="$work/dmg-background.svg.png" OUT="$work/bg@2x.png" W=$((WIN_W*2)) H=$((WIN_H*2)) \
  swift "$HERE/crop_top.swift"
sips -z "$WIN_H" "$WIN_W" "$work/bg@2x.png" --out "$work/bg.png" >/dev/null
tiffutil -cathidpicheck "$work/bg.png" "$work/bg@2x.png" -out "$work/background.tiff" >/dev/null 2>&1

echo "==> staging"
stage="$work/stage"; mkdir -p "$stage/.background"
cp -R "$APP" "$stage/"
ln -s /Applications "$stage/Applications"
cp "$work/background.tiff" "$stage/.background/background.tiff"

echo "==> creating writable dmg"
rm -f "$RW" "$DMG"
hdiutil create -srcfolder "$stage" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW" >/dev/null

echo "==> mounting + styling"
mp="$(hdiutil attach "$RW" -nobrowse -noverify -noautoopen 2>/dev/null | tail -1 | awk -F'\t' '{print $NF}')"
osascript <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {$WIN_X, $WIN_Y, $((WIN_X+WIN_W)), $((WIN_Y+WIN_H))}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to $ICON
    set text size of theViewOptions to 13
    set background picture of theViewOptions to POSIX file "$mp/.background/background.tiff"
    set position of item "Red Pen(Codex).app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
    update without registering applications
    delay 1
    close
    open
    delay 1
  end tell
end tell
OSA

sync
hdiutil detach "$mp" >/dev/null 2>&1 || hdiutil detach "$mp" -force >/dev/null 2>&1

echo "==> compressing"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"

echo "Built: $DMG"
