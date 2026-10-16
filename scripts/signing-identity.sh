#!/bin/sh
# signing-identity.sh: create (once) the local self-signed code-signing identity "macrock Local".
#
# The launcher and its account service are signed with it. The service serves only a launcher
# signed with its own certificate, and the Keychain trusts the service by its designated
# requirement, which a fixed certificate keeps across builds; a new service build still asks for
# the login password once per account. The identity lives only in your login keychain; nothing
# leaves the Mac.
#
# Prints the identity name. The build settings sign with exactly this name.
set -eu
NAME="macrock Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  printf '%s\n' "$NAME"
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/signing.XXXXXX")
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
password=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$NAME" \
  -out "$work/identity.p12" -passout "pass:$password"
# -T: codesign may use the private key without asking each time.
security import "$work/identity.p12" -k "$KEYCHAIN" -P "$password" -T /usr/bin/codesign >/dev/null
printf '%s\n' "$NAME"
