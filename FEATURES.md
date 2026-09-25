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

**Demo mode (for showing the flow without a route or other users)**

Map settings (slider icon) → **Demo mode**. It plants four sample community pins around your position (fallen tree, fenced-off crossing, broken sidewalk, no shade) and lists "Walk into: …" buttons — tapping one closes the sheet and fires the Still there? popup exactly as a real approach would. A "Demo: walk into …" chip also sits bottom-left on the map and walking screens so you can trigger the next one mid-demo. Demo pins live in memory only: never saved to disk, never uploaded, and votes on them aren't sent.

**Files changed**

| File | Change |
| --- | --- |
| `CoolMap/Services/RouteReports.swift` | `RouteReport` gains `confirmedAt`, `denials` (backwards-compatible decoding); `expiresAt` counts from the last confirmation; `isActive` also requires `denials < 2`. New `WalkerReputation`. `RouteReportStore` gains `verification`, `checkProximity(to:)`, `answerVerification(stillThere:)`, `dismissVerification()`, haversine `distance`, vote upload; demo mode (`demo`, `plantDemoHazards(around:)`, `nextDemoHazard`, `simulateApproach(to:)`). |
| `CoolMap/Views/HazardReportSheet.swift` | New `StillThereCard` (icon, "Still there" / "Not there", 8 s timeout bar). |
| `CoolMap/Views/MapScreen.swift`, `WalkingSessionView.swift` | Feed location fixes into `checkProximity`, show the card at the top; Demo section in Map settings and demo chip. |
| `Backend/reports.sql` | New `route_report_votes` table + insert policy. |

**Not covered / follow-ups**

- Server-side aggregation of votes (extend/clear for *all* users) — currently each device applies its own vote locally and uploads it.
- Route-aware pre-alerting ("hazard ahead in 200 m along your route") — trigger is pure proximity for now.
