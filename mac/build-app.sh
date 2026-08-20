#!/bin/bash
# Assemble AgentSpend.app from the SPM build.
#
# SPM produces a bare executable; a menu bar app needs a bundle with
# LSUIElement=1 so it runs without a Dock icon or main window.
set -euo pipefail

cd "$(dirname "$0")"
CONFIG="${1:-release}"
APP="build/AgentSpend.app"

# The single source of truth for the marketing version. It used to be typed
# directly into the Info.plist below, which the update checker turns into a
# hazard: the shipped app compares its own CFBundleShortVersionString against the
# latest GitHub tag, so forgetting to bump it here while tagging v0.1.2 makes
# every install show a "New version available" badge that upgrading never
# clears. One file, read by the build and by `git tag` (see RELEASING.md).
VERSION="$(tr -d ' \n' < VERSION)"
# CFBundleVersion only has to be monotonic, so derive it instead of keeping a
# second number in sync by hand. Outside a git checkout the count is unavailable
# and any placeholder will do — only release builds, which are cut from the
# repo, need the ordering to hold.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "version $VERSION (build $BUILD)"

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

# Unquoted heredoc: the version fields below interpolate. Nothing else in this
# plist contains a `$` or a backtick, so expansion is safe.
cat > "$APP/Contents/Info.plist" <<PLIST
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
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundleVersion</key>         <string>${BUILD}</string>
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
