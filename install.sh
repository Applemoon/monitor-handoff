#!/bin/bash
# Builds Monitor Handoff with the Command Line Tools alone (no Xcode), installs it into
# ~/Applications (Open at Login registers that path) and starts it, replacing a running copy.
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
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
app="$tmp/Monitor Handoff.app"
dest="$HOME/Applications/Monitor Handoff.app"
mkdir -p "$app/Contents/MacOS"
cp "$here/Info.plist" "$app/Contents/"
swiftc -parse-as-library -O -target arm64-apple-macos14 -o "$app/Contents/MacOS/MonitorHandoff" "$here"/Sources/*.swift
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
