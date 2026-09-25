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
