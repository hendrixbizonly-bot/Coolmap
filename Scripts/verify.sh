#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 ]]; then
  echo 'Usage: Scripts/verify.sh core|app|all' >&2
  exit 2
fi
case "$1" in
  core|app|all) ;;
  *) echo 'Usage: Scripts/verify.sh core|app|all' >&2; exit 2 ;;
esac
if [[ $1 == core || $1 == all ]]; then
  CLANG_MODULE_CACHE_PATH=/tmp/coolmap-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/coolmap-module-cache \
    swift test --disable-sandbox --scratch-path /tmp/coolmap-build
fi
if [[ $1 == app || $1 == all ]]; then
  Scripts/setup.sh
  xcodebuild -project CoolMap.xcodeproj -scheme CoolMap -destination 'generic/platform=iOS Simulator' -quiet build
fi
