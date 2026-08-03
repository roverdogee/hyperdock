#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
APP_NAME="HyperDock"
NOTARY_PROFILE="${NOTARY_PROFILE:-HyperDockNotary}"
STAGE=""

cleanup() {
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
    rm -rf -- "$STAGE"
  fi
}
trap cleanup EXIT

VERSION=$(grep 'MARKETING_VERSION:' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
DMG="$DIST/$APP_NAME.dmg"

echo "==> Building Release $VERSION"
CONFIG=Release "$ROOT/scripts/build.sh" >/dev/null
APP="/Applications/$APP_NAME.app"
[ -d "$APP" ] || { echo "==> Build did not produce $APP"; exit 1; }

if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow"; then
  echo "==> REFUSING: the bundle carries get-task-allow."
  echo "    CODE_SIGN_INJECT_BASE_ENTITLEMENTS must be NO for Release in project.yml."
  exit 1
fi

if find "$APP/Contents/MacOS" -maxdepth 1 -type f \
    \( -name '*.debug.dylib' -o -name '__preview.dylib' \) | grep -q .; then
  echo "==> REFUSING: the Release bundle carries Xcode debug/preview dylibs."
  exit 1
fi

echo "==> Re-signing for distribution"
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)

if [ -n "$DEV_ID" ]; then
  echo "    identity: $DEV_ID"
  codesign --force --deep --timestamp --options runtime \
    --sign "$DEV_ID" \
    --entitlements Sources/HyperDock/Resources/HyperDock.entitlements \
    "$APP"
  DISTRIBUTABLE=yes
else
  echo "    No 'Developer ID Application' certificate found — keeping the local signature."
  echo "    That is fine for your own machines. Gatekeeper only stops a file that carries"
  echo "    a quarantine flag, which is stamped by browsers and AirDrop but not by a USB"
  echo "    copy, scp or rsync. If a copy does end up quarantined, clear it with:"
  echo "        xattr -d com.apple.quarantine /path/to/HyperDock.dmg"
  DISTRIBUTABLE=no
fi

echo "==> Building the disk image"
mkdir -p "$DIST"
rm -f "$DMG"
STAGE=$(mktemp -d)
/usr/bin/ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -quiet \
  "$DMG"
echo "==> Packaged $DMG"

if [ "$DISTRIBUTABLE" = "yes" ]; then
  codesign --force --timestamp --sign "$DEV_ID" "$DMG"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "==> Notarising (this waits on Apple; a few minutes is normal)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "==> Notarised and stapled"
  else
    echo "==> Signed but NOT notarised: no '$NOTARY_PROFILE' credentials."
    echo "    Store them with:"
    echo "      xcrun notarytool store-credentials $NOTARY_PROFILE \\"
    echo "        --apple-id <id> --team-id <team> --password <app-specific-password>"
  fi
fi

echo
echo "==> Verification"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
echo "    Gatekeeper:"
spctl -a -vv -t exec "$APP" 2>&1 | sed 's/^/      /' || true
echo "    Disk image:"
spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 | sed 's/^/      /' || true
echo
echo "==> $DMG"
