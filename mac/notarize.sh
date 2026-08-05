#!/bin/bash
# Produce a notarized, stapled AgentSpend.dmg for public distribution.
#
# This is the "release to the world" packaging — unlike dist.sh (ad-hoc, for
# handing to friends who clear Gatekeeper manually), the output here verifies
# cleanly on any Mac with no warning. It requires an Apple Developer account.
# See RELEASING.md for the full picture.
#
# One-time setup:
#   1. Apple Developer Program ($99/yr), then create a "Developer ID Application"
#      certificate installed in your login keychain.
#   2. Store notary credentials once:
#        xcrun notarytool store-credentials "AgentSpend" \
#          --apple-id "you@example.com" --team-id "YOURTEAMID" \
#          --password "app-specific-password"
#
# Each release:
#   DEVID="Developer ID Application: Your Name (TEAMID)" ./notarize.sh
set -euo pipefail
cd "$(dirname "$0")"

# Auto-detect the Developer ID Application identity unless DEVID is set. This is
# specifically NOT the "Apple Development" or "Apple Distribution" cert — only a
# "Developer ID Application" cert can sign a notarized download that runs outside
# the App Store. Catching the wrong type here saves a confusing failure later.
if [ -z "${DEVID:-}" ]; then
  DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$DEVID" ]; then
  echo "No 'Developer ID Application' certificate found in your keychain." >&2
  echo "You currently have:" >&2
  security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /' >&2
  echo >&2
  echo "Create a Developer ID Application cert (Xcode → Settings → Accounts →" >&2
  echo "Manage Certificates → + → Developer ID Application, or the dev portal)," >&2
  echo "then re-run. See RELEASING.md." >&2
  exit 1
fi
echo "Signing identity: $DEVID"
PROFILE="${NOTARY_PROFILE:-AgentSpend}"
APP="build/AgentSpend.app"
DMG="build/AgentSpend.dmg"

# 1. Universal app bundle (reuses dist.sh's build), then re-sign with the real
#    Developer ID and the hardened runtime — notarization rejects anything less.
./dist.sh >/dev/null
rm -f build/AgentSpend.zip          # dist.sh's ad-hoc zip isn't what we publish
codesign --force --deep --options runtime --timestamp --sign "$DEVID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 2. Notarize the APP itself, then staple the ticket INTO the app. Stapling the
#    dmg alone isn't enough: once someone drags the app to /Applications, the
#    dmg's ticket doesn't travel with it, and a first launch with no network
#    would prompt. A ticket stapled to the app makes it self-contained and
#    verify offline. notarytool wants a container, so submit a zip of the app.
echo "Notarizing the app…"
NZIP="$(mktemp -d)/AgentSpend-notarize.zip"
ditto -c -k --keepParent "$APP" "$NZIP"
xcrun notarytool submit "$NZIP" --keychain-profile "$PROFILE" --wait
rm -f "$NZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# 3. Package the now-stapled app into a signed .dmg, then notarize and staple the
#    dmg too (the dmg is a separate artifact Gatekeeper assesses when opened).
#    Prefer the styled "drag to Applications" window (make-dmg.sh) when create-dmg
#    is installed; otherwise fall back to a plain, functional dmg.
rm -f "$DMG"
if command -v create-dmg >/dev/null; then
  ./make-dmg.sh
else
  echo "note: create-dmg not installed — building a plain dmg (brew install create-dmg for the styled window)"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "AgentSpend" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
fi
codesign --force --timestamp --sign "$DEVID" "$DMG"
echo "Notarizing the disk image…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "→ $DMG"
echo "  Notarized and stapled. Upload it to your GitHub Release."
echo "  SHA256 (for a Homebrew cask): $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
