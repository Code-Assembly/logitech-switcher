#!/bin/bash
set -euo pipefail

NAME="${LOGITECH_SIGN_IDENTITY:-logitech-switcher-dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\""; then
    echo "identity '$NAME' already in login keychain"
    exit 0
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

cat > "$dir/openssl.cnf" <<CNF
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
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" -config "$dir/openssl.cnf"
/usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -out "$dir/id.p12" -passout pass:logi

security import "$dir/id.p12" -k "$KEYCHAIN" -P logi -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$dir/cert.pem"

security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
