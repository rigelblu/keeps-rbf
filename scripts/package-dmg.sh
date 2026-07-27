#!/bin/bash
# Package keeps as an installable .dmg (#keeps-24) — drag-to-Applications, the way a Mac app arrives.
#
# This script is deliberately a LADDER, not a gate. It produces a working image today with whatever
# certificate is on the machine, and climbs to a genuinely distributable one the moment a Developer ID
# certificate exists — no rewrite, no second script. What it will never do is pretend: if the image
# cannot open cleanly on someone else's Mac, it says so, in those words, every run.
#
#   Apple Development signing  → installs fine for you; Gatekeeper BLOCKS it on any other Mac
#   Developer ID + notarized   → opens clean anywhere
#
# The gap is not stylistic. Notarization REQUIRES Developer ID signing; an Apple Development certificate
# cannot be notarized at all, so no amount of flags gets there from here.
#
# ⚠️ ONE-TIME COST when you first switch to Developer ID: TCC keys the Accessibility grant on the signing
# identity (that is why package-app.sh pins a stable one — grant once, not every rebuild). Developer ID is
# a DIFFERENT identity, so the first Developer-ID build presents to TCC as a different app and your existing
# Accessibility grant stops applying. Re-grant it once via `open`, and it is stable again from there.
#
# Usage: package-dmg.sh [release|debug]     (default: release — an installer should not ship debug)
# Output: .build/keeps-<version>.dmg (gitignored, colocated with the bundle it wraps)
#
# Env:
#   KEEPS_SIGN_IDENTITY   override the fallback (Apple Development) identity — passed to package-app.sh
#   KEEPS_DEVID_IDENTITY  override Developer ID identity autodetection
#   KEEPS_NOTARY_PROFILE  notarytool keychain profile name; without it, notarization is skipped and the
#                         exact command to create one is printed
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
[[ "$CONFIG" == debug || "$CONFIG" == release ]] || { echo "usage: $0 [release|debug]" >&2; exit 2; }

APP="$REPO/.build/keeps.app"
STAGE="$REPO/.build/dmg-stage"  # on the external drive already, and gitignored — see .gitignore

# 1. Build and sign the bundle. package-app.sh owns that step; this script never duplicates it.
bash "$REPO/scripts/package-app.sh" "$CONFIG"

# Version comes from the bundle, so the image can never be named something the app disagrees with.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$REPO/.build/keeps-$VERSION.dmg"

# 2. Climb to Developer ID if the certificate is there. Autodetect rather than configure: the whole point
#    is that the day the cert appears, this script starts producing a distributable image with no edit.
DEVID="${KEEPS_DEVID_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"

DISTRIBUTABLE=false
if [[ -n "$DEVID" ]]; then
  echo "==> Developer ID found — re-signing for distribution: $DEVID"
  # --options runtime (hardened runtime) and --timestamp are both REQUIRED for notarization; a build
  # missing either is rejected at submission, not at signing, so set them here rather than discovering it
  # three minutes into an upload.
  codesign --force --options runtime --timestamp --sign "$DEVID" "$APP"
  codesign --verify --deep --strict "$APP"
  DISTRIBUTABLE=true
else
  echo "==> No Developer ID Application certificate on this machine."
  echo "    Falling back to the package-app.sh signature (Apple Development)."
fi

# 3. Stage: the app plus the /Applications symlink that makes "drag to install" self-explanatory.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/keeps.app"
ln -s /Applications "$STAGE/Applications"

# 4. The image itself. UDZO = compressed read-only, the standard shape for a distributed installer.
hdiutil create -volname "keeps" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

# 5. Sign and notarize the image, when we can. Signing the DMG is separate from signing the app inside it:
#    Gatekeeper checks both, and a notarization ticket is stapled to the DMG.
if [[ "$DISTRIBUTABLE" == true ]]; then
  codesign --force --timestamp --sign "$DEVID" "$DMG"
  if [[ -n "${KEEPS_NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing (this uploads to Apple and waits — minutes, not seconds)"
    xcrun notarytool submit "$DMG" --keychain-profile "$KEEPS_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    echo "==> Notarized and stapled — this image opens clean on any Mac."
  else
    DISTRIBUTABLE=false
    echo "==> Signed with Developer ID but NOT notarized: no notary profile configured."
    echo "    Create one once with:"
    echo "      xcrun notarytool store-credentials keeps-notary \\"
    echo "        --apple-id <your-apple-id> --team-id <your-team-id> --password <app-specific-password>"
    echo "    Then re-run with: KEEPS_NOTARY_PROFILE=keeps-notary $0 $CONFIG"
  fi
fi

echo
echo "packaged: $DMG ($CONFIG, v$VERSION)"
codesign -dv "$DMG" 2>&1 | grep -E "^Authority=" | head -2 || true

# The honest verdict, every run. An installer that quietly cannot be installed is exactly the class of
# silent failure #keeps-20 was built to end — so this never gets softened to "signed ✓".
echo
if [[ "$DISTRIBUTABLE" == true ]]; then
  echo "STATUS: distributable — signed with Developer ID, notarized, stapled."
else
  echo "STATUS: NOT distributable. Installs fine on this machine; on any other Mac Gatekeeper will refuse"
  echo "        it (\"keeps is damaged\" / unidentified developer). Getting there needs a Developer ID"
  echo "        Application certificate (paid Apple Developer Program) plus notarization — see the header."
fi
