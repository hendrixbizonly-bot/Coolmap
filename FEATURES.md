# Feature changelog

One entry per feature so the team can see exactly what changed and where.

## Feature 1 — Waze-style hazard reporting (persistent button, map pins, auto-expiry)

**What it does**

- A prominent orange floating **Report a hazard** button sits above the "Use my location" button on the map screen and on the walking screen. It never disappears while the map is visible.
- Tapping it opens a one-tap sheet with five hazard tiles: **Broken sidewalk, Blocked crossing, No shade, Construction, Other**, plus an optional note. Tap a tile → "Pin …" and the report is pinned immediately.
- The pin is placed at your GPS fix (if fresh and accurate), otherwise at the map centre; the sheet tells you which.
- Reports render as coloured map pins with a category glyph on both the Apple map (`BatchedRouteMap`) and the debug/walking SwiftUI `Map`. Tapping a pin shows the note, when it was reported and when it clears.
- **Auto-expiry** per category: Blocked crossing 6 h · Other 24 h · Broken sidewalk / Construction 14 days · No shade 30 days. Expired reports are purged on launch, every 60 s while the map is open, and filtered out of nearby community results.
- Offline-first: reports save locally (`Documents/route-reports-v2.json`) and sync to Supabase only when `REPORTS_HOST`/`REPORTS_PUBLIC_KEY` are configured (unchanged behaviour). Community reports remain unverified and do not affect routing or shade.

**Files changed**

| File | Change |
| --- | --- |
| `CoolMap/Services/RouteReports.swift` | New `HazardCategory` enum (raw name, SF Symbol, colour, lifetime, legacy-name mapping). `RouteReport` gains `hazard`, `expiresAt`, `isActive`. `RouteReportStore` gains `shared` singleton, `active` (own + nearby, unexpired, de-duplicated) and `purgeExpired()`; nearby fetch filters expired rows. |
| `CoolMap/Views/HazardReportSheet.swift` | **New.** `HazardReportButton` (orange floating control) and `HazardReportSheet` (tile grid, note, submit). |
| `CoolMap/Views/BatchedRouteMap.swift` | New `hazards` input rendered as `HazardAnnotation` marker pins with callouts; hazard pins survive route re-fits; new `onCenterChange` callback so a report can be dropped at the map centre. |
| `CoolMap/Views/MapScreen.swift` | Floating button + sheet wiring, pins passed to both map paths, 60 s expiry timer, nearby refresh when origin is set. |
| `CoolMap/Views/WalkingSessionView.swift` | Floating button, "Report" action now opens the quick sheet, pins shown on the walking map. |
| `CoolMap/Views/RouteReportView.swift` | **Removed** — replaced by `HazardReportSheet`. |
| `Backend/reports.sql` | `category` check constraint accepts the new names (old names kept for existing rows). Re-run in Supabase if you already created the table. |
| `CoolMap.xcodeproj/project.pbxproj` | Regenerated via `Scripts/generate_project.py` for the added/removed files. |

**Not covered / follow-ups**

- Google Maps provider (`GoogleRouteMap`) does not draw hazard pins yet — only used when Google keys are configured.
- No upvote/"still there?" confirmation, no server-side expiry or moderation (see `Backend/SETUP.md`).

## Feature 2 — "Still there?" verification (Waze-style proximity prompt, adapted for walking)

**What it does**

- **Trigger zone:** every active pin has a 40 m radius. When a GPS fix lands inside it (map screen or walking screen), a **Still there?** card slides in at the top — close enough to check with your own eyes at walking pace. The nearest pin wins; each pin is asked about at most once per 30 min per device; your own reports are skipped for their first 10 min.
- **Still there (thumbs up, blue):** restarts the pin's decay timer from now (`confirmedAt`), keeping it on the map for the next walker.
- **Not there (orange X):** adds a weighted negative vote. Once weighted denials reach **2.0** the pin is cleared immediately (from the map and local storage).
- **No answer:** the card times out after 8 s (progress bar) — neutral; the natural decay timer keeps ticking.
- **Reputation weighting (local-only for now, no accounts yet):** each device has a `WalkerReputation` score starting at 1.0; every 5 answered prompts it rises by 0.25, capped at 2.0 (floor 0.5). The score is the weight of each vote. Server-side accuracy scoring can lower it later.
- Votes are POSTed to a new Supabase table `route_report_votes` when sharing is configured (best-effort); otherwise everything stays on-device.

