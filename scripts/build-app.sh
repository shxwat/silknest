#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swift build -c release
APP="$(pwd)/.build/SilkNest.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
rm -f "$APP/Contents/MacOS/WEBBER"
cp .build/release/WEBBER "$APP/Contents/MacOS/SilkNest"
strip -x "$APP/Contents/MacOS/SilkNest"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SilkNest</string>
<key>CFBundleDisplayName</key><string>SilkNest</string>
<key>CFBundleIdentifier</key><string>BUNDLE_ID</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleExecutable</key><string>SilkNest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>NSHumanReadableCopyright</key><string>© 2026 SilkNest</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# The version being built (VERSION file). Builds of an unreleased version are never replaced by the
# updater, which only installs versions newer than the running one.
VERSION="$(tr -d ' \n' < VERSION)"
# Official build (studio.webber.spider) only when it will be signed with the SilkNest certificate;
# every other build is a development build (app.silknest.dev): separate data, no auto-update.
IDENTITY="${SILKNEST_SIGN_IDENTITY:-SilkNest Signing}"
if [[ -z "${SILKNEST_DEV:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  BUNDLE_ID=studio.webber.spider; NAME="SilkNest"
else
  BUNDLE_ID=app.silknest.dev; NAME="SilkNest Dev"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleDisplayName $NAME" "$APP/Contents/Info.plist"
echo "bundle: $BUNDLE_ID" >&2
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
xattr -cr "$APP"
# Hardened runtime, signed with the SilkNest certificate when it is in the keychain (see scripts/sign.sh).
./scripts/sign.sh "$APP"
printf '%s\n' "$APP"
