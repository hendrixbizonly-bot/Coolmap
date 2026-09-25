# Verification — September 25, 2026

- Geometry gates passed before MapKit integration.
- Xcode simulator build succeeded (arm64 and x86_64, iOS 17 deployment target).
- App installed and launched in iPhone 17 Pro / iOS 26.5 simulator.
- Real MapKit walking responses: 413 m / 310 s and 458 m / 346 s.
- Real OSM footprint overlays visually checked against the Marina base map. No systematic projection offset observed; this is not a footprint survey.
- Noon and afternoon classifications captured; recorded geometry re-evaluated in independent Swift tests.

| Route | Noon model sun minutes | 16:00 model sun minutes | Changed sample classifications |
|---|---:|---:|---:|
| Faster | 2.6916 | 3.0847 | 36 |
| Alternative | 4.0150 | 0.7498 | 76 |

These are computed from real route samples, solar coordinates, and the **incomplete** known-height dataset. They are not ground-truth exposure. Missing heights can reduce actual direct sun; erroneous source heights can bias either way. The UI rounds upper estimates upward to one decimal and disables best-shade recommendations while data is incomplete.

The second route becomes substantially more shaded as the sun rotates west. The first route becomes slightly more exposed despite longer shadows: overall exposure depends on orientation and obstacles, so it need not monotonically decrease with solar elevation. Synthetic tests independently verify the shadow-length relationship.

`noon.json` preserves the MapKit coordinates and sample decisions; it is only a regression fixture, not a routing fallback. `tests.log` contains the actual test run. Screenshots show the working simulator.

## Acceptance still outstanding

Evidence-backed height verification and patches for relevant buildings. There are 23 missing-height records near these candidates; source floor counts also need review. No fabricated heights, verified-height claims, or final exposure values have been substituted. The app is a working calculation/debug prototype, not yet a validated single-value route recommender.

## User-flow redesign

The app now launches without a destination, with My location and Where to? inputs. Search selection automatically requests walking routes; current-location permission is requested when needed. Manual origins are supported. Debug overlays default off and move into Map settings. Routes outside the shade-data region still receive MapKit walking directions, with no fabricated shade estimate.

An independent AppFlowChecks executable verifies initial state, missing-origin handling, current-location selection, clearing stale routes when either endpoint changes, and preserving the chosen destination when the starting point changes. All checks pass. Superseded route responses are guarded by a request token. The 18 independent geometry/solar/exposure tests still pass.

The redesigned home and real Marina route cards were inspected via simulator screenshots. Interactive tapping/search/permission checks remain unverified because the Mac was locked during this run; the computer-control tool requested manual unlock.

## Interactive checks completed

Manually exercised through Simulator accessibility controls:
- Typed Dubai Marina Mall; autocomplete returned actual MapKit matches and selection worked.
- Selected Marina promenade; routes loaded automatically (555 m / 8 min and 698 m / 9 min displayed).
- Switched to the alternative; selection updated.
- Opened walking instructions and advanced a step in the old UI. Found missing visible dismissal and confusing zero-meter intro.
- Replaced that preview with a numbered, scrollable list and Done. Rebuilt, opened the new list, and verified Done returns to route comparison.
- Changed departure with Leave now at 00:59 Dubai time; both routes updated to After sunset · no direct sun.
- My location reproduced Walking Directions Not Available. Manual Dubai origins work; simulator GPS configuration remains unconfirmed because the Mac locked again during inspection.

Improved route failure recovery: report very distant origins using calculated endpoint separation, offer Change starting point, and explain simulated GPS in simulator builds. Build succeeded. Final recovery controls have not yet been clicked after the Mac locked. City-wide walking directions remain supported where MapKit returns a route; city-wide building/shade coverage has not been added.


## Dubai expansion and integration preparation — September 25, 2026

