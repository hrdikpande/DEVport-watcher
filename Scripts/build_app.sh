#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Ports.app"
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

if [[ ! -f assets/AppIcon.icns ]]; then
  mkdir -p build/icon/AppIcon.iconset
  swiftc -O tools/icon.swift -o build/icon/gen
  build/icon/gen build/icon/1024.png
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" build/icon/1024.png --out "build/icon/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" build/icon/1024.png --out "build/icon/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns build/icon/AppIcon.iconset -o assets/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/PortsApp" "$APP/Contents/MacOS/Ports"
cp "$BIN_PATH/ports" "$APP/Contents/MacOS/ports"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --sign - "$APP"

mkdir -p "$HOME/Applications"
if pgrep -x Ports >/dev/null 2>&1; then
  kill "$(pgrep -x Ports | head -n 1)"
fi
rm -rf "$HOME/Applications/Ports.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed $HOME/Applications/Ports.app"
