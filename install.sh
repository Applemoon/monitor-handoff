#!/bin/bash
# Builds Monitor Handoff with the Command Line Tools alone (no Xcode), installs it into
# ~/Applications (Open at Login registers that path) and starts it, replacing a running copy.
# From a clone it builds the code next to it; piped from curl it downloads the code first:
#   curl -fsSL https://raw.githubusercontent.com/Applemoon/monitor-handoff/main/install.sh | bash
set -euo pipefail
if [[ $(uname -m) != arm64 ]]; then
  echo "Monitor Handoff needs an Apple Silicon Mac."
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Monitor Handoff builds from source and needs the Command Line Tools: xcode-select --install"
  exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Piped, the script has no file and no code next to it.
if [[ -n ${BASH_SOURCE[0]:-} && -f $(dirname "${BASH_SOURCE[0]}")/Sources/Follower.swift ]]; then
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
else
  curl -fsSL https://github.com/Applemoon/monitor-handoff/archive/refs/heads/main.tar.gz | tar -xz -C "$tmp"
  here=$tmp/monitor-handoff-main
fi
app="$tmp/Monitor Handoff.app"
dest="$HOME/Applications/Monitor Handoff.app"
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
