#!/bin/bash
# Assemble AgentSpend.app from the SPM build.
#
# SPM produces a bare executable; a menu bar app needs a bundle with
# LSUIElement=1 so it runs without a Dock icon or main window.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
APP="build/AgentSpend.app"

swift build -c "$CONFIG"
# --show-bin-path can interleave build chatter on stdout; take the last line and
# check it, otherwise a contaminated path silently yields a binary-less bundle.
BIN="$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null | tail -1)"
if [ ! -x "$BIN/AgentSpend" ]; then
  echo "error: no executable at '$BIN/AgentSpend'" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/AgentSpend" "$APP/Contents/MacOS/"

# Coefficient files go as loose resources directly in Contents/Resources, loaded
# at runtime via Bundle.main. Do NOT ship SPM's nested AgentSpend_AgentSpend.bundle
# and rely on Bundle.module: its resolution depends on paths baked into ./.build
# that don't exist on another machine, which crashed the app at launch for anyone
# who wasn't the build host. Loose files in Contents/Resources are the canonical,
# machine-independent location — and, unlike the nested bundle, they need no
# synthesized Info.plist to satisfy codesign.
cp AgentSpend/Resources/energy-model.json AgentSpend/Resources/pricing.json \
   assets/AgentSpend.icns \
   "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>AgentSpend</string>
  <key>CFBundleDisplayName</key>     <string>AgentSpend</string>
  <key>CFBundleIdentifier</key>      <string>com.agentspend.app</string>
  <key>CFBundleExecutable</key>      <string>AgentSpend</string>
  <key>CFBundleIconFile</key>        <string>AgentSpend</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <!-- Menu bar only: no Dock icon, no main window. -->
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature — enough to run locally. Distribution would need a real
# Developer ID identity plus notarization.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
  echo "note: ad-hoc codesign failed; the app will still run locally"

echo "built $APP"
