#!/bin/bash
set -euo pipefail

KEYCHAIN_NAME="hyperdock-signing"
KEYCHAIN="$HOME/Library/Keychains/${KEYCHAIN_NAME}.keychain-db"
KEYCHAIN_REF="${KEYCHAIN_NAME}.keychain"
PASSWORD="hyperdock-local"
IDENTITY="HyperDock Local Signing"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASELINE_AGENT="$(pgrep -x SecurityAgent | head -1 || true)"

guard() {
  local step="$1"
  sleep 0.4
  local now
  now="$(pgrep -x SecurityAgent | head -1 || true)"
  if [ -n "$now" ] && [ "$now" != "$BASELINE_AGENT" ]; then
    echo "!! A SecurityAgent prompt appeared during: $step"
    echo "!! Dismissing it and aborting so the screen does not lock up."
    kill -9 "$now" 2>/dev/null || true
    rollback
    exit 1
  fi
}

rollback() {
  echo "==> Rolling back"
  security delete-keychain "$KEYCHAIN_REF" 2>/dev/null || true
  security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
  echo "==> Rolled back. The build script will keep using ad-hoc signing."
}

echo "==> Removing any previous signing keychain"
security delete-keychain "$KEYCHAIN_REF" 2>/dev/null || true

echo "==> Creating dedicated keychain (login keychain untouched)"
security create-keychain -p "$PASSWORD" "$KEYCHAIN_REF"
guard "create-keychain"

security set-keychain-settings "$KEYCHAIN_REF"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN_REF"
guard "unlock-keychain"

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=$IDENTITY/O=HyperDock/C=US" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  2>/dev/null

export_p12() {
  openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY" -passout "pass:$PASSWORD" "$@" 2>"$WORK/p12err"
}

if ! export_p12 -legacy; then
  echo "    -legacy unavailable, falling back to explicit legacy algorithms"
  export_p12 -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES || {
    echo "!! Could not produce a PKCS#12 macOS will accept:"
    sed 's/^/     /' "$WORK/p12err"
    rollback
    exit 1
  }
fi

echo "==> Importing into the dedicated keychain"
security import "$WORK/identity.p12" -k "$KEYCHAIN_REF" -P "$PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null
guard "import"

echo "==> Pre-authorising codesign to use the private key"
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$PASSWORD" "$KEYCHAIN_REF" >/dev/null 2>&1
guard "set-key-partition-list"

echo "==> Adding the keychain to the search list"
security list-keychains -d user -s \
  "$HOME/Library/Keychains/login.keychain-db" "$KEYCHAIN"
guard "list-keychains"

echo "==> Verifying the identity is present"
if ! security find-identity "$KEYCHAIN_REF" | grep -q "$IDENTITY"; then
  echo "!! Identity not found in the keychain."
  rollback
  exit 1
fi

PROBE="$WORK/probe"
printf 'int main(void){return 0;}' > "$WORK/probe.c"
clang -o "$PROBE" "$WORK/probe.c" 2>/dev/null
if ! codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$PROBE" 2>"$WORK/err"; then
  echo "!! codesign failed:"
  sed 's/^/     /' "$WORK/err"
  rollback
  exit 1
fi
guard "codesign probe"

echo "==> Probe signed. Designated requirement:"
codesign -d -r- "$PROBE" 2>&1 | sed 's/^/     /'

echo
echo "==> Done. Identity ready: $IDENTITY"
echo "    Keychain: $KEYCHAIN"
echo
echo "    Rebuilds now keep the same designated requirement, so Accessibility and"
echo "    Screen Recording only have to be granted once."
