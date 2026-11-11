#!/bin/zsh
# One-time: creates the self-signed "SilkNest Signing" code-signing certificate in YOUR login keychain.
# Run it yourself in Terminal (macOS asks for your login password to trust the certificate for code
# signing). The private key is generated in a private temporary folder outside the repo, imported into
# the login keychain, and the temporary files are deleted. Nothing is written to the repo.
#
# Keep this certificate forever and back it up (Keychain Access → My Certificates → SilkNest Signing →
# Export, store the .p12 somewhere safe and offline). SilkNest builds signed with it only accept updates
# signed with the same certificate: if it is lost, users would have to reinstall by hand.
set -euo pipefail
NAME="${1:-SilkNest Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "A certificate named \"$NAME\" is already in the login keychain. Nothing to do."; exit 0
fi
TMP="$(mktemp -d)"; chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
# /usr/bin/openssl (LibreSSL) writes a .p12 that `security import` understands.
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Imported \"$NAME\". macOS will now ask for your password to trust it for code signing…"
security add-trusted-cert -r trustAsRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
echo
security find-identity -p codesigning -v | grep "$NAME" && echo "Done: builds are now signed with \"$NAME\"."
echo "Back it up: Keychain Access → login → My Certificates → $NAME → File → Export Items… (.p12)."
