#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Ports.app"
fail() { echo "build_app.sh: $*" >&2; exit 1; }
# macOS 14+ needs no Swift back-deployment shims; skipping them also avoids CommandLineTools' arm64-only
# libswiftCompatibility56.a breaking the x86_64 link of swift-argument-parser.
ARCHS=(--arch arm64 --arch x86_64 -Xswiftc -runtime-compatibility-version -Xswiftc none)

swift build -c release "${ARCHS[@]}"
BIN_PATH="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

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

# The CLI lives in Contents/Helpers: on case-insensitive APFS, MacOS/ports would overwrite MacOS/Ports.
APP_BIN="$APP/Contents/MacOS/Ports"
CLI_BIN="$APP/Contents/Helpers/ports"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_PATH/PortsApp" "$APP_BIN"
cp "$BIN_PATH/ports" "$CLI_BIN"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Localizable.xcstrings -> <lang>.lproj/Localizable.strings (CommandLineTools ship no xcstringstool).
python3 - "$APP/Contents/Resources" <<'PY2'
import json, os, sys
cat = json.load(open("Localization/Localizable.xcstrings"))
out = {}
for key, entry in cat["strings"].items():
    for lang, loc in entry.get("localizations", {}).items():
        out.setdefault(lang, {})[key] = loc["stringUnit"]["value"]
def esc(t): return t.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
for lang, strings in out.items():
    d = os.path.join(sys.argv[1], lang + ".lproj"); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
        for k in sorted(strings): f.write('"%s" = "%s";\n' % (esc(k), esc(strings[k])))
PY2
[[ -s "$APP/Contents/Resources/en.lproj/Localizable.strings" ]] || fail "no en.lproj/Localizable.strings"

for bin in "$APP_BIN" "$CLI_BIN"; do [[ -f "$bin" ]] || fail "missing $bin"; done
cmp -s "$APP_BIN" "$CLI_BIN" && fail "$APP_BIN and $CLI_BIN are identical (one overwrote the other)"
otool -L "$APP_BIN" | grep -q AppKit || fail "$APP_BIN does not link AppKit (is it the CLI?)"

codesign --force --options runtime --sign - "$CLI_BIN"       # nested code is signed before the bundle
codesign --force --options runtime --sign - "$APP"
codesign --verify --strict "$APP"

for bin in "$APP_BIN" "$CLI_BIN"; do
  archs="$(lipo -archs "$bin")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "not universal: $bin ($archs)"
  codesign --verify --strict "$bin" || fail "bad signature: $bin"
done
echo "Built universal $APP (app + Contents/Helpers/ports)"

if [[ -n "${CI:-}" || "${1:-}" == "--no-install" ]]; then
  exit 0
fi

mkdir -p "$HOME/Applications"
if pgrep -x Ports >/dev/null 2>&1; then
  kill "$(pgrep -x Ports | head -n 1)"
fi
rm -rf "$HOME/Applications/Ports.app"
cp -R "$APP" "$HOME/Applications/"
echo "Installed $HOME/Applications/Ports.app"