Supersedes the earlier Marina-only limitation. A real MapKit City Walk → Burj Khalifa / Dubai Mall Metro walk returned 1,628 m and about 21 minutes. At 15:00 Dubai time the incomplete OSM model computed 979.553 seconds (displayed up to 16.4 minutes) of potential sun. This is a model result, not measured exposure. Live OSM tile fetch also independently succeeded outside Marina (7 tiles). The provider now discards footprints outside the route bounds plus its search radius before visualization.

Google Maps SDK 11.1.0 compiles in the iOS target. API authorization, live Google search/routing and cross-device Supabase sharing remain untested because the user requested setup preparation and has no projects/keys yet. Backend SQL and local configuration instructions are in `Backend/SETUP.md`. No cloud project or billing was created.

Sun preview, walking progress, steps/speech and report outbox are implemented. Interactive checks for these new screens were blocked by the locked Mac; earlier interactive checks above describe the previous UI only.

Final build succeeded with Google Maps SDK linked; all 23 core tests passed. `sun-preview-city.png` captures the new sun-preview screen at 15:00 on the live City Walk route. The screenshot was produced using the development launch arguments `--city-test --sun-test`; it verifies rendering, not interactive tapping.


## Lag fix — September 25, 2026

Reproduced blank map tiles during sun playback. The City Walk test route generated 418 footprint overlays, 1,538 shadow-edge overlays and 433 route-sample overlays in the previous SwiftUI renderer. The old process reported a 3.7 GB peak physical footprint (567.7 MB at sampling after pause).

Replaced the normal Apple map and sun preview with a persistent MKMapView using batched MKMultiPolygon / MKMultiPolyline layers. Unchanged layers stay installed; camera movement does not recreate geometry. Cached footprint validation, moved shadow computation off the main actor, suspended the hidden home map, and delayed slider calculation until release. Shade sample spacing and classification math are unchanged. Adjacent render segments merge without dropping any sampled endpoints.

On the same City Walk route, the updated process measured 105.3 MB physical footprint and 109.8 MB peak during a five-second playback sample; 2,912 of 3,393 main-thread samples were in the idle Mach wait. These are simulator observations over different run durations, not a controlled FPS benchmark or a physical-device guarantee. Playback was clicked, visibly advanced from 15:00 into night without blanking the map, and paused successfully. The Mac locked while attempting the slider drag, so that gesture and walking mode were not verified in this pass. All 25 core tests pass, including lossless rendering-group and disconnected-segment tests.


## Walking camera stays with the selected route

The user’s screenshot exposed unconditional camera following of the simulator GPS outside Dubai. Walking mode now follows only fresh, accurate fixes within 250 m of the selected route; on-route progress still requires 45 m. Otherwise it fits the selected route and explicitly shows Route preview. Stale fixes also return to preview. The Google camera has the same gate. Preview reports explicitly identify route-start coordinates instead of calling them the user’s location. Added regressions for a San Francisco fix against a Dubai route and the near-route distance boundary; all 27 tests pass.

Verified the installed walking view using the `--city-test --sun-test --walk-test` launch path: screenshot `dubai-walk-fixed.png` shows Al Safa Street, Sheikh Zayed Road, the selected route and the Route preview notice. Simulator GPS was not changed. Interactive tapping was blocked by the locked Mac; screenshot verification is not a tap-test claim.


## Inline sun simulator

Moved sun marker, batched shadow layer, Dubai-time slider and playback onto the normal route-selection screen. Start walk now opens walking mode directly. Verified via Simulator accessibility: simulator controls appear automatically for the Marina routes; selected Alternative; Play advanced 16:00 to 16:15 and both route estimates changed (3.1→2.5, 0.8→0.7 minutes); playback continued into night and Pause stopped at 19:15 with no direct sun on both routes. The Mac locked during the drag gesture, so dragging remains unverified. Build passed. Map layout refits route geometry when the control panel changes map size.


## Abu Dhabi presentation redesign