**Stage demo (show the flow on stage without a real hazard)**

On the walking screen, tap the orange **Stage demo** toggle (bottom-left). It plants a "Fallen tree across the path" pin on your own route, reported by another walker 10 minutes ago (~150 m in, or mid-route on short walks), and starts a simulated walker 90 m before it moving along the route at 3 m/s. When the walker enters the pin's 40 m trigger zone the real `checkProximity` path fires the Still there? card — nothing is faked downstream. The walker pauses while the card is up so you can talk, then continues after Still there / Not there / timeout. A caption shows "Another walker reported … 10 min ago · N m ahead". Turning the toggle off (or ending the walk) removes the pin. Demo pins are in memory only: never saved, uploaded, or voted to the backend.

**Files changed**

| File | Change |
| --- | --- |
| `CoolMap/Services/RouteReports.swift` | `RouteReport` gains `confirmedAt`, `denials` (backwards-compatible decoding); `expiresAt` counts from the last confirmation; `isActive` also requires `denials < 2`. New `WalkerReputation`. `RouteReportStore` gains `verification`, `checkProximity(to:)`, `answerVerification(stillThere:)`, `dismissVerification()`, haversine `distance`, vote upload; stage demo (`demo`, `plantStageDemo(at:)`, `clearDemoHazards()`). |
| `CoolMap/Views/HazardReportSheet.swift` | New `StillThereCard` (icon, "Still there" / "Not there", 8 s timeout bar). |
| `CoolMap/Views/MapScreen.swift`, `WalkingSessionView.swift` | Feed location fixes into `checkProximity`, show the card at the top; WalkingSessionView also hosts the Stage demo toggle and simulated walker. |
| `Backend/reports.sql` | New `route_report_votes` table + insert policy. |

**Not covered / follow-ups**

- Server-side aggregation of votes (extend/clear for *all* users) — currently each device applies its own vote locally and uploads it.
- Route-aware pre-alerting ("hazard ahead in 200 m along your route") — trigger is pure proximity for now.

## Feature 3 — D0 repeatable verification checks

**What it does**

- `Scripts/verify.sh core|app|all` runs the ShadeCore `swift test` suite (isolated scratch/module cache under `/tmp`), the simulator app build, or both.
- `Scripts/smoke.sh` runs the locked Apple Maps demo check: picks an iPhone simulator, builds Debug with empty Google/report flags, installs, launches with `--demo-autoload`, and polls `Documents/last-analysis.json` for a fresh top-level route array with a finite numeric `sunSecondsUpperEstimate` (up to 90 s). A mkdir lock at `/tmp/coolmap-smoke.lock` prevents concurrent runs.
- On pass it saves a simulator screenshot to `Verification/smoke/<short-sha>.png` (directory gitignored).

**Files changed**

| File | Change |
| --- | --- |
| `Scripts/verify.sh` | **New.** Core tests and/or simulator app build. |
| `Scripts/smoke.sh` | **New.** Locked demo smoke check with freshness guard and screenshot artifact. |
| `Scripts/setup.sh` | Replaces `head -1` with `sed -n '1p'` when printing the Xcode version to avoid intermittent SIGPIPE (exit 141) under pipefail. |
| `README.md` | One line documenting the checks. |
| `.gitignore` | Ignores `Verification/smoke/`. |
| `FEATURES.md` | This entry. |

**Not covered / follow-ups**

- Requires Xcode with an iOS simulator runtime and network access for routing.
- No app source changes; Google Maps path and shared reports are not exercised.

## Feature D2 — Offline Abu Dhabi building heights

**What it does**

