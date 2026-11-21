#!/bin/zsh
# Release build: universal app → Developer ID signature → notarization → staple → zip + DMG + SHA-256.
#
#   VERSION=1.2.0 ./Scripts/release.sh
#
# Signing and notarization happen only when their secrets are present; otherwise it still builds everything
# and produces a clearly labelled UNSIGNED build (it never fails for missing secrets):
#   DEVELOPER_ID_APPLICATION   "Developer ID Application: Name (TEAMID)", an identity in the keychain
#   NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH   App Store Connect API key for `xcrun notarytool`
#     (or NOTARY_PROFILE: a keychain profile made with `xcrun notarytool store-credentials`)
#
# Output: dist/Ports-<version>[-unsigned].zip, .dmg, and SHA256SUMS.txt; dist/release-notes.md says how it was signed.
# Never installs anything and never touches running apps.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "release.sh: bad VERSION '$VERSION'" >&2; exit 64; }
export VERSION

signed=0 notarized=0
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]] && security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID_APPLICATION"; then
  signed=1
else
  unset DEVELOPER_ID_APPLICATION DEVELOPER_ID
  echo "release.sh: no Developer ID identity: building UNSIGNED (ad-hoc) artefacts"
fi

./Scripts/build_app.sh --no-install
APP=build/Ports.app
NAME="Ports-$VERSION"
(( signed )) || NAME="$NAME-unsigned"
mkdir -p dist
ZIP="dist/$NAME.zip" DMG="dist/$NAME.dmg"
[[ -e "$ZIP" ]] && mv -f "$ZIP" "$ZIP.old"
[[ -e "$DMG" ]] && mv -f "$DMG" "$DMG.old"

notary() {   # notary <file>: submit and wait; 0 on Accepted
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
  fi
}
can_notarize() { [[ -n "${NOTARY_PROFILE:-}" ]] || [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" && -f "${NOTARY_KEY_PATH:-/nonexistent}" ]]; }

ditto -c -k --keepParent "$APP" "$ZIP"
if (( signed )) && can_notarize; then
  notary "$ZIP" && xcrun stapler staple "$APP" && notarized=1
  if (( notarized )); then ditto -c -k --keepParent "$APP" "$ZIP.tmp" && mv -f "$ZIP.tmp" "$ZIP"; fi
elif (( signed )); then
  echo "release.sh: signed, but no notarization credentials: not notarized"
fi

STAGE=$(mktemp -d -t ports-dmg)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Ports $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
if (( signed )); then codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG"; fi
if (( notarized )); then notary "$DMG" && xcrun stapler staple "$DMG"; fi
[[ -d "$STAGE" && "$STAGE" == */ports-dmg* ]] && rm -rf -- "$STAGE"

(cd dist && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt)
{
  echo "## Ports $VERSION"
  echo
  if (( notarized )); then echo "Signed with Developer ID and notarized by Apple."
  elif (( signed )); then echo "Signed with Developer ID, **not notarized**: macOS may ask before the first launch."
  else
    echo "**Unsigned build** (ad-hoc signature). macOS Gatekeeper blocks it on first launch: right-click Ports.app → Open,"
    echo "or run \`xattr -dr com.apple.quarantine /Applications/Ports.app\` after checking the SHA-256 below."
  fi
  echo
  echo '```'
  cat dist/SHA256SUMS.txt
  echo '```'
} > dist/release-notes.md
rm -f "$ZIP.old" "$DMG.old"
echo "release.sh: $NAME (signed=$signed notarized=$notarized)"
ls -1 dist
