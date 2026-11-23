#!/bin/bash
# Build OpenKey.app with the Command Line Tools only (no Xcode).
# The compiled storyboard, images and helper apps come from a reference
# OpenKey 2.0.5 bundle, because ibtool and actool need Xcode.
# Only the main executable is compiled from this source tree.
#
# Usage: ./build_cli.sh [reference.app]
#   reference.app  default: build/OpenKey-2.0.5-original.app
# Output: build/OpenKey.app (arm64, signed as described below)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources/OpenKey"
OUT="$ROOT/build"
OBJ="$OUT/obj"
REF="${1:-$OUT/OpenKey-2.0.5-original.app}"

if [ ! -d "$REF" ]; then
  echo "Reference bundle not found: $REF" >&2
  exit 1
fi

rm -rf "$OBJ" "$OUT/OpenKey.app"
mkdir -p "$OBJ"

COMMON=(-arch arm64 -mmacosx-version-min=11.0 -O2 -fobjc-arc
        -I"$SRC/engine" -I"$SRC/macOS/ModernKey"
        -Wno-deprecated-declarations -Wno-nullability-completeness)

for f in "$SRC"/engine/*.cpp "$SRC"/macOS/ModernKey/*.mm; do
  clang++ -std=gnu++14 -stdlib=libc++ "${COMMON[@]}" -c "$f" -o "$OBJ/$(basename "$f").o"
done
for f in "$SRC"/macOS/ModernKey/*.m; do
  clang -std=gnu11 "${COMMON[@]}" -c "$f" -o "$OBJ/$(basename "$f").o"
done

clang++ -arch arm64 -mmacosx-version-min=11.0 -fobjc-arc -stdlib=libc++ "$OBJ"/*.o \
  -framework Cocoa -framework AppKit -framework Foundation -framework CoreGraphics \
  -framework ServiceManagement -framework EventKit -framework Carbon \
  -o "$OBJ/OpenKey"

# Assemble: copy the reference bundle, replace the executable.
ditto "$REF" "$OUT/OpenKey.app"
cp "$OBJ/OpenKey" "$OUT/OpenKey.app/Contents/MacOS/OpenKey"
xattr -cr "$OUT/OpenKey.app"

# Sign with the local "OpenKey Local Signing" certificate when it is in the
# keychain. Its designated requirement (identifier + certificate) stays the
# same across rebuilds, so the Accessibility permission survives a rebuild.
# Without it, fall back to ad-hoc (permission must be granted again each time).
SIGN_ID="$(security find-identity -p codesigning 2>/dev/null \
  | awk '/"OpenKey Local Signing"/ {print $2; exit}')"
SIGN_ID="${SIGN_ID:--}"
for h in "$OUT/OpenKey.app/Contents/Library/LoginItems/"*.app; do
  codesign --force --sign "$SIGN_ID" "$h"
done
codesign --force --sign "$SIGN_ID" "$OUT/OpenKey.app"
echo "Signed with: $SIGN_ID"
codesign --verify --deep --strict "$OUT/OpenKey.app"
echo "Built: $OUT/OpenKey.app"
