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

## Feature 3 — Step-free routing (wheelchair & stroller mode)

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
