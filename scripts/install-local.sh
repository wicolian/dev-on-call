#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Dev On Call.app"
BUILD_APP="$ROOT/build/$APP_NAME"
INSTALL_APP="$HOME/Applications/$APP_NAME"

cd "$ROOT"
swift build -c release --product DevOnCall
swift build -c release --product dev-on-call

rm -rf "$BUILD_APP"
mkdir -p "$BUILD_APP/Contents/MacOS" "$BUILD_APP/Contents/Resources" "$BUILD_APP/Contents/Helpers"
cp "$ROOT/.build/release/DevOnCall" "$BUILD_APP/Contents/MacOS/DevOnCall"
cp "$ROOT/.build/release/dev-on-call" "$BUILD_APP/Contents/Helpers/dev-on-call"
cp "$ROOT/Resources/Info.plist" "$BUILD_APP/Contents/Info.plist"
codesign --force --deep --sign - "$BUILD_APP" >/dev/null

mkdir -p "$HOME/Applications" "$HOME/.local/bin"
rm -rf "$INSTALL_APP"
ditto "$BUILD_APP" "$INSTALL_APP"
install -m 755 "$ROOT/.build/release/dev-on-call" "$HOME/.local/bin/dev-on-call"

echo "Installed: $INSTALL_APP"
echo "CLI:       $HOME/.local/bin/dev-on-call"
echo "Launch:    open '$INSTALL_APP'"
