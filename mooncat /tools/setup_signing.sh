#!/bin/bash
# One-time setup: creates a self-signed "MoonCat Dev" code-signing identity in your login
# keychain, so every build of MoonCat has the same signature and Keychain "Always Allow"
# sticks. Run it once, then use ./build.sh as usual.
set -e
NAME="${1:-MoonCat Dev}"
KC="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:mooncat 2>/dev/null

echo "Importing the identity into your login keychain (macOS may ask for your password)..."
security import "$TMP/id.p12" -k "$KC" -P mooncat -T /usr/bin/codesign
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KC" "$TMP/cert.pem" || true

echo
security find-identity -p codesigning | grep "$NAME" || {
  echo "Could not find the identity. Create it by hand instead:"
  echo "Keychain Access > Certificate Assistant > Create a Certificate >"
  echo "name \"$NAME\", Identity Type: Self Signed Root, Certificate Type: Code Signing."
  exit 1
}
echo "Done. Now run ./build.sh"
