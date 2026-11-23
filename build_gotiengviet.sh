#!/bin/bash
# Build Gõ Tiếng Việt (GoTiengViet.app) with the Command Line Tools only.
# Sources: Sources/GoTiengViet (app) + Sources/OpenKey/engine (OpenKey engine).
# All UI is built in code, so no storyboard, ibtool or Xcode is needed.
#
# Usage: ./build_gotiengviet.sh
# Output: build/GoTiengViet.app (arm64)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$ROOT/Sources/OpenKey/engine"
SRC="$ROOT/Sources/GoTiengViet"
OUT="$ROOT/build"
OBJ="$OUT/obj-gotiengviet"
APP="$OUT/GoTiengViet.app"
# App icon: OpenKey's icon from the reference bundle, unless ICON is given.
ICON="${ICON:-$OUT/OpenKey-2.0.5-original.app/Contents/Resources/Icon.icns}"

rm -rf "$OBJ" "$APP"
mkdir -p "$OBJ"

COMMON=(-arch arm64 -mmacosx-version-min=13.0 -O2 -fobjc-arc -I"$ENGINE" -I"$SRC")

# OpenKey engine (unchanged; its own warnings are not ours to fix here).
for f in Engine.cpp Vietnamese.cpp Macro.cpp SmartSwitchKey.cpp; do
  clang++ -std=gnu++14 -stdlib=libc++ "${COMMON[@]}" -w -c "$ENGINE/$f" -o "$OBJ/$f.o"
done

# App.
for f in "$SRC"/*.mm; do
  clang++ -std=gnu++14 -stdlib=libc++ "${COMMON[@]}" -Wall -Wno-unused-variable \
    -c "$f" -o "$OBJ/$(basename "$f").o"
done
for f in "$SRC"/*.m; do
  clang -std=gnu11 "${COMMON[@]}" -Wall -c "$f" -o "$OBJ/$(basename "$f").o"
done

clang++ -arch arm64 -mmacosx-version-min=13.0 -fobjc-arc -stdlib=libc++ "$OBJ"/*.o \
  -framework Cocoa -framework Carbon -framework ApplicationServices -framework ServiceManagement \
  -o "$OBJ/GoTiengViet"

# Bundle.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OBJ/GoTiengViet" "$APP/Contents/MacOS/GoTiengViet"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
fi

# Sign with the local "OpenKey Local Signing" certificate when present, so
# that the Accessibility permission survives a rebuild; else ad-hoc.
SIGN_ID="$(security find-identity -p codesigning 2>/dev/null \
  | awk '/"OpenKey Local Signing"/ {print $2; exit}')"
SIGN_ID="${SIGN_ID:--}"
codesign --force --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "Signed with: $SIGN_ID"
echo "Built: $APP ($(du -sh "$APP" | cut -f1))"
