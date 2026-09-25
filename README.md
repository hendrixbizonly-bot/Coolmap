# Coolmap — Dubai pedestrian shade prototype

First-time setup: `Scripts/setup.sh` (checks Xcode, creates `Config/Local.xcconfig`, regenerates the project and resolves packages). Add `--run` to build and launch on a simulator, `--test` to run the ShadeCore tests.

Open `CoolMap.xcodeproj` in Xcode, select an iPhone simulator and Run. Tap **Where to?**, choose a destination, and allow location access or choose a starting point. Routes load automatically. The route-selection screen automatically shows the sun marker, estimated shadows, time slider and Play control; **Start walk** opens GPS progress, spoken instructions, steps and reporting. The Marina shortcut remains available. Apple Maps works without keys; Google Maps and shared reports need your own configuration (see [setup](Backend/SETUP.md)). Network access is required for routes and new building tiles. Physical-device builds require your own signing team.

## Verified core

The independent `ShadeCore` Swift package has no MapKit, SwiftUI, or CoreLocation dependency. Run:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/coolmap-module-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/coolmap-module-cache swift test --disable-sandbox --scratch-path /tmp/coolmap-build
```

The six requested synthetic cases passed before MapKit code was added: 45° shadow, high sun, low sun, east/west direction, night, and a 100 m / 10 min route producing 6 min direct sun and 4 min shade. 27 tests now pass. Additional tests cover projection, intersection, UTC conversion, Dubai solar progression, height units, uneven intervals and farther tall blockers, invalid polygons, a published NREL solar reference, low sun and real MapKit route time changes, OSM tile coverage/parsing, walking progress and Google polyline decoding.

## Calculation

- One local metric projection: +x east, +y north, Earth radius 6,371,000 m.
- Azimuth clockwise from north: 0° north, 90° east, 180° south, 270° west.
- Solar coordinates use NOAA/Meeus equations with UTC `Date`. Dubai controls use `Asia/Dubai` (UTC+4). Geometric solar center, without refraction.
- Horizontal unit ray toward the sun intersects each footprint. A building blocks the sun if its height exceeds `distance * tan(elevation)`.
- Flat ground, ground-level pedestrian, vertical constant-height extrusions. No trees, overhangs, terrain, indoor routes or cloud modeling.
- Midpoint samples represent intervals no longer than 4 m. Exposure is weighted by interval length, never sample count. Travel time is the routing provider’s expected time distributed proportionally over measured polyline length.
- Solar position is recalculated at each sample's estimated arrival time and location.
- At/below horizon: zero direct sun. Positive low sun: bounded 100/300/500 m search, explicitly incomplete for distant tall blockers.
- Debug shadows are swept footprint-edge quads; classification uses independent ray tests.

## Data — important limitations

Building data is now fetched on demand along walks across Dubai using 0.01° OSM tiles, cached for seven days. The prototype caps each request at 64 tiles and withholds exposure if a required tile fails (the bundled Marina sample can provide an explicitly labeled fallback). Whole-city routing support does not imply complete building heights or verified shade coverage. Complex building relations, elevated buildings and unsupported geometry are omitted.


Demo: Dubai Marina Mall promenade. Real OSM ways were downloaded September 24, 2026 UTC from:
`https://api.openstreetmap.org/api/0.6/map?bbox=55.132,25.073,55.145,25.085`

198 closed building footprints; 131 have parseable heights or levels, 67 have unknown heights. No height patches have been invented. `exact` means an explicit OSM height tag, **not independently surveyed accuracy**. `levelsEstimate` means tagged floors × 3.2 m. Some source levels appear implausibly low for towers: source audit remains necessary. The raw XML is retained for inspection. Import script preserves unknown height as null. Only closed building ways are supported; multipolygon relations and building parts require future reconciliation. Dataset completeness is not guaranteed.

Unknown-height buildings appear red. Green route intervals are blocked by known building geometry. Orange intervals have no known blocker; an unknown or absent building can still shade them. With unknown heights, displayed `≤ … min sun*` is an **upper estimate under the supplied height model**, not a complete exposure prediction. Best-shade ranking is disabled in this case. Missing datasets withhold exposure while continuing to offer real walking directions. Even with all local heights, finite query coverage remains a limitation.

This is not yet a fully verified hackathon acceptance demo: real building heights need review and important missing heights need evidence-backed patches before defensible single-value comparisons are possible. Do not present the upper estimates as validated true exposure.

## App

The main screen is a map with a current-location/start selector and destination search. Developer overlays are off by default and available in Map settings. Changing either endpoint immediately clears old results; superseded asynchronous requests cannot replace newer routes.

Native SwiftUI/MapKit map, origin/destination autocomplete, location permission, walking alternatives, a real MapKit intermediate-waypoint fallback, per-sample colors and inspector, building height/source labels, optional debug shadow quads, date and time controls. Route requests and data providers are separate. The bundled provider is a Marina fallback; the live city provider retrieves route-area OSM tiles. Sun preview moves the solar direction marker and recomputes shadow geometry and route exposure as Dubai date/time changes. Google SDK 11.1.0 is linked, with Google Places/Routes adapters; map, search and routes switch together when both keys are configured.

Walking mode follows fresh GPS fixes and projects them onto the route to estimate remaining distance/time. It includes a steps list, on-demand spoken instruction, report form and End action. It is prototype guidance: no automatic rerouting, background navigation or production navigation guarantees. Reports queue locally and sync to Supabase when configured. Nearby shared reports are unverified and never alter building calculations.

Simulator GPS is simulated and may be outside Dubai. If My location cannot produce a walk, choose a starting point using search or use the Marina demo. A very distant origin now produces an explanatory message and a Change starting point action.

## Files

- `Sources/ShadeCore`: projection, ray geometry, solar service, shade engine, route exposure and data models.
- `Tests/ShadeCoreTests`: independent engine verification.
- `CoolMap/Services`: routing, search, location, bundled building provider and orchestration.
- `CoolMap/Views`: native map, debug inspector, time controls, search and walking preview.
- `CoolMap/Resources/buildings.json`: source-tagged geometry; `source-osm.xml`: source extract.
- `Scripts/setup.sh`: one-step local setup; `--run` builds and launches on a simulator, `--test` runs the core tests.
- `Scripts/import_osm.py`: reproducible OSM import.
- `Scripts/generate_project.py`: regenerates the Xcode project, including the pinned Google Maps SPM dependency.

## References and attribution

Solar algorithm: https://gml.noaa.gov/grad/solcalc/calcdetails.html and NOAA calculator equations. Reference validation: https://docs.nlr.gov/docs/fy08osti/34302.pdf .

See `Verification/RESULTS.md`, `Verification/tests.log`, and noon/afternoon simulator screenshots for measured results.
Building geometry © OpenStreetMap contributors, ODbL: https://www.openstreetmap.org/copyright . Bundled derived data remains subject to ODbL. MapKit attribution is provided by the map itself.