- Bundles 19,381 footprints for longitude 54.31–54.41, latitude 24.42–24.52 (6.78 MB), without changing app loading or adding app network calls.
- Matches GlobalBuildingAtlas footprints to OpenStreetMap by centroid containment or intersection-over-union above 0.3; height priority is OSM height, OSM levels × 3.5 m, then GBA model height.
- Drops footprints below 15 m², rounds coordinates to six decimals, and preserves named OSM towers including ADNOC Headquarters (342 m).
- Run `python3 Scripts/build_buildings.py` after installing `Scripts/requirements.txt`; source snapshots default to `/tmp/coolmap-buildings-cache` for identical offline reruns, and `--refresh` fetches current upstream data.

**Files changed**

| File | Change |
| --- | --- |
| `Scripts/build_buildings.py`, `Scripts/requirements.txt` | Reproducible offline importer, Overpass fallback, pinned dependencies and printed source shares/top ten. |
| `CoolMap/Resources/abudhabi-buildings.json` | GlobalBuildingAtlas (CC BY-NC) footprints with OpenStreetMap (ODbL) height overrides. |
| `Sources/ShadeCore/ShadeEngine.swift` | Adds the `model` height source. |
| `Tests/ShadeCoreTests/AbuDhabiBuildingTests.swift` | Decodes the bundled file and checks heights, sources, polygons, unique IDs, size and a named ≥150 m OSM tower. |
| `CoolMap.xcodeproj/project.pbxproj` | Regenerated to bundle the new JSON. |

**Not covered / follow-ups**

- D5 owns loading the bundle in the app; this change does not activate it.
- Upstream snapshots are cached locally, not committed; refreshing can change results as OSM evolves. The core footprint model stores exterior rings only.

## Feature 4 — Coolmap server scaffold (Next.js + Jev evaluation wrapper)

**What it does**

- New `Server/` package: minimal Next.js App Router app (`next dev`/`build`/`start`, `pnpm check` = tsc + eslint + vitest) with a root page and `GET /api/health` returning `{ ok: true }`.
- `lib/jev.ts` `evaluateWithJev` wraps AI SDK `experimental_evaluate` for `typesafe-ai/jev` via Vercel AI Gateway (`AI_GATEWAY_API_KEY`, local-only env): zero data retention, hard 3 s timeout, no retries, returns `{ ok, answers, probabilities }` or a safe failure reason — including `missing_probabilities` when the model returns no distribution.
- No iOS/Swift behaviour change — server only.

**Files changed**

| File | Change |
| --- | --- |
| `Server/package.json`, `Server/pnpm-lock.yaml` | New package `coolmap-server` with pinned deps (ai, next, react) and dev deps (typescript, eslint, vitest, types). |
| `Server/tsconfig.json`, `Server/eslint.config.mjs`, `Server/.gitignore`, `Server/next-env.d.ts` | Strict Next TS config, flat ESLint (core-web-vitals + typescript), ignores for `.next`/env files. |
| `Server/app/layout.tsx`, `Server/app/page.tsx` | Minimal root layout and page. |
| `Server/app/api/health/route.ts` (+ `route.test.ts`) | Health endpoint `{ ok: true }`. |
| `Server/lib/jev.ts` (+ `jev.test.ts`) | Jev evaluation wrapper + vitest coverage (typed answers/probabilities, 3 s timeout, missing distribution, provider error, missing key). |
| `Server/README.md` | Setup, commands, and return contract docs. |

**Not covered / follow-ups**

- Live model credentials not tested — all Jev tests use `Experimental_EvaluationMockModelV4`; real gateway calls need a valid `AI_GATEWAY_API_KEY`.
- No routes consume `evaluateWithJev` yet; no deployment config.

## R-A1 — Off-route duration tracker

**What it does**

- Adds a public `OffRouteTracker` (`Sendable` value type) to `ShadeCore`. Each `update(distanceOffRoute:at:)` call returns the current route deviation in meters and the continuous seconds spent beyond the 25 m off-route threshold.
- Returning to 25 m or less resets the clock; the next departure starts a fresh count at zero.
- Elapsed time is clamped so it can never go negative, even if timestamps arrive out of order.
- No app behavior changes — nothing calls the tracker yet.

