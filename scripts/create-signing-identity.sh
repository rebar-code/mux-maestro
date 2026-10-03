#!/usr/bin/env bash
# Create the local, self-signed code-signing identity that `make app` uses.
#
# Why this exists: an ad-hoc signed app has a designated requirement of
# `cdhash H"..."` and nothing else, so macOS treats every rebuild as a different
# app. Every TCC grant — App Data ("MuxMaestro.app would like to access data
# from other apps"), Automation, Documents, Photos — is asked again after each
# build, and System Settings collects another MuxMaestro row each time. Signing
# with a stable certificate makes the requirement
# `identifier "is.rebar.MuxMaestro" and certificate leaf = H"<cert>"`, which
# survives rebuilds, so a grant given once stays given.
#
# The certificate is self-signed and trusted on this Mac only. It is NOT a
# Developer ID: it does not notarize and does not make the app distributable.
#
# Run once. macOS asks for your login password to store the trust setting.
set -euo pipefail

NAME="${1:-MuxMaestro-Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Apple's LibreSSL, not whatever is first on PATH. Homebrew's OpenSSL 3 writes
# PKCS#12 with AES-256 and a SHA-256 MAC, which Security.framework cannot read:
# `security import` fails with "MAC verification failed during PKCS12 import".
OPENSSL=/usr/bin/openssl

if security find-identity -v -p codesigning | grep -q "$NAME"; then
	echo "Identity '$NAME' already exists — nothing to do."
	exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints     = critical, CA:false
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/openssl.cnf" 2>/dev/null

# The transport password protects the key only while it sits in $tmp, which this
# script deletes on exit.
pw="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
	-name "$NAME" -passout "pass:$pw" -out "$tmp/identity.p12"

# -T /usr/bin/codesign lets codesign use the key. The first build still shows one
# keychain dialog — choose "Always Allow".
security import "$tmp/identity.p12" -k "$KEYCHAIN" -P "$pw" -T /usr/bin/codesign

# Trust the certificate for code signing. User trust only, not the system store.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"

if ! security find-identity -v -p codesigning | grep "$NAME"; then
	echo "Imported, but codesign cannot see '$NAME'." >&2
	exit 1
fi

echo
echo "Done. 'make app' now signs with '$NAME'."
echo "The next build shows one keychain dialog — choose \"Always Allow\"."
