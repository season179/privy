#!/bin/zsh
# Build, bundle, and sign Privy.app into dist/.
# Signing identity is auto-detected (first valid "Apple Development" cert) so
# no personal identifiers live in the repo. A STABLE identity is required for
# mic permission to survive rebuilds — ad-hoc signing would re-prompt every
# build (PLAN.md req 7).
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
if [[ -z "${IDENTITY}" ]]; then
    echo "error: no 'Apple Development' signing identity found" >&2
    exit 1
fi

BUILD_VERSION=$(date +%s)
swift build -c release --product Privy

APP=dist/Privy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Privy "$APP/Contents/MacOS/Privy"
sed "s/BUILD_VERSION/$BUILD_VERSION/" Support/Info.plist > "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" "$APP"
echo "built $APP (CFBundleVersion=$BUILD_VERSION, identity=$IDENTITY)"
