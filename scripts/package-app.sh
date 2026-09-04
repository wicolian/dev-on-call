#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Dev On Call.app"
ZIP="$ROOT/build/Dev-On-Call-macOS.zip"
DMG="$ROOT/build/Dev-On-Call-macOS.dmg"
DMG_ROOT="$ROOT/build/dmg-root"

"$ROOT/scripts/install-local.sh"

# A release DMG should work on both Apple Silicon and Intel Macs. Building the
# two triples separately also works on machines that only have Command Line
# Tools, where SwiftPM's multi-arch mode requires the full Xcode xcbuild tool.
swift build -c release --triple arm64-apple-macosx13.0 --product DevOnCall
swift build -c release --triple arm64-apple-macosx13.0 --product dev-on-call
swift build -c release --triple x86_64-apple-macosx13.0 --product DevOnCall
swift build -c release --triple x86_64-apple-macosx13.0 --product dev-on-call
lipo -create \
  "$ROOT/.build/arm64-apple-macosx/release/DevOnCall" \
  "$ROOT/.build/x86_64-apple-macosx/release/DevOnCall" \
  -output "$APP/Contents/MacOS/DevOnCall"
lipo -create \
  "$ROOT/.build/arm64-apple-macosx/release/dev-on-call" \
  "$ROOT/.build/x86_64-apple-macosx/release/dev-on-call" \
  -output "$APP/Contents/Helpers/dev-on-call"
codesign --force --deep --sign - "$APP" >/dev/null

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$ROOT/build" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/Dev On Call.app"
ln -s /Applications "$DMG_ROOT/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Dev On Call" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"
(cd "$ROOT/build" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "$ZIP"
echo "$DMG"
