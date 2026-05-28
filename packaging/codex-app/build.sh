#!/usr/bin/env bash
# Build the "Redpen" wrapper .app:
#   - uses the committed app icon (packaging/codex-app/assets/app-icon-1024.png)
#   - compiles an AppleScript launcher app and embeds the launcher binary
#
# An AppleScript applet is used (rather than a shell-script CFBundleExecutable)
# because it has a real Mach-O stub and launches reliably via LaunchServices /
# double-click. It starts the launcher detached, then exits; the launcher lives
# until Codex App quits.
#
# Output: packaging/codex-app/build/Redpen.app
# Env overrides:
#   BIN          prebuilt redpen-codex-app binary to embed (CI passes the
#                universal binary; otherwise the binary is built with cargo)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/build"
APP="$OUT/Red Pen.app"
VERSION="0.3.1"
BUNDLE_ID="org.redpen.app"
PB=/usr/libexec/PlistBuddy

for t in iconutil sips osacompile codesign; do
  command -v "$t" >/dev/null || { echo "$t not found"; exit 1; }
done

ICON_PNG="$HERE/assets/app-icon-1024.png"
if [ ! -f "$ICON_PNG" ]; then
  echo "==> committed icon missing, regenerating (requires Codex.app)"
  bash "$HERE/make-icon.sh"
fi

if [ -z "${BIN:-}" ]; then
  echo "==> building launcher binary"
  ( cd "$REPO" && cargo build --release -p redpen-codex-app )
  BIN="$REPO/target/release/redpen-codex-app"
fi
[ -f "$BIN" ] || { echo "launcher binary not found: $BIN"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> building icns from committed icon"
iconset="$work/AppIcon.iconset"; mkdir -p "$iconset"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  px="${spec%%:*}"; name="${spec##*:}"
  sips -z "$px" "$px" "$ICON_PNG" --out "$iconset/icon_${name}.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$work/AppIcon.icns"

echo "==> compiling AppleScript app"
rm -rf "$APP"; mkdir -p "$OUT"
osacompile -o "$APP" "$HERE/wrapper.applescript"

echo "==> embedding binary + icon + metadata"
mkdir -p "$APP/Contents/Resources/bin"
cp "$BIN" "$APP/Contents/Resources/bin/redpen-codex-app"
chmod +x "$APP/Contents/Resources/bin/redpen-codex-app"
# Use a uniquely-named icon (not osacompile's default applet.icns) so the icon
# isn't confused with the generic applet icon in icon caches.
rm -f "$APP/Contents/Resources/applet.icns"
# osacompile also emits an asset catalog (Assets.car) holding the default applet
# icon and sets CFBundleIconName=applet in Info.plist. CFBundleIconName (asset
# catalog) outranks CFBundleIconFile, so leaving it makes macOS show the generic
# applet icon. Drop the asset catalog so only our AppIcon.icns is used.
rm -f "$APP/Contents/Resources/Assets.car"
cp "$work/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

PLIST="$APP/Contents/Info.plist"
# Remove the asset-catalog icon reference osacompile adds; it outranks
# CFBundleIconFile and would point back at the generic applet icon.
$PB -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true
$PB -c "Set :CFBundleIconFile AppIcon" "$PLIST"
$PB -c "Set :CFBundleName Red Pen" "$PLIST"
$PB -c "Add :CFBundleDisplayName string Red Pen" "$PLIST" 2>/dev/null || $PB -c "Set :CFBundleDisplayName Red Pen" "$PLIST"
$PB -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$PLIST" 2>/dev/null || $PB -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
$PB -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST" 2>/dev/null || $PB -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
$PB -c "Add :CFBundleVersion string $VERSION" "$PLIST" 2>/dev/null || $PB -c "Set :CFBundleVersion $VERSION" "$PLIST"
# Not LSUIElement: the launcher shows a progress bar + dialogs, which need a
# foreground UI context. The app exits right after kicking off the (detached)
# launcher, so the dock icon only appears briefly.
$PB -c "Add :NSHighResolutionCapable bool true" "$PLIST" 2>/dev/null || true

touch "$APP"

# Ad-hoc sign (distribution needs a real Developer ID + notarization).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc codesign skipped)"

echo "Built: $APP"
