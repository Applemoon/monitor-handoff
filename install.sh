#!/bin/bash
# Installs Monitor Handoff into ~/Applications (Open at Login registers that path) and starts it,
# replacing a running copy. Piped from curl it takes the latest release, built by GitHub Actions:
#   curl -fsSL https://raw.githubusercontent.com/Applemoon/monitor-handoff/main/install.sh | bash
# From a clone it builds the code next to it with the Command Line Tools alone (no Xcode).
set -euo pipefail
if [[ $(uname -m) != arm64 ]]; then
  echo "Monitor Handoff needs an Apple Silicon Mac."
  exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
app="$tmp/Monitor Handoff.app"
dest="$HOME/Applications/Monitor Handoff.app"
# Piped, the script has no file and no code next to it.
if [[ -n ${BASH_SOURCE[0]:-} && -f $(dirname "${BASH_SOURCE[0]}")/Sources/Follower.swift ]]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Building Monitor Handoff needs the Command Line Tools: xcode-select --install"
    exit 1
  fi
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$here/Info.plist" "$app/Contents/"
  swiftc -parse-as-library -O -target arm64-apple-macos14 -o "$app/Contents/MacOS/MonitorHandoff" "$here"/Sources/*.swift
  # The icon: every size macOS asks for, from icon.png (drawn by icon.swift).
  iconset="$tmp/AppIcon.iconset"
  mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$here/icon.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$here/icon.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
  codesign --force -s - "$app"
else
  # curl marks nothing as downloaded, so macOS opens the unnotarized app without asking.
  curl -fsSL https://github.com/Applemoon/monitor-handoff/releases/latest/download/Monitor-Handoff.zip -o "$tmp/app.zip"
  ditto -x -k "$tmp/app.zip" "$tmp"
fi
if pgrep -xq MonitorHandoff; then # quit it first: the bundle is about to be replaced
  osascript -e 'tell application id "com.auvarov.monitor-handoff" to quit'
  for _ in {1..50}; do pgrep -xq MonitorHandoff || break; sleep 0.1; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$dest"
ditto "$app" "$dest"
touch "$dest" # ditto carries the old date, by which macOS takes the build for the old one
open "$dest"
echo "Installed $dest"