Built with native iOS 26 glassEffect (material fallback on earlier OS versions), a full-screen map, floating endpoint card, route pills, road-level shade classification and inline time playback. Defaults to an explicitly labeled Al Maryah Island demo; never claims the demo origin is current GPS. Map search is biased to Abu Dhabi. Map-provider selection explains missing Google credentials; both keys are still absent.

Real simulator check: Rosewood-area demo → The Galleria returned an 893 m / approximately 12-minute MapKit walk, with about 4.2 model-estimated minutes of sun at 15:00. Playback changed this to approximately 4.0 minutes at 15:15 and zero after sunset. Tapped Go and verified the glass walking screen stayed on Al Maryah Island with the correct preview disclosure. The provider’s waypoint detour was 47 minutes and was rejected by the final 1.6× detour threshold. A single available route is disclosed rather than inventing a shade alternative.

The app filters route candidates to <=3,600 seconds before requesting buildings. New unit coverage checks the 3,600/3,601-second boundary and invalid durations; all 28 tests passed. Attempted a live route to Louvre Abu Dhabi: MapKit returned no pedestrian route, and the app displayed recovery controls. This checks routing failure handling, not the one-hour rejection UI. Mac locking prevented completing the remaining manual search/provider checks. Final iOS build succeeded.

## Sunlight and route choice — 25 September 2026
- Added native Canvas sunlight rays and glow, isolated to a 20 fps child timeline; Reduce Motion pauses shimmer. Night hides rays.
- Restored background-computed shadow polygons on the main route preview. MapKit draws them as one nonzero fill so overlaps do not accumulate darkness. These remain estimates from available building heights.
- Added explicit Shortest and Shade selection, actual provider walking minutes, and percentage walking-time difference for distinct choices. Same-route result is explicitly disclosed; no extra route is fabricated.
- Simulator interaction verified Shade selection and playback from 15:00 (4.2 estimated sun minutes) to 15:15 (4.0) and night (0.0). Final uniform-shadow renderer verified by simulator screenshot after rebuild. Mac locked during final UI capture; simctl capture still verified rendering.
- Xcode simulator build passed; 28 ShadeCore tests passed. Google Maps remains untested without API keys. Default Abu Dhabi demo returns one useful route, so distinct-route percentage was code-reviewed rather than verified with a live alternate.

## Walking navigation — 25 September 2026
- Added an on-map directional arrow, turn symbol/distance banner, tracking camera, remaining time/distance and estimated arrival, and an explicitly labelled accelerated Demo walk for unavailable/off-route GPS.
- Demo interpolation follows the returned route geometry; reports from demo positions are labelled simulated. Real GPS is never silently replaced by demo coordinates in the app.
- Corrected the simulator's San Francisco test location to the public Abu Dhabi demo path using simctl. Verified navigation receives it and displays Turn left / In 73 m, 12 min, 0.9 km, and arrival estimate.
- Build and 28 core tests passed. Further moving-GPS UI verification was interrupted by user interaction with Simulator; full physical-device walking verification remains outstanding.

## Simple home and route identity — 25 September 2026
- Normal launch now shows a destination search field, menu, and current-location control. Demo is available in the menu instead of loading automatically. Profile is explicitly a future placeholder.
- Route cards include walking and estimated sun minutes; retained playback, time slider, navigation, reports, swapping, and map/date options. Yellow identifies Shortest and blue identifies Shade, including the walking line. Grey insets identify shaded route portions.
- Expanded single-route fallback to real pedestrian legs through two sides of the origin/destination corridor. Rejects disconnected joins, near-duplicate paths, walks over one hour, and detours over 1.8 times the baseline duration.
- Only exposes a Shade choice when the least-sun result is a distinct route. Abu Dhabi demo still produced no qualifying shadier alternative; this requirement is limited by returned pedestrian directions, not solved by fabricated route geometry.
- Verified simulator home, menu/profile placeholder, and yellow/grey route preview. Simulator build and 28 core tests passed. Distinct blue shade selection not live-tested because this demo returned no shadier alternative.
