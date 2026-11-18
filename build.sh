#!/bin/zsh
# Builds "LLM Usage.app" and (re)launches it.
#
#   ./build.sh                      build into ~/Applications and launch
#   APP="dist/LLM Usage.app" LAUNCH=0 ./build.sh     build elsewhere, don't launch (see release.sh)
#
# Optional settings, from the environment or a git-ignored .local.env file next to this script:
#   BUNDLE_ID   bundle identifier; also the defaults domain and the launchd label   (default app.llmusage.menubar)
#   SIGN_ID     codesign identity, e.g. "Developer ID Application: Name (TEAMID)"    (default "-", ad-hoc)
set -e
cd "$(dirname "$0")"
[ -f .local.env ] && [ -z "$NO_LOCAL_ENV" ] && source ./.local.env
BUNDLE_ID="${BUNDLE_ID:-app.llmusage.menubar}"
SIGN_ID="${SIGN_ID:--}"
APP="${APP:-$HOME/Applications/LLM Usage.app}"
LAUNCH="${LAUNCH:-1}"
VERSION="$(cat VERSION)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
rm -rf "$APP/Contents/Resources/icons" "$APP/Contents/Library"
xattr -cr "$APP" 2>/dev/null || true
cp -R icons "$APP/Contents/Resources/icons"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Universal binary: Apple Silicon and Intel, macOS 13+.
TMP="$(mktemp -d)"
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" LLMUsage.swift -o "$TMP/LLMUsage-$arch" -framework AppKit
done
lipo -create "$TMP/LLMUsage-arm64" "$TMP/LLMUsage-x86_64" -output "$APP/Contents/MacOS/LLMUsage"
rm -rf "$TMP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LLM Usage</string>
  <key>CFBundleDisplayName</key><string>LLM Usage</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>LLMUsage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Cynaptix. MIT licence.</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
else
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
fi
echo "Built: $APP ($BUNDLE_ID $VERSION)"
[ "$LAUNCH" = "1" ] || exit 0

pkill -x LLMUsage 2>/dev/null || true
sleep 1
# With "Launch at Login" on, restart through launchd so the running copy is the keep-alive-managed one.
if [ -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist" ] && launchctl print "gui/$(id -u)/$BUNDLE_ID" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$BUNDLE_ID"
else
  open "$APP"
fi
echo "Launched."
