#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Dev On Call.app"
ZIP="$ROOT/build/Dev-On-Call-macOS.zip"

"$ROOT/scripts/install-local.sh"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"
echo "$ZIP"
