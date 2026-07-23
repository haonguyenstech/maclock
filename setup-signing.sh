#!/bin/bash
# One-time setup: create a STABLE self-signed code-signing identity for MacLock.
#
# Why: ad-hoc signing (`codesign --sign -`) pins the app's "designated requirement"
# to the binary's cdhash, which changes on every rebuild. macOS TCC keys the
# Accessibility grant to that requirement, so every update wipes the permission.
# A stable self-signed cert makes the requirement
#     identifier "vn.saigontechnology.maclock" and certificate leaf = H"<hash>"
# which never changes across rebuilds -> you grant Accessibility ONCE, forever.
#
# Run once:  ./setup-signing.sh    (macOS will ask you to unlock the keychain)
set -euo pipefail

CN="MacLock Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# NOTE: a self-signed cert is untrusted, so it never appears in
# `security find-identity -p codesigning` — but codesign can still sign with it
# by name, and the embedded leaf makes a STABLE designated requirement. So we
# check for the certificate directly, not via find-identity.
if security find-certificate -c "$CN" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "✅ Signing identity '$CN' already exists — nothing to do."
  exit 0
fi

echo "==> Creating self-signed code-signing certificate '$CN' …"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CN
[v3]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

# 10-year self-signed cert + key, with the codeSigning extended key usage.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export -legacy \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$CN" -out "$TMP/id.p12" -passout pass:maclock >/dev/null 2>&1

echo "==> Importing into your login keychain (allowing codesign to use it) …"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P maclock \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null

# Let codesign use the private key without a per-build GUI prompt.
# (Prompts once for your login/keychain password.)
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 \
  || echo "   (note: if codesign later asks for keychain access, click 'Always Allow')"

echo ""
echo "✅ Done. Certificate installed:"
security find-certificate -c "$CN" -Z "$KEYCHAIN" 2>/dev/null | grep -E 'SHA-1|"labl"' || true
echo ""
echo "Next: run ./build.sh — it will sign with '$CN' automatically."
echo "Then grant Accessibility ONE more time; it will persist across all future updates."