**Files changed**

| File | Change |
| --- | --- |
| `Sources/ShadeCore/WalkingProgress.swift` | New `OffRouteTracker` struct. |
| `Tests/ShadeCoreTests/WalkingCameraTests.swift` | Four tests covering on-route zero time, accumulation, reset on return, and negative-time clamping. |

**Not covered / follow-ups**

- Wiring the tracker into the walking UI / reroute flow is a separate task.

## Feature 5 — Heat-score route ranking (coolest route label)

**What it does**

- A new `SunIntensity.weight(elevationDegrees:)` in ShadeCore converts solar elevation to a normalised 0–1 intensity (projected irradiance × air-mass-attenuated direct normal, scaled by the numerically solved global peak at ~32.41°). Degrees are converted to radians inside the formula.
- `RouteHeat.cost(_:expectedTravelTime:k:fromDistance:)` prices a route as `travelTime × Σ share_i × (1 + k · sunFraction_i · weight_i)`. Samples are midpoint intervals, so `fromDistance` clips the partially covered interval rather than filtering midpoints; the time-share denominator is always the whole sampled route length. `k` is the single constant `RouteHeat.defaultK = 2`.
- `AppModel.coolest` ranks every route with an exposure by heat cost — no gating on missing building heights or unexposed routes — and `heatCost` is exported in diagnostics.
- Route cards label the winner "Coolest · +N min" (or "Fastest · coolest" when it coincides with the fastest) and append "· X% less sun" only when the fastest route's baseline is present, positive, and the reduction rounds above zero — it never claims more sun.

**Files changed**

| File | Change |
| --- | --- |
| `Sources/ShadeCore/HeatScore.swift` | **New.** `SunIntensity`, `ShadeDecision.sunFraction`, `RouteHeat` cost function. |
| `Tests/ShadeCoreTests/HeatScoreTests.swift` | **New.** Weight reference values, bounds/peak, shade/sun costs, `fromDistance` clipping, degenerate inputs, uneven sample weighting, shade-vs-sun ranking. |
| `CoolMap/Services/AppModel.swift` | `bestShade` replaced by `coolest` + `heatCost(for:)`; `heatCost` added to diagnostics export. |
| `CoolMap/Views/MapScreen.swift` | Route-card label now `routeLabel(_:)` with "Coolest · +N min" and optional "· X% less sun". |

**Not covered / follow-ups**

- `k` is fixed at `RouteHeat.defaultK`; no UI preference for sun sensitivity.
- Remaining-walk recosting via `fromDistance` is exposed in ShadeCore but not yet wired into the walking session UI.

## Feature 6 — Abu Dhabi tree crowns and shade structures (D4)

**What it does**

- `Scripts/build_shade.py` builds `abudhabi-shade.json` for longitude 54.31–54.41 and latitude 24.42–24.52 from Meta canopy height v2 (CC BY 4.0) and OpenStreetMap (ODbL).
- Trees use connected pixels ≥ 3 m, split components over 200 m² on a 25 m grid, keep pieces ≥ 30 m², and simplify pixel-following polygons to ≤ 8 vertices; p90 height, half-height clearance and 0.65 transmissivity remain unchanged.
- OSM adds covered highways, roofs/canopies, shelters and bridges with metre-based buffers and the agreed clearance/transmission defaults. Bridge width is full deck width (half on each side).
- Optional fields remain compatible with today's BuildingRecord decoder; this data-only change does not activate new app behaviour.

**Files changed**

- `Scripts/build_shade.py`, append-only pinned `Scripts/requirements.txt`, `CoolMap/Resources/abudhabi-shade.json`, generated Xcode project and `Verification/d4-crowns-preview.png` (500 m satellite-overlay sanity check).

**Not covered / follow-ups**

