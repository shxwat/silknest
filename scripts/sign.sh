#!/bin/zsh
# Signs a built SilkNest.app. With the "SilkNest Signing" certificate in the login keychain (create it once
# with scripts/create-signing-cert.sh) every build carries the same designated requirement, so macOS keeps
# Accessibility for SilkNest across updates and the updater accepts only builds from that certificate.
# Without it, an ad-hoc signature is used (local development only; see release.sh).
#   scripts/sign.sh path/to/SilkNest.app
set -euo pipefail
APP="$1"
IDENTITY="${SILKNEST_SIGN_IDENTITY:-SilkNest Signing}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")"
if [[ "$BUNDLE_ID" == studio.webber.spider ]] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
  echo "signed: $IDENTITY" >&2
else
  # Designated requirement by bundle identifier (not the per-build hash).
  codesign --force --options runtime --timestamp=none --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
  echo "signed: ad-hoc ($BUNDLE_ID)" >&2
fi
