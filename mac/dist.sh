#!/bin/bash
# Produce a distributable AgentSpend.zip: a universal (Apple Silicon + Intel)
# app bundle, zipped the way macOS expects.
#
# The zip is ad-hoc signed, NOT notarized — friends will have to clear Gatekeeper
# once on first launch (see SHARING.md). Real notarization needs an Apple
# Developer account; this script deliberately stops short of that.
set -euo pipefail
cd "$(dirname "$0")"

# 1. Build the arm64 bundle (Info.plist, resources, ad-hoc sign) via build-app.sh,
#    then fuse in the Intel slice so it runs on any Mac from ~2020 on.
echo "Building Apple Silicon slice…"
./build-app.sh release >/dev/null

echo "Building Intel slice…"
swift build -c release --arch x86_64 >/dev/null

ARM="$(swift build -c release --arch arm64  --show-bin-path 2>/dev/null | tail -1)"
X86="$(swift build -c release --arch x86_64 --show-bin-path 2>/dev/null | tail -1)"
APP="build/AgentSpend.app"

lipo -create -output "$APP/Contents/MacOS/AgentSpend" \
  "$ARM/AgentSpend" "$X86/AgentSpend"

# 2. Re-sign (the binary changed) and package with ditto — plain `zip` mangles
#    bundle metadata and the signature; ditto is what Apple's tooling expects.
codesign --force --deep --sign - "$APP"
rm -f build/AgentSpend.zip
ditto -c -k --keepParent "$APP" build/AgentSpend.zip

echo
echo "universal binary: $(lipo -archs "$APP/Contents/MacOS/AgentSpend")"
codesign --verify --verbose "$APP" 2>&1 | tail -1
echo "→ build/AgentSpend.zip  ($(du -h build/AgentSpend.zip | cut -f1))"
echo "  Send this file. Friends: see mac/SHARING.md for how to open it."
