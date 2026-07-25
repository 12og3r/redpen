#!/usr/bin/env sh
set -eu

repo="${REDPEN_REPO:-12og3r/redpen}"
version="${REDPEN_VERSION:-latest}"
install_dir="${REDPEN_INSTALL_DIR:-$HOME/.local/bin}"
asset="redpen-chatgpt-app-macos-universal"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "redpen-chatgpt-app currently supports macOS only." >&2
  exit 1
fi

if [ "$version" = "latest" ]; then
  base_url="https://github.com/$repo/releases/latest/download"
else
  base_url="https://github.com/$repo/releases/download/$version"
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT INT TERM

binary_path="$tmp_dir/$asset"
checksum_path="$tmp_dir/$asset.sha256"

echo "Downloading $asset from $repo ($version)..."
curl -fsSL "$base_url/$asset" -o "$binary_path"
curl -fsSL "$base_url/$asset.sha256" -o "$checksum_path"

(
  cd "$tmp_dir"
  shasum -a 256 -c "$asset.sha256"
)

mkdir -p "$install_dir"
chmod +x "$binary_path"
mv "$binary_path" "$install_dir/redpen-chatgpt-app"

echo "Installed redpen-chatgpt-app to $install_dir/redpen-chatgpt-app"
echo "Run: redpen-chatgpt-app launch"

# The chatgpt-app channel is counted at runtime (first launch per version) by
# the embedded coach so DMG, curl, and manual installs are captured uniformly.
