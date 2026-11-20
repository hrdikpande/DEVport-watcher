#!/bin/zsh
# Builds Ports.app and installs it to ~/Applications. Run: ./build.sh
set -e
cd "$(dirname "$0")"
APP=build/Ports.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/Ports"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"            # ad-hoc signature so macOS will run it
mkdir -p ~/Applications
pkill -x Ports 2>/dev/null || true          # quit an old copy if it's running
rm -rf ~/Applications/Ports.app && cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Ports.app — double-click it to start."
