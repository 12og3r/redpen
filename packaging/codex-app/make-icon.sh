#!/usr/bin/env bash
# Regenerate the committed app icon from the redpen-codex plugin icon, so the
# Red Pen(Codex).app icon matches the plugin's icon. CI consumes the committed PNG.
#
# Output (committed): packaging/codex-app/assets/app-icon-1024.png
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC_SVG="$REPO/plugins/redpen-codex/assets/icon.svg"
OUT="$HERE/assets/app-icon-1024.png"

command -v qlmanage >/dev/null || { echo "qlmanage not found"; exit 1; }
[ -f "$SRC_SVG" ] || { echo "plugin icon not found: $SRC_SVG"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

qlmanage -t -s 1024 -o "$work" "$SRC_SVG" >/dev/null 2>&1
mv -f "$work/icon.svg.png" "$OUT"

echo "wrote $OUT"
