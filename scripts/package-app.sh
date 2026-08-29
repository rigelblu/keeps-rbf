#!/bin/bash
# Package keeps as a signed .app bundle (#keeps-18) — the enabler for the UserNotifications half
# (#keeps-13): an unbundled SwiftPM binary has no bundle id and can't post. Signing with a real
# certificate (not ad-hoc) is load-bearing: TCC keys the Accessibility grant on the signing
# identity, so a stable identity means grant-once, not grant-every-rebuild.
#
# Usage: package-app.sh [debug|release]   (default: debug — the dogfood configuration)
# Output: .build/keeps.app (gitignored, colocated with the binary it wraps)
# Override the identity with KEEPS_SIGN_IDENTITY if the keychain changes. The default is the certificate's SHA-1,
# not its display name: two Apple Development certs can share the name (the 2026-08-11 expiry left the old one in the
# keychain beside the renewed one), and codesign refuses an ambiguous name. Override the build dir with
# KEEPS_SCRATCH_PATH when the repo's .build is unusable (its module cache pins the volume path it was created on).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
[[ "$CONFIG" == debug || "$CONFIG" == release ]] || { echo "usage: $0 [debug|release]" >&2; exit 2; }
IDENTITY="${KEEPS_SIGN_IDENTITY:-CF30AF3339F4D4887D22C04A4A381551F10763FD}"
SCRATCH="${KEEPS_SCRATCH_PATH:-$REPO/.build}"
APP="$SCRATCH/keeps.app"

# Fail BEFORE the multi-minute build when the identity can't sign. 2026-08-26: the cert had expired, codesign failed
# after the build, and a `| tee | grep` pipeline masked the exit — an unsigned bundle reached /Applications and TCC
# dropped the Accessibility grant. `find-identity -v` lists only valid (unexpired) identities.
if ! security find-identity -v -p codesigning | grep -q -- "$IDENTITY"; then
  echo "package-app: no valid codesigning identity matches '$IDENTITY'" >&2
  echo "package-app: valid identities:" >&2
  security find-identity -v -p codesigning >&2
  echo "package-app: renew it in Xcode (Settings → Accounts → Manage Certificates) or pass KEEPS_SIGN_IDENTITY=<sha1>" >&2
  exit 3
fi

# Default priority on purpose: `taskpolicy -b` made this build 7× slower (measured 2026-08-28, M4 Pro) and bought
# no responsiveness; `nice -n 1` is a no-op. If multi-agent load ever hurts, `taskpolicy -c utility` is the one
# clamp that keeps full speed — never `-b` or `-c maintenance`.
swift build -c "$CONFIG" --package-path "$REPO" --scratch-path "$SCRATCH"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$SCRATCH/$CONFIG/keeps" "$APP/Contents/MacOS/keeps"
cp "$REPO/scripts/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "packaged: $APP ($CONFIG)"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority=Apple Development)" || true
