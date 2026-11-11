#!/bin/zsh
# Development check for the signing transition, with throwaway certificates in a temporary keychain
# (never the login keychain; everything is deleted at the end):
#   - 1.2.2's update check (bundle identifier only) accepts a certificate-signed build   → transition works
#   - a certificate-signed build's own requirement accepts the next build from the same certificate,
#     and rejects an ad-hoc build or a build from another certificate                    → no downgrade
#   - an ad-hoc build of this version (identifier-only requirement) also accepts the first certificate build
set -euo pipefail
cd "${0:A:h}/.."
[[ -d .build/SilkNest.app ]] || ./scripts/build-app.sh >/dev/null
TMP="$(mktemp -d)"; chmod 700 "$TMP"
KC="$TMP/test.keychain-db"; PW="$(/usr/bin/openssl rand -hex 12)"
ORIG_LIST=("${(@f)$(security list-keychains -d user | sed 's/^ *"//; s/"$//')}")
cleanup() { security list-keychains -d user -s "${ORIG_LIST[@]}" 2>/dev/null; security delete-keychain "$KC" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
security create-keychain -p "$PW" "$KC"; security set-keychain-settings "$KC"; security unlock-keychain -p "$PW" "$KC"
security list-keychains -d user -s "$KC" "${ORIG_LIST[@]}"
make_cert() {   # name
  cat > "$TMP/$1.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $1
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$TMP/$1.key" -out "$TMP/$1.pem" -config "$TMP/$1.cnf" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/$1.key" -in "$TMP/$1.pem" -name "$1" -out "$TMP/$1.p12" -passout pass:x 2>/dev/null
  security import "$TMP/$1.p12" -k "$KC" -P x -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null 2>&1
}
make_cert "SilkNest Test A"; make_cert "SilkNest Test B"
copy() { ditto --norsrc --noextattr .build/SilkNest.app "$TMP/$1.app"; }
copy adhoc; copy a1; copy a2; copy b
SILKNEST_SIGN_IDENTITY="no such identity" ./scripts/sign.sh "$TMP/adhoc.app" 2>/dev/null
for v in a1 a2; do codesign --force --options runtime --timestamp=none --keychain "$KC" --sign "SilkNest Test A" "$TMP/$v.app" 2>/dev/null; done
codesign --force --options runtime --timestamp=none --keychain "$KC" --sign "SilkNest Test B" "$TMP/b.app" 2>/dev/null

fails=0
accepts() {  # description requirement app expected(yes/no)
  if codesign --verify --deep --strict -R="$2" "$TMP/$3.app" 2>/dev/null; then got=yes; else got=no; fi
  if [[ $got == $4 ]]; then echo "ok   $1"; else echo "FAIL $1 (expected $4, got $got)"; fails=$((fails+1)); fi
}
dr() { codesign -d -r- "$TMP/$1.app" 2>&1 | sed -n 's/^designated => //p'; }
OLD='identifier "studio.webber.spider"'            # 1.2.2's Updater requirement
accepts "1.2.2 accepts the first certificate-signed update" "$OLD" a1 yes
accepts "ad-hoc build of this version accepts it too" "$(dr adhoc)" a1 yes
accepts "certificate build accepts the next build from the same certificate" "$(dr a1)" a2 yes
accepts "certificate build rejects an ad-hoc build" "$(dr a1)" adhoc no
accepts "certificate build rejects another certificate" "$(dr a1)" b no
if [[ "$(dr a1)" == "$(dr a2)" ]]; then echo "ok   two builds from the same certificate have the same requirement (1.3.0 → 1.3.1)"
else echo "FAIL requirement changed between builds"; fails=$((fails+1)); fi
echo "designated requirement (certificate build): $(dr a1)"
echo "$fails signing failures"; exit $fails
