#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
mode="${1:-run}"
case "$mode" in
  run|--verify) ;;
  *) echo "Usage: $0 [--verify]" >&2; exit 2 ;;
esac

pkill -x 'Port Menu' || true
xcodebuild build -quiet \
  -project Porter.xcodeproj -scheme Porter -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" \
  OTHER_CODE_SIGN_FLAGS=--timestamp \
  MARKETING_VERSION=0.8.10-robin.2 CURRENT_PROJECT_VERSION=20

app="$PWD/build/DerivedData/Build/Products/Release/Port Menu.app"
codesign --verify --deep --strict "$app"
open -n "$app"
if [[ "$mode" == --verify ]]; then
  sleep 2
  pgrep -x 'Port Menu' >/dev/null
fi
