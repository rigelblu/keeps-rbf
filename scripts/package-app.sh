#!/bin/bash
# Package keeps as a signed .app bundle (#keeps-18) — the enabler for the UserNotifications half
# (#keeps-13): an unbundled SwiftPM binary has no bundle id and can't post. Signing with a real
# certificate (not ad-hoc) is load-bearing: TCC keys the Accessibility grant on the signing
# identity, so a stable identity means grant-once, not grant-every-rebuild.
#
# Usage: package-app.sh [debug|release]   (default: debug — the dogfood configuration)
# Output: .build/keeps.app (gitignored, colocated with the binary it wraps)
# Override the identity with KEEPS_SIGN_IDENTITY if the keychain changes.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
[[ "$CONFIG" == debug || "$CONFIG" == release ]] || { echo "usage: $0 [debug|release]" >&2; exit 2; }
IDENTITY="${KEEPS_SIGN_IDENTITY:-Apple Development: tom.hosiawa@rigelblu.com (4JJHGVKG2B)}"
APP="$REPO/.build/keeps.app"

taskpolicy -b nice -n 1 swift build -c "$CONFIG" --package-path "$REPO"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$REPO/.build/$CONFIG/keeps" "$APP/Contents/MacOS/keeps"
cp "$REPO/scripts/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "packaged: $APP ($CONFIG)"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority=Apple Development)" || true
