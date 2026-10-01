#!/usr/bin/env bash
# Creates a self-signed code signing identity in the login keychain, once. Signed with it, Tickler keeps its
# privacy permissions (Calendar, Automation) across rebuilds: macOS ties them to the certificate, not the build.
set -euo pipefail

readonly NAME="Tickler Local Signing"
readonly KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"${NAME}\""; then
    echo "${NAME} already exists"
    exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
password="$(uuidgen)"

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "${workdir}/key.pem" -out "${workdir}/cert.pem" -subj "/CN=${NAME}" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2> /dev/null
/usr/bin/openssl pkcs12 -export -inkey "${workdir}/key.pem" -in "${workdir}/cert.pem" \
    -out "${workdir}/identity.p12" -passout "pass:${password}"

security import "${workdir}/identity.p12" -k "${KEYCHAIN}" -P "${password}" -T /usr/bin/codesign
# Asks for your password: the certificate must be trusted for code signing.
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${workdir}/cert.pem"

security find-identity -v -p codesigning | grep "\"${NAME}\""
echo "Done. Rebuild with: make dev"
