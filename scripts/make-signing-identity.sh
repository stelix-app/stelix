#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Gabriele Carsana. See the NOTICE file for the additional terms.
# Creates the local signing identity "Stelix Local Signing" in the login keychain.
# Idempotent: if it already exists, it exits without touching anything.
# STELIX_SIGNING_DRY_RUN=1: generates and checks key, certificate and .p12 in a
# temporary folder, then stops before the keychain (imports nothing).
set -euo pipefail

NAME="Stelix Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if [ -x /opt/homebrew/bin/openssl ]; then
  OPENSSL=/opt/homebrew/bin/openssl
else
  OPENSSL=openssl
fi

if [ -z "${STELIX_SIGNING_DRY_RUN:-}" ] \
  && security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "The identity \"$NAME\" already exists: nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
P12_PASS="$("$OPENSSL" rand -hex 16)"

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

# Old algorithms (3DES/SHA1): `security`'s import does not read OpenSSL 3's AES .p12 files.
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/stelix.p12" -passout "pass:$P12_PASS" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

if [ -n "${STELIX_SIGNING_DRY_RUN:-}" ]; then
  "$OPENSSL" x509 -in "$WORK/cert.pem" -text -noout
  "$OPENSSL" pkcs12 -in "$WORK/stelix.p12" -passin "pass:$P12_PASS" -info -noout 2>&1 | head -5
  echo "DRY RUN: keychain untouched."
  exit 0
fi

security import "$WORK/stelix.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
# Asks for the login/administrator password.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "Done. Verify with: security find-identity -v -p codesigning"
