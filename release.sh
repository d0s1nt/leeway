#!/bin/zsh
# Builds distributable archives in dist/: a .dmg (drag to Applications), a .zip, and SHA256SUMS.txt.
#
#   ./release.sh
#   SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=llm-usage ./release.sh
#
# Without SIGN_ID the app is ad-hoc signed: it runs, but macOS makes people right-click > Open the first time.
# With SIGN_ID and NOTARY_PROFILE (saved once with `xcrun notarytool store-credentials`) the app and the disk image
# are notarized and stapled, and open normally on any Mac. CI (.github/workflows/release.yml) runs this on a tag.
set -e
cd "$(dirname "$0")"
[ -f .local.env ] && source ./.local.env
VERSION="$(cat VERSION)"
SIGN_ID="${SIGN_ID:--}"
APP="dist/LLM Usage.app"
ZIP="dist/LLM-Usage-$VERSION.zip"
DMG="dist/LLM-Usage-$VERSION.dmg"
rm -rf dist && mkdir dist

# A release never carries a machine's private identifier: .local.env may supply SIGN_ID and NOTARY_PROFILE,
# but the bundle id is the public default unless RELEASE_BUNDLE_ID says otherwise.
export SIGN_ID
NO_LOCAL_ENV=1 BUNDLE_ID="${RELEASE_BUNDLE_ID:-app.llmusage.menubar}" APP="$APP" LAUNCH=0 ./build.sh
"$APP/Contents/MacOS/LLMUsage" --selftest

# No extended attributes or resource forks in an archive: nothing from the build machine travels with it.
pack_zip() { rm -f "$ZIP"; ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"; }
pack_zip
if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_ID" != "-" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  pack_zip
fi

STAGE="$(mktemp -d)"
ditto --norsrc --noextattr "$APP" "$STAGE/LLM Usage.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "LLM Usage $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
if [ "$SIGN_ID" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

./check-secrets.sh
(cd dist && shasum -a 256 LLM-Usage-$VERSION.dmg LLM-Usage-$VERSION.zip > SHA256SUMS.txt && cat SHA256SUMS.txt)
