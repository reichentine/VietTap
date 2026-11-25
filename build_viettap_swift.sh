#!/bin/bash
# Build VietTap Beta (the Swift/SwiftUI app) with the Command Line Tools only.
# Sources: Sources/VietTapSwift (SwiftUI app), Sources/VietTap/KeyHook.mm
# (keyboard hook, shared with the Objective-C app) and Sources/OpenKey/engine.
#
# Usage: ./build_viettap_swift.sh
# Output: build/VietTap Beta.app (arm64, macOS 14 or later)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$ROOT/Sources/OpenKey/engine"
HOOK="$ROOT/Sources/VietTap"
SRC="$ROOT/Sources/VietTapSwift"
OUT="$ROOT/build"
OBJ="$OUT/obj-viettap-swift"
APP="$OUT/VietTap Beta.app"
MIN=14.0

rm -rf "$OBJ" "$APP"
mkdir -p "$OBJ"

COMMON=(-arch arm64 -mmacosx-version-min=$MIN -O2 -fobjc-arc -I"$ENGINE" -I"$HOOK")

# OpenKey engine (unchanged; its own warnings are not ours to fix here).
for f in Engine.cpp Vietnamese.cpp Macro.cpp SmartSwitchKey.cpp; do
  clang++ -std=gnu++14 -stdlib=libc++ "${COMMON[@]}" -w -c "$ENGINE/$f" -o "$OBJ/$f.o"
done

# Keyboard hook (the same file as the Objective-C app).
clang++ -std=gnu++14 -stdlib=libc++ "${COMMON[@]}" -Wall -Wno-unused-variable \
  -c "$HOOK/KeyHook.mm" -o "$OBJ/KeyHook.mm.o"

# Swift app, linked with the objects above. VTHook.h is the bridge.
swiftc -O -swift-version 5 -target arm64-apple-macos$MIN -parse-as-library \
  -import-objc-header "$HOOK/VTHook.h" \
  "$SRC"/*.swift "$OBJ"/*.o -lc++ \
  -framework Cocoa -framework Carbon -framework ApplicationServices -framework ServiceManagement \
  -o "$OBJ/VietTapBeta"

# Bundle.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OBJ/VietTapBeta" "$APP/Contents/MacOS/VietTapBeta"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
cp "$HOOK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Sign with "OpenKey Local Signing" when present, so that the Accessibility
# permission survives a rebuild; else ad hoc.
SIGN_ID="$(security find-identity -p codesigning 2>/dev/null \
  | awk '/"OpenKey Local Signing"/ {print $2; exit}')"
SIGN_ID="${SIGN_ID:--}"
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "Signed with: $SIGN_ID"
echo "Built: $APP ($(du -sh "$APP" | cut -f1))"
