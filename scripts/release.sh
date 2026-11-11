#!/bin/zsh
# Builds a release locally — nothing is uploaded or published:
#   dist/SilkNest-<version>.zip      what the updater and install.sh download
#   dist/SilkNest-<version>.dmg      drag-to-Applications disk image (GitHub Releases, website, Homebrew)
#   dist/SHA256SUMS
#   dist/version.json                signed update feed (Ed25519 release key)
#   dist/install.sh                  the curl installer pointing at this zip and its SHA-256
# Publishing is scripts/deploy-site.sh (website + feed) and the steps in RELEASING.md.
#
# Release key: SILKNEST_UPDATE_KEY (path to the 32-byte Ed25519 key), default ~/.silknest/update-signing.key.
# It must live outside this repository; the script refuses a key inside it.
#
# Signing:
#   default            the self-signed "SilkNest Signing" certificate (scripts/create-signing-cert.sh) +
#                      hardened runtime. Required: installed SilkNest builds signed with it accept only
#                      updates signed with it. ALLOW_ADHOC=1 releases ad-hoc anyway (never for a real release).
#   DEVELOPER_ID=...   "Developer ID Application: Name (TEAMID)" → signed with a secure timestamp
#   NOTARY_PROFILE=... notarytool keychain profile → notarized and stapled (no Gatekeeper warning)
set -euo pipefail
cd "${0:A:h}/.."
VERSION="${1:-$(tr -d ' \n' < VERSION)}"
KEY="${SILKNEST_UPDATE_KEY:-$HOME/.silknest/update-signing.key}"
[[ -f "$KEY" ]] || { echo "Missing the release key at $KEY (set SILKNEST_UPDATE_KEY)" >&2; exit 1; }
case "${KEY:A}" in "${PWD:A}"/*) echo "Refusing a release key inside the repository: $KEY" >&2; exit 1;; esac
./scripts/test-motion.sh
./scripts/build-app.sh >/dev/null
# Sign and package outside this folder: iCloud/File Provider sync adds Finder metadata to bundles in
# Documents, which breaks a strict signature check after download.
WORK="$(mktemp -d /tmp/silknest-release.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
ditto --norsrc --noextattr --noacl .build/SilkNest.app "$WORK/SilkNest.app"
APP="$WORK/SilkNest.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
xattr -cr "$APP"
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
  ./scripts/sign.sh "$APP"
  if ! codesign -d -r- "$APP" 2>&1 | grep -q 'identifier "studio.webber.spider" and certificate' && [[ -z "${ALLOW_ADHOC:-}" ]]; then
    echo "Refusing to release an ad-hoc build: create the certificate with scripts/create-signing-cert.sh" >&2; exit 1
  fi
fi
codesign --verify --deep --strict "$APP"
spctl --assess --type execute "$APP" 2>/dev/null && echo "Gatekeeper: accepted" || echo "Gatekeeper: needs Open Anyway (not notarized)"
rm -rf dist; mkdir -p dist
DMG="dist/SilkNest-$VERSION.dmg"
DMGBUILD="${DMGBUILD:-dmgbuild}"
if command -v "$DMGBUILD" >/dev/null; then
  "$DMGBUILD" -s scripts/dmg-settings.py -D app="$APP" -D root="$(pwd)" "SilkNest" "$DMG" >/dev/null
else
  mkdir -p dist/stage; ditto "$APP" dist/stage/SilkNest.app; ln -s /Applications dist/stage/Applications
  hdiutil create -quiet -volname "SilkNest" -srcfolder dist/stage -ov -format UDZO "$DMG"; rm -rf dist/stage
fi
# Only a Developer ID signature goes on the disk image: macOS refuses to open an ad-hoc signed DMG
# that was downloaded, while an unsigned one opens normally (the app inside stays signed).
if [[ -n "${DEVELOPER_ID:-}" ]]; then codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"; fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
hdiutil verify -quiet "$DMG"
# The app as a user receives it must still pass a strict signature check.
MNT="$WORK/mnt"; mkdir -p "$MNT"; hdiutil attach -nobrowse -quiet -mountpoint "$MNT" "$DMG"
codesign --verify --deep --strict "$MNT/SilkNest.app" && echo "Signature inside DMG: valid"
hdiutil detach -quiet "$MNT"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "dist/SilkNest-$VERSION.zip"
(cd dist && shasum -a 256 SilkNest-$VERSION.dmg SilkNest-$VERSION.zip > SHA256SUMS)
# Signed update feed: installed copies update only if this signature verifies with their built-in key.
SHA=$(shasum -a 256 "dist/SilkNest-$VERSION.zip" | cut -c1-64)
SIG=$(swift scripts/update-key.swift sign "$KEY" "$VERSION|$SHA")
printf '{"version":"%s","url":"https://silknest.app/SilkNest-%s.zip","sha256":"%s","signature":"%s"}\n' "$VERSION" "$VERSION" "$SHA" "$SIG" > dist/version.json
PUB=$(swift scripts/update-key.swift public "$KEY")
grep -q "$PUB" Sources/WEBBER/App/Updater.swift || { echo "The release key does not match the app's built-in public key" >&2; exit 1; }
# The curl installer for this release.
# (The installer template lives with the website, outside the public repository.)
if [[ -f website/public/install.sh ]]; then
  sed -E "s/^VERSION=\"[^\"]*\"/VERSION=\"$VERSION\"/; s/^SHA256=\"[0-9a-f]*\"/SHA256=\"$SHA\"/" website/public/install.sh > dist/install.sh
fi
ls -lh dist; cat dist/SHA256SUMS
echo "Signed feed: dist/version.json — nothing has been published. Next: RELEASING.md"
