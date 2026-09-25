#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: Scripts/setup.sh [--run] [--test] [--simulator "iPhone 17 Pro"]

Prepares CoolMap for Xcode: checks the toolchain, creates Config/Local.xcconfig,
regenerates CoolMap.xcodeproj and resolves Swift packages (Google Maps SDK).

  --run              Build and launch the app on an iPhone simulator
  --test             Run the ShadeCore unit tests
  --simulator NAME   Simulator to use with --run (default: booted iPhone, else newest iPhone)
EOF
}

RUN=0 TEST=0 SIM_NAME=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --run) RUN=1 ;;
    --test) TEST=1 ;;
    --simulator) SIM_NAME=${2:?--simulator needs a name}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  shift
done

cd "$(dirname "$0")/.."
PROJECT=CoolMap.xcodeproj SCHEME=CoolMap BUNDLE_ID=com.hendrix.coolmap

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

step "Checking toolchain"
command -v xcodebuild >/dev/null || die "Xcode is not installed. Install it from the App Store."
[[ $(xcode-select -p) == *CommandLineTools* ]] && die "Command Line Tools are selected instead of Xcode. Run: sudo xcode-select -s /Applications/Xcode.app"
xcodebuild -checkFirstLaunchStatus || die "Xcode needs first-launch setup. Run: sudo xcodebuild -runFirstLaunch"
command -v python3 >/dev/null || die "python3 is required to generate the Xcode project."
xcodebuild -version | head -1

step "Local configuration"
if [[ -f Config/Local.xcconfig ]]; then
  echo "Config/Local.xcconfig exists, leaving it untouched."
else
  cp Config/Local.xcconfig.example Config/Local.xcconfig
  echo "Created Config/Local.xcconfig. Apple Maps works without keys; see Backend/SETUP.md for Google Maps and reports."
fi

step "Generating $PROJECT"
python3 Scripts/generate_project.py

step "Resolving Swift packages"
xcodebuild -resolvePackageDependencies -project "$PROJECT" -quiet

if (( TEST )); then
  step "Running ShadeCore tests"
  CLANG_MODULE_CACHE_PATH=/tmp/coolmap-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/coolmap-module-cache \
    swift test --disable-sandbox --scratch-path /tmp/coolmap-build
fi

if (( RUN )); then
  step "Selecting simulator"
  UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
want, data = sys.argv[1], json.load(sys.stdin)["devices"]
ver = lambda rt: [int(p) for p in rt.rsplit("iOS-", 1)[1].split("-")]
devs = [d for rt in sorted((r for r in data if ".iOS-" in r), key=ver, reverse=True) for d in data[rt] if d["name"].startswith("iPhone")]
devs = [d for d in devs if d["name"] == want] if want else [d for d in devs if d["state"] == "Booted"] or devs
print(devs[0]["udid"] if devs else "")
' "$SIM_NAME")
  [[ -n $UDID ]] || die "No matching iPhone simulator. Install an iOS runtime in Xcode > Settings > Components."
  xcrun simctl bootstatus "$UDID" -b >/dev/null
  open -a Simulator --args -CurrentDeviceUDID "$UDID"
  echo "Using simulator $UDID"

  step "Building $SCHEME"
  DEST="platform=iOS Simulator,id=$UDID"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" -quiet build
  PRODUCTS=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')

  step "Launching $BUNDLE_ID"
  xcrun simctl install "$UDID" "$PRODUCTS/$SCHEME.app"
  xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID"
fi

step "Done"
echo "Open $PROJECT in Xcode, pick an iPhone simulator and press Run (Cmd+R)."