- Per-piece quantized footprint area is capped at 115% of source-mask area; the 10 MB budget keeps the largest accurate pieces, so some canopy is omitted. Bridge interiors are explicitly filled because the record contract has no holes; closed-loop bridge centers remain a known limitation.
- Run with a fresh `--cache` directory to refresh source data; failed source downloads fail the build rather than publish a partial dataset. Tree coordinates use 5 decimals, structures 6; canopy-area retention is reported by the generator. Historical byte reproducibility requires the unversioned cached snapshot; fresh live sources can change.

## Feature 7 — Step-free routing (wheelchair & stroller mode)

**What it does**

- **Step-free toggle** (high-contrast, `figure.roll`) at the top of the route options. It is remembered between launches. When on, the app re-ranks the MapKit walking alternatives by accessibility instead of speed and auto-selects the best one.
- **Barrier tagging from OpenStreetMap.** The same route-scoped OSM download that powers shade (`CityBuildingProvider`) is now also parsed for pedestrian barriers (`OSMAccessParser` in ShadeCore, cached per tile under `OSMAccess-v1`):
  - `highway=steps` without `ramp=yes` / `ramp:wheelchair=yes` / `ramp:stroller=yes` / `wheelchair=yes` → **Steps, no ramp** (blocking)
  - `barrier=kerb` + `kerb=raised` → **Raised kerb** (blocking); `kerb=flush|lowered` is fine
  - `wheelchair=no` on any footway/node → **Not wheelchair accessible** (blocking)
  - `incline=*` above **8.3 % (1:12)** → **Incline N%** (slow-down, +2 min penalty). Accepts `12%`, `1:10`, `0.15`, `steep`; `up`/`down` is unknown and ignored.
  - `surface=cobblestone|sett|gravel|unpaved|ground|sand|grass|…` → **Surface: …** (slow-down, +1 min penalty)
  - `highway=elevator` → shown as an elevator marker; only blocking if `wheelchair=no` or a walker has reported it broken.
- **Route scoring** (`StepFreeAssessment`): a barrier counts against a route when it is within 12 m of the route line. Routes with no blocking barrier are "step-free"; among them the lowest adjusted time wins. If every alternative has a barrier, the one with the fewest/least penalised barriers is selected and the card is titled **Fewest barriers**, with a red note "No fully step-free route found".
- **Pace calibration:** with the toggle on, every ETA (route cards, walking screen, arrival estimate, progress) uses `expected × 1.35 + penalties` — a steadier wheelchair/stroller pace.
- **Visualising barriers:** with the toggle on, blocking OSM ways are drawn as solid red lines (dashed for slow-downs) and point barriers get a red marker with a stair / kerb / incline / surface icon on both the route map (Apple) and the walking map. Each route card lists "⚠ N barrier(s): Steps, no ramp, Raised kerb…" or "Step-free ✓ (· N min slower for slope/surface)".
- **Crowdsourced accessibility reports:** three new hazard categories in the report sheet — **Steps / no ramp** (30 d), **Broken elevator** (12 h), **Missing kerb ramp** (30 d). Active reports of these kinds count as blocking barriers in the step-free scoring, so a freshly reported broken lift immediately demotes the route that depends on it. They go through the same Still there? verification loop as other pins.
- **Photo trust markers:** the report sheet has an optional **Add photo** (Photos picker). The photo is downscaled to 1280 px JPEG and stored on-device under `Documents/report-photos/`; it shows as a thumbnail in the Still there? card and in the pin's callout so the next walker can eyeball the ramp/kerb before arriving. Photos are **not** uploaded to Supabase yet.

**Stage demo**

The **Stage demo** button on the walking screen is now a menu with two scenarios: **Fallen tree ahead** (Feature 2) and **Broken elevator (step-free)** — another walker reported "Lift out of service — use the ramp on the north side" 10 minutes ago on your route; the simulated walker approaches it and the Still there? card fires. With Step-free on, the banner reads "step-free pace" and any OSM barriers on the route are drawn in red as the walker passes them. **Stop demo** clears the pin; demo pins are never saved or uploaded.

**Files changed**

