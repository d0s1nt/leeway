#!/bin/zsh
# Builds a distributable zip in dist/.
#
#   ./release.sh
#   SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=llm-usage ./release.sh
#
# Without SIGN_ID the app is ad-hoc signed: it runs, but Gatekeeper makes people right-click > Open the first time.
# With SIGN_ID and NOTARY_PROFILE (a profile saved with `xcrun notarytool store-credentials`) the zip is
# notarized and stapled, and opens normally on any Mac.
set -e
cd "$(dirname "$0")"
[ -f .local.env ] && source ./.local.env
VERSION="$(cat VERSION)"
rm -rf dist && mkdir dist
# A release never carries a machine's private identifier: .local.env may supply SIGN_ID and NOTARY_PROFILE,
# but the bundle id is the public default unless RELEASE_BUNDLE_ID says otherwise.
export SIGN_ID
NO_LOCAL_ENV=1 BUNDLE_ID="${RELEASE_BUNDLE_ID:-app.llmusage.menubar}" APP="dist/LLM Usage.app" LAUNCH=0 ./build.sh
ZIP="dist/LLM-Usage-$VERSION.zip"
ditto -c -k --keepParent "dist/LLM Usage.app" "$ZIP"
if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "dist/LLM Usage.app"
  rm "$ZIP" && ditto -c -k --keepParent "dist/LLM Usage.app" "$ZIP"
fi
shasum -a 256 "$ZIP"
