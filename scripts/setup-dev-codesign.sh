#!/usr/bin/env bash
# Prefer a stable code-signing identity so Screen Recording TCC survives rebuilds.
#
# Recommended (you already had one): renew "Apple Development" in Xcode (free Apple ID).
# Optional: local self-signed cert + trust it in Keychain Access (more fiddly on Sequoia).
set -euo pipefail

CERT_NAME="${CODESIGN_IDENTITY_NAME:-Video Editor Wails Dev}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
OPENSSL="${OPENSSL:-/usr/bin/openssl}"

echo "Current code-signing identities:"
security find-identity -p codesigning 2>/dev/null || true
echo

if security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development:|Developer ID Application:' >/dev/null; then
  echo "A valid Apple/Developer signing identity is already available. Nothing to do."
  echo "Rebuild with: wails3 package"
  exit 0
fi

if security find-identity -p codesigning 2>/dev/null | grep -F 'Apple Development:' | grep -q CERT_EXPIRED; then
  cat <<EOF
Your Apple Development certificate is EXPIRED. Renew it once (free):

  1. Open Xcode → Settings… → Accounts
  2. Select your Apple ID → Manage Certificates…
  3. Click + → Apple Development
  4. Then: wails3 package
  5. Authorize Screen Recording once for bin/video-editor-wails.app

After that, rebuilds keep the same Team ID and usually do NOT need re-authorization.
EOF
  exit 0
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$CERT_NAME\"" >/dev/null; then
  echo "Local identity already valid: $CERT_NAME"
  exit 0
fi

echo "No valid Apple Development identity found. Creating local cert: $CERT_NAME"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = exts
[dn]
CN = ${CERT_NAME}
O = Video Editor Wails Local Dev
[exts]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

"$OPENSSL" req -new -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/csr.pem" -config "$TMP/cert.cnf" >/dev/null
"$OPENSSL" x509 -req -in "$TMP/csr.pem" -signkey "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -extfile "$TMP/cert.cnf" -extensions exts >/dev/null
"$OPENSSL" pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout pass:wailsdev -name "$CERT_NAME" >/dev/null

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P wailsdev -A \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

cat <<EOF

Certificate imported, but macOS marks self-signed certs as "not trusted" until you:

  1. Open Keychain Access
  2. Find "$CERT_NAME" under login → Certificates
  3. Double-click → Trust → Code Signing → Allow / Always Trust
  4. Close the window (may ask for password)
  5. Run: security find-identity -v -p codesigning
     (should list "$CERT_NAME" under Valid identities)
  6. wails3 package

Prefer renewing Apple Development in Xcode if you can — fewer trust steps.
EOF
