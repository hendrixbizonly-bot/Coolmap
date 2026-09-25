#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 0 ]]; then
  echo 'Usage: Scripts/smoke.sh' >&2
  exit 2
fi
LOCK=/tmp/coolmap-smoke.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "error: Smoke check already running ($LOCK); retry when it finishes." >&2
  exit 1
fi
trap 'rmdir "$LOCK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
Scripts/setup.sh
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
ver = lambda rt: [int(p) for p in rt.rsplit("iOS-", 1)[1].split("-")]
devs = [d for rt in sorted((r for r in data if ".iOS-" in r), key=ver, reverse=True) for d in data[rt] if d["name"].startswith("iPhone")]
devs = [d for d in devs if d["state"] == "Booted"] or devs
print(devs[0]["udid"] if devs else "")
')
if [[ -z $UDID ]]; then
  echo 'error: No available iPhone simulator; install an iOS runtime in Xcode.' >&2
  exit 1
fi
xcrun simctl bootstatus "$UDID" -b
BUILD=/tmp/coolmap-smoke-build
xcodebuild -project CoolMap.xcodeproj -scheme CoolMap -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$BUILD" \
  GOOGLE_MAPS_API_KEY= GOOGLE_SERVICES_API_KEY= REPORTS_HOST= REPORTS_PUBLIC_KEY= -quiet build
xcrun simctl install "$UDID" "$BUILD/Build/Products/Debug-iphonesimulator/CoolMap.app"
xcrun simctl terminate "$UDID" com.hendrix.coolmap >/dev/null 2>&1 || true
DATA=$(xcrun simctl get_app_container "$UDID" com.hendrix.coolmap data)
START=$(python3 -c 'import time; print(time.time_ns())')
xcrun simctl launch --terminate-running-process "$UDID" com.hendrix.coolmap --demo-autoload
python3 - "$DATA/Documents/last-analysis.json" "$START" <<'PY'
import json
import math
from pathlib import Path
import sys
import time

path, started = Path(sys.argv[1]), int(sys.argv[2])
deadline = time.monotonic() + 90
reason = "no fresh analysis file"
while time.monotonic() < deadline:
    try:
        if path.stat().st_mtime_ns >= started:
            routes = json.loads(path.read_text())
            valid = isinstance(routes, list) and any(
                isinstance(route, dict)
                and type(route.get("sunSecondsUpperEstimate")) in (int, float)
                and math.isfinite(route["sunSecondsUpperEstimate"])
                for route in routes
            )
            if valid:
                print(f"C-smoke: PASS ({len(routes)} routes; numeric sunSecondsUpperEstimate)")
                break
            reason = "expected at least one route with a finite numeric sunSecondsUpperEstimate"
    except (OSError, ValueError) as error:
        reason = str(error)
    time.sleep(1)
else:
    sys.exit(f"C-smoke: FAIL after 90 seconds: {reason}")
PY
mkdir -p Verification/smoke
SCREENSHOT="Verification/smoke/$(git rev-parse --short HEAD).png"
xcrun simctl io "$UDID" screenshot "$SCREENSHOT"
echo "Screenshot: $SCREENSHOT"
