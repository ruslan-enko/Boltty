#!/bin/zsh
set -euo pipefail

identity="Boltty Development"
keychain="${HOME}/Library/Keychains/login.keychain-db"
local_config="${0:A:h}/../Config/Signing.local.xcconfig"

# Debug builds sign with the identity too (Config/Signing.xcconfig), so every
# build on this Mac carries the release's designated requirement and keeps
# its privacy grants. Written whether the identity is new or not.
write_local_config() {
  print "// Written by scripts/setup-local-signing.sh: this Mac signs Debug builds\n// with its own identity. Not committed.\nBOLTTY_LOCAL_SIGN_IDENTITY = ${identity}" > "$local_config"
  print "Debug builds now sign with ${identity} (Config/Signing.local.xcconfig)"
}

if security find-identity -v -p codesigning "$keychain" | grep -Fq '"Boltty Development"'; then
  print "Boltty Development identity already exists"
  write_local_config
  exit 0
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/boltty-signing.XXXXXX")"
password="$(openssl rand -hex 24)"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
  -keyout "$work_dir/key.pem" \
  -out "$work_dir/cert.pem" \
  -days 3650 \
  -subj "/CN=${identity}/O=Boltty Local Development" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=codeSigning"

openssl pkcs12 -export \
  -legacy \
  -inkey "$work_dir/key.pem" \
  -in "$work_dir/cert.pem" \
  -out "$work_dir/identity.p12" \
  -passout "pass:$password"

security import "$work_dir/identity.p12" \
  -k "$keychain" \
  -P "$password" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

security add-trusted-cert \
  -d \
  -r trustRoot \
  -p codeSign \
  -k "$keychain" \
  "$work_dir/cert.pem"

security find-identity -v -p codesigning "$keychain" | grep -Fq '"Boltty Development"' || {
  print -u2 "Boltty signing setup failed: imported identity is not valid for code signing"
  exit 1
}

print "Boltty Development identity created in the login keychain"
write_local_config