| File | Change |
| --- | --- |
| `Sources/ShadeCore/Accessibility.swift` (new) | `AccessBarrier`, `OSMAccessParser`, `RouteAccessibility`, `StepFreeAssessment` (pure Swift). |
| `Tests/ShadeCoreTests/AccessibilityTests.swift` (new) | Parser rules, incline parsing, corridor matching/penalties. |
| `CoolMap/Services/CityBuildingProvider.swift` | `BuildingLoad.barriers`; barriers parsed from the same OSM XML and cached. |
| `CoolMap/Services/AppModel.swift` | `stepFree` (persisted), `barriers`, `reportBarriers`, `accessibility(_:)`, `bestStepFree`, `eta(_:)`. |
| `CoolMap/Services/RouteReports.swift` | New categories (`isAccessBarrier`, `barrierKind`), `RouteReport.photo`, `attachPhoto`, `photoURL`, generalised `plantStageDemo(at:category:note:ageMinutes:)`. |
| `CoolMap/Views/MapScreen.swift` | Step-free toggle, per-route accessibility lines, adjusted ETAs, barrier data passed to the map and walking screen. |
| `CoolMap/Views/BatchedRouteMap.swift` | Red barrier polylines and markers, photo thumbnail in callouts. |
| `CoolMap/Views/WalkingSessionView.swift` | Step-free ETA/progress, barrier overlays, demo menu with the broken-elevator scenario. |
| `CoolMap/Views/HazardReportSheet.swift` | Photo picker in the report sheet, thumbnail in `StillThereCard`. |
| `Backend/reports.sql` | Category constraint extended with the three new categories (re-run if the table exists). |
| `CoolMap.xcodeproj/project.pbxproj` | Regenerated (`Scripts/generate_project.py`) for the new ShadeCore file. |

**Not covered / follow-ups**

- Barriers are only as good as OSM coverage: an untagged flight of steps is invisible, and steps whose end touches the sidewalk within 12 m can flag a route that merely passes them. Elevation-model slope (no `incline` tag) is not computed yet.
- MapKit still produces the candidate routes; the app re-ranks and penalises, it does not compute a detour itself. Google Maps provider does not draw barriers.
- Photo upload/sharing to Supabase; per-account reputation for accessibility reports.

## Feature 8 — Jev reroute-decision API (R-J1)

**What it does**

- `POST /api/reroute-decision` validates a walking-state payload (zod) and returns `{ prompt, urgency, reason, confidence?, debug }` deciding whether to interrupt the walker with a cooler alternative route.
- Deterministic gates run first: a 180 s prompt cooldown and missing alternative stay quiet; blocked/closed/fallen-tree hazards ahead hard-trigger an immediate prompt; alternatives saving under 10% of remaining heat stay quiet.
- Otherwise `lib/weather.ts` fetches the current Dubai-hour temperature from Open-Meteo (10 min per-coordinate cache, 1.5 s timeout, silently optional) and `evaluateWithJev` scores `rerouteWorthIt` (boolean) and `urgency` (0–3); prompting requires probability ≥ 0.6.
- If Jev fails or times out, a rule fallback prompts only when the alternative cuts ≥ 25% of remaining heat for ≤ 3 extra minutes. Debug output lists each question's answer and probability.

**Files changed**

| File | Change |
| --- | --- |
| `Server/lib/reroute.ts` (+ `reroute.test.ts`) | **New.** Request schema, Jev question definitions, `decideReroute` gating/fallback logic + mock-model tests. |
| `Server/lib/weather.ts` (+ `weather.test.ts`) | **New.** `currentTemperature` Open-Meteo lookup with cache + tests. |
| `Server/app/api/reroute-decision/route.ts` (+ `route.test.ts`) | **New.** POST endpoint with 400 validation and decision tests. |
| `Server/package.json`, `Server/pnpm-lock.yaml` | Pin `zod@4.1.12`. |
| `FEATURES.md` | This entry. |

**Not covered / follow-ups**

- Vercel preview pending H1b; no Swift changes here.
- Live Jev/weather calls untested; mock-model tests and a local HTTP POST cover the endpoint.
