#!/usr/bin/env bash
# Creates the self-signed certificate the release workflow signs with, and stores it as GitHub secrets.
# Run it once: every release must use the same certificate, or upgrades reset the permissions macOS granted.
set -euo pipefail

readonly NAME="Tickler Release Signing"
readonly REPO="${1:?usage: $0 <owner/repo>}"

command -v gh > /dev/null || { echo "gh is required" >&2; exit 1; }
if gh secret list --repo "${REPO}" | grep -q '^RELEASE_SIGNING_P12'; then
    echo "RELEASE_SIGNING_P12 already exists on ${REPO}: replacing it would reset users' permissions on upgrade." >&2
    exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
password="$(openssl rand -base64 24)"

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
    -keyout "${workdir}/key.pem" -out "${workdir}/cert.pem" -subj "/CN=${NAME}" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2> /dev/null
/usr/bin/openssl pkcs12 -export -inkey "${workdir}/key.pem" -in "${workdir}/cert.pem" \
    -out "${workdir}/identity.p12" -passout "pass:${password}"

base64 < "${workdir}/identity.p12" | gh secret set RELEASE_SIGNING_P12 --repo "${REPO}"
printf '%s' "${password}" | gh secret set RELEASE_SIGNING_PASSWORD --repo "${REPO}"
echo "Stored RELEASE_SIGNING_P12 and RELEASE_SIGNING_PASSWORD on ${REPO}."
echo "Keep a backup of the certificate (e.g. in your password manager): it cannot be recovered from GitHub."
openssl x509 -in "${workdir}/cert.pem" -noout -fingerprint -sha256
