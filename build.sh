#!/bin/zsh
# Builds Ports.app and installs it to ~/Applications. Run: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Ports.app

# App icon (generated once from an SF Symbol; delete assets/AppIcon.icns to regenerate)
if [[ ! -f assets/AppIcon.icns ]]; then
  mkdir -p build/icon/AppIcon.iconset
  swiftc -O tools/icon.swift -o build/icon/gen && build/icon/gen build/icon/1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon/1024.png --out build/icon/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon/1024.png --out build/icon/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/icon/AppIcon.iconset -o assets/AppIcon.icns
fi

rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/Ports"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature with the hardened runtime (blocks code injection / dylib hijacking).
codesign --force --options runtime --sign - "$APP"

mkdir -p ~/Applications
pkill -x Ports 2>/dev/null || true
rm -rf ~/Applications/Ports.app && cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Ports.app — double-click it to start."
