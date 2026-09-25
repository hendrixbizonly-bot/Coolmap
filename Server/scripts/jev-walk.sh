#!/usr/bin/env bash
# Demo walk: Jeddah Street -> World Trade Center. A check every ${GAP}s, with community reports on most checks.
# Results appear live on http://localhost:3000/jev-live.html (reads /api/decisions).
# Usage: jev_walk.sh [--loop]    env: BASE_URL (default http://localhost:3000), GAP (seconds between checks, default 2.5)
BASE=${BASE_URL:-http://localhost:3000}; GAP=${GAP:-2.5}
post() { curl -s -m 20 -X POST "$BASE/api/reroute-decision" -H 'content-type: application/json' -d "$1" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);q={x['label']:(x['answer'],round(x['probability']*100)) for x in d['debug']['questions']};print('   ->',d['reason'],'prompt=',d['prompt'],q)"; }
# step: lat lon walked_s remaining_s remaining_heat heat_saved_pct extra_s sunset_min hazards_json
step() {
  local alt_heat=$(( $5 * (100 - $6) / 100 )) alt_s=$(( $4 + $7 ))
  post "{\"lat\":$1,\"lon\":$2,\"localTime\":\"$(date -u -v+4H +%Y-%m-%dT%H:%M:%S)+04:00\",\"offRouteMeters\":0,\"offRouteSeconds\":0,\"walkedSeconds\":$3,\"secondsSinceLastPrompt\":9999,\"minutesToSunset\":$8,\"current\":{\"remainingSeconds\":$4,\"remainingHeat\":$5,\"remainingSunSeconds\":$(( $4 * 8 / 10 ))},\"alternative\":{\"totalSeconds\":$alt_s,\"heat\":$alt_heat,\"sunSeconds\":$(( alt_s * 5 / 10 ))},\"hazardsAhead\":$9}"
  sleep "$GAP"
}
R() { printf '{"category":"%s","note":"%s","metersAhead":%s,"minutesAgo":%s,"confirmed":%s}' "$1" "$2" "$3" "$4" "$5"; }
run() {
echo "1  start, nothing ahead";                    step 24.49088 54.35495  10 460 1200  4 240 141 '[]'
echo "2  shade sail torn down";                    step 24.49079 54.35478  25 450 1170 18 200 141 "[$(R 'No shade' 'Shade sail torn down' 110 12 true)]"
echo "3  uneven paving (old)";                     step 24.49070 54.35460  40 440 1150  6 230 141 "[$(R 'Broken sidewalk' 'Uneven paving' 140 95 false)]"
echo "4  crowd outside mall entrance";             step 24.49057 54.35437  55 430 1120  8 220 140 "[$(R 'Other' 'Crowd outside mall entrance' 120 5 false)]"
echo "5  sprinklers soaking the pavement";         step 24.49044 54.35415  70 410 1080 16 190 140 "[$(R 'Other' 'Sprinklers soaking the pavement' 90 3 true)]"
echo "6  nothing ahead";                           step 24.49032 54.35407  85 400 1050  5 240 140 '[]'
echo "7  water pipe burst, pavement flooded";      step 24.49020 54.35400 100 390 1020 22 170 140 "[$(R 'Other' 'Water pipe burst, pavement flooded' 70 6 true)]"
echo "8  sidewalk closed for works";               step 24.49005 54.35394 115 375  990 20 180 139 "[$(R 'Construction' 'Sidewalk closed for works' 90 8 true)]"
echo "9  scaffolding overhead (shade)";            step 24.48990 54.35388 130 360  960  3 230 139 "[$(R 'Construction' 'Scaffolding over the sidewalk' 80 30 true)]"
echo "10 two reports: no shade + broken paving";   step 24.48975 54.35399 145 350  930 19 190 139 "[$(R 'No shade' 'Trees cut back, no shade' 100 15 true),$(R 'Broken sidewalk' 'Cracked paving slabs' 150 40 false)]"
echo "11 bench area in full sun";                  step 24.48960 54.35410 160 340  900  9 210 139 "[$(R 'No shade' 'Bench area in full sun' 130 60 false)]"
echo "12 nothing ahead";                           step 24.48940 54.35427 175 325  870  4 240 138 '[]'
echo "13 delivery trucks blocking crossing";       step 24.48921 54.35444 190 310  840 18 180 138 "[$(R 'Blocked crossing' 'Delivery trucks blocking the crossing' 60 2 true)]"
echo "14 hot asphalt, freshly resurfaced";         step 24.48905 54.35457 205 300  815 21 170 138 "[$(R 'Other' 'Fresh asphalt, very hot surface' 90 10 true)]"
echo "15 kiosk queue across the path";             step 24.48890 54.35470 215 290  790  7 220 138 "[$(R 'Other' 'Kiosk queue across the path' 70 20 false)]"
echo "16 bus stop canopy removed";                 step 24.48853 54.35500 240 260  720 25 150 137 "[$(R 'No shade' 'Bus stop canopy removed' 60 4 true)]"
echo "17 fallen tree across the path";             step 24.48830 54.35530 265 240  660 25 150 137 "[$(R 'Other' 'Fallen tree across the path' 50 3 true)]"
echo "18 steps with no ramp (old)";                step 24.48810 54.35545 280 220  610  5 200 136 "[$(R 'Steps / no ramp' 'Steps at the underpass' 80 120 false)]"
echo "19 no ramp at crossing";                     step 24.48798 54.35559 290 200  560  5 200 136 "[$(R 'Missing kerb ramp' 'No ramp at the crossing' 70 45 false)]"
echo "20 nearly there, nothing ahead";             step 24.48810 54.35600 320 120  320  2 240 136 '[]'
}
if [[ ${1:-} == --loop ]]; then while true; do run; done; else run; fi
