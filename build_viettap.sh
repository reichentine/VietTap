#!/bin/bash
# Build VietTap (VietTap.app) with the Command Line Tools only; Xcode is not needed.
# Sources: Sources/VietTapSwift (SwiftUI app), Sources/VietTap (keyboard hook
# KeyHook.mm, its header VTHook.h, the app icon) and Sources/OpenKey/engine.
#
# Usage: ./build_viettap.sh
# Output: build/VietTap.app (arm64, macOS 14 or later)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$ROOT/Sources/OpenKey/engine"
HOOK="$ROOT/Sources/VietTap"
SRC="$ROOT/Sources/VietTapSwift"
OUT="$ROOT/build"
OBJ="$OUT/obj-viettap"
APP="$OUT/VietTap.app"
MIN=14.0
# App icon: Sources/VietTap/AppIcon.icns, unless ICON is given.
ICON="${ICON:-$HOOK/AppIcon.icns}"

rm -rf "$OBJ" "$APP"
mkdir -p "$OBJ"

COMMON=(-arch arm64 -mmacosx-version-min=$MIN -O2 -fobjc-arc -I"$ENGINE" -I"$HOOK")

# OpenKey engine (unchanged; its own warnings are not ours to fix here).
for f in Engine.cpp Vietnamese.cpp Macro.cpp SmartSwitchKey.cpp; do
  clang++ -std=gnu++14 -stdlib=libc++ "${COMMON[@]}" -w -c "$ENGINE/$f" -o "$OBJ/$f.o"
done

# Keyboard hook.
clang++ -std=gnu++14 -stdlib=libc++ "${COMMON[@]}" -Wall -Wno-unused-variable \
  -c "$HOOK/KeyHook.mm" -o "$OBJ/KeyHook.mm.o"

# Swift app, linked with the objects above. VTHook.h is the bridge.
swiftc -O -swift-version 5 -target arm64-apple-macos$MIN -parse-as-library \
  -import-objc-header "$HOOK/VTHook.h" \
  "$SRC"/*.swift "$OBJ"/*.o -lc++ \
  -framework Cocoa -framework Carbon -framework ApplicationServices -framework ServiceManagement \
  -o "$OBJ/VietTap"

# Bundle.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OBJ/VietTap" "$APP/Contents/MacOS/VietTap"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# Sign with "OpenKey Local Signing" when present, so that the Accessibility
# permission survives a rebuild; else ad hoc.
SIGN_ID="$(security find-identity -p codesigning 2>/dev/null \
  | awk '/"OpenKey Local Signing"/ {print $2; exit}')"
SIGN_ID="${SIGN_ID:--}"
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "Signed with: $SIGN_ID"
echo "Built: $APP ($(du -sh "$APP" | cut -f1))"
