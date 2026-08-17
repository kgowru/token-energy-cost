#!/bin/bash
# Build the styled "drag to Applications" disk image from an already-built
# build/AgentSpend.app — custom volume icon, background image, and the app +
# Applications alias positioned on the arrow.
#
# Uses create-dmg (`brew install create-dmg`). It styles the window by driving
# Finder via AppleScript, so the FIRST run prompts for Automation permission
# (Terminal → Finder) — approve it once. That's why this can't run headless/CI.
#
# notarize.sh calls this automatically when create-dmg is installed; you can also
# run it standalone to preview the look:  ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="build/AgentSpend.app"
DMG="build/AgentSpend.dmg"

[ -d "$APP" ] || { echo "build the app first: ./build-app.sh"; exit 1; }
command -v create-dmg >/dev/null || { echo "need create-dmg — run: brew install create-dmg"; exit 1; }

# create-dmg wants a source *folder*; stage just the app so the Applications
# alias is the only other item.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
rm -f "$DMG"

# Icon positions (x,y from top-left) sit on the background arrow; keep these in
# sync with assets/dmg-preview.html if you move the arrow. That page is the
# background's source of truth — tweak it, export @1x + @2x, then rebuild the
# HiDPI tiff:  tiffutil -cathidpicheck dmg-background.png dmg-background@2x.png \
#                       -out dmg-background.tiff
create-dmg \
  --volname "AgentSpend" \
  --volicon "assets/AgentSpend.icns" \
  --background "assets/dmg-background.tiff" \
  --window-pos 200 120 \
  --window-size 640 380 \
  --icon-size 128 \
  --icon "AgentSpend.app" 160 208 \
  --app-drop-link 480 208 \
  --no-internet-enable \
  "$DMG" "$STAGE"

rm -rf "$STAGE"
echo "→ $DMG (styled)"
