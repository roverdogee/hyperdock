#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
INSTALL_DIR="/Applications"
APP="$INSTALL_DIR/HyperDock.app"
CONFIG="${CONFIG:-Debug}"

# This machine keeps the full IDE as Xcode-beta while xcode-select points at the
# standalone Command Line Tools. Select it automatically unless the caller supplied a
# developer directory explicitly.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

echo "==> Generating Xcode project"
xcodegen generate --quiet

echo "==> Building ($CONFIG)"
set +e
xcodebuild \
  -project HyperDock.xcodeproj \
  -scheme HyperDock \
  -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/.build/DerivedData" \
  -quiet \
  build 2>&1 | grep -v "CoreSimulator" | grep -v "^$"
STATUS=${PIPESTATUS[0]}
set -e
if [ "$STATUS" -ne 0 ]; then
  echo "==> BUILD FAILED"
  exit "$STATUS"
fi

BUILT="$ROOT/.build/DerivedData/Build/Products/$CONFIG/HyperDock.app"
if [ ! -d "$BUILT" ]; then
  echo "==> Could not find built app at $BUILT"
  exit 1
fi

if [ "$CONFIG" = "Release" ]; then
  RELEASE_EXECUTABLE="$BUILT/Contents/MacOS/HyperDock"
  if find "$BUILT/Contents/MacOS" -maxdepth 1 -type f \
      \( -name '*.debug.dylib' -o -name '__preview.dylib' \) | grep -q .; then
    echo "==> REFUSING: Release contains Xcode debug/preview dylibs"
    exit 1
  fi
  if otool -l "$RELEASE_EXECUTABLE" | grep -Eq '__llvm_(prf|cov)' \
      || nm -a "$RELEASE_EXECUTABLE" 2>/dev/null | grep -Eq '___llvm_(profile|cov)'; then
    echo "==> REFUSING: Release executable contains LLVM coverage instrumentation"
    exit 1
  fi
fi

echo "==> Installing to $APP"
mkdir -p "$INSTALL_DIR"
pkill -x HyperDock 2>/dev/null || true
rm -rf "$APP"
cp -R "$BUILT" "$APP"

SIGN_IDENTITY="HyperDock Local Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/hyperdock-signing.keychain-db"

if [ -f "$SIGN_KEYCHAIN" ] && security find-identity "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> Signing as '$SIGN_IDENTITY'"
  codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" \
    --entitlements Sources/HyperDock/Resources/HyperDock.entitlements \
    --options runtime "$APP" 2>&1 | grep -v "replacing existing signature" || true
else
  echo "==> Signing (ad-hoc — run scripts/setup-signing.sh to stop losing permissions on rebuild)"
  codesign --force --deep --sign - \
    --entitlements Sources/HyperDock/Resources/HyperDock.entitlements \
    --options runtime "$APP" 2>&1 | grep -v "replacing existing signature" || true
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" 2>/dev/null || true

echo "==> designated requirement (stable across rebuilds if certificate-based):"
codesign -d -r- "$APP" 2>&1 | grep '^designated' | sed 's/^/    /' || true
echo
echo "==> Built $APP"
echo
echo "    Launch it with:  open \"$APP\""
echo
echo "    Do NOT run the binary directly from a shell. A process started that way"
echo "    inherits the TERMINAL's TCC grants rather than the app's, so permissions"
echo "    will look granted when they are not."
