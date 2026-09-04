#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="wicolian/dev-on-call"
ASSET="Dev-On-Call-macOS.dmg"
BASE_URL="${DEV_ON_CALL_BASE_URL:-https://github.com/$REPOSITORY/releases/latest/download}"
INSTALL_ROOT="${DEV_ON_CALL_INSTALL_ROOT:-$HOME/Applications}"
APP="$INSTALL_ROOT/Dev On Call.app"
CLI_DIR="${DEV_ON_CALL_BIN_DIR:-$HOME/.local/bin}"
TEMP_DIR="$(mktemp -d /tmp/dev-on-call-install.XXXXXX)"
MOUNT="$TEMP_DIR/mount"

cleanup() {
  if mount | grep -Fq "on $MOUNT "; then
    hdiutil detach -quiet "$MOUNT" || true
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Dev On Call requires macOS 13 or newer." >&2
  exit 1
fi

mkdir -p "$MOUNT" "$INSTALL_ROOT" "$CLI_DIR"
echo "Downloading Dev On Call…"
curl -fsSL "$BASE_URL/$ASSET" -o "$TEMP_DIR/$ASSET"
curl -fsSL "$BASE_URL/$ASSET.sha256" -o "$TEMP_DIR/$ASSET.sha256"

expected="$(awk '{print $1}' "$TEMP_DIR/$ASSET.sha256")"
actual="$(shasum -a 256 "$TEMP_DIR/$ASSET" | awk '{print $1}')"
if [[ -z "$expected" || "$actual" != "$expected" ]]; then
  echo "Checksum verification failed." >&2
  exit 1
fi

hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$TEMP_DIR/$ASSET"
rm -rf "$APP"
ditto "$MOUNT/Dev On Call.app" "$APP"
install -m 755 "$APP/Contents/Helpers/dev-on-call" "$CLI_DIR/dev-on-call"
hdiutil detach -quiet "$MOUNT"

echo "Installed: $APP"
echo "CLI:       $CLI_DIR/dev-on-call"
if [[ "${DEV_ON_CALL_NO_LAUNCH:-0}" != "1" ]]; then
  open "$APP"
fi
