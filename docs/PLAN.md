# Coolmap hackathon build plan (3 hours)

An Orca orchestrator runs this file. Two lanes build in parallel as small, gated PRs:

- **Data lane (iOS):** Abu Dhabi building and tree data, a heat-weighted route score, partial shade from trees and canopies.
- **Re-route lane (Jev):** live "a cooler way is available" prompts while walking, decided by Jev (`typesafe-ai/jev` via Vercel AI Gateway).

It supersedes the scope of `~/.devin/plans/plan-dc3a83134a256f7b.md` for this hackathon. That file keeps the longer Jev roadmap: report triage, segment scoring, city dashboard.

---

## 0. How the orchestrator uses this file

1. Read the whole file. Create one Run and every Task in §6 with its `deps`, then dispatch everything that is ready (§8).
2. Keep **at most 6 builders live**: 3 per lane.
3. Enforce §4 yourself. Never accept a builder's claim that checks passed without re-running them.
4. Keep to the clock in §5. At each checkpoint, apply the cut list in §5.1 if the lane is behind.
5. **Never edit code.** Fixes go back to the builder's terminal.
6. Ask the user only at the human steps (§7), the checkpoints, and on escalations.

---

## 1. Context for every task spec (paste verbatim)

- **App:** native SwiftUI/MapKit iOS app in `CoolMap/`, plus the pure Swift package `Sources/ShadeCore` (geometry, solar maths, exposure; no UIKit/MapKit).
- **The Xcode project is generated** by `Scripts/generate_project.py`:
  - It globs `Sources/ShadeCore/*.swift`, `CoolMap/**/*.swift` and `CoolMap/Resources/*.json`.
  - Never hand-edit `CoolMap.xcodeproj`. After adding or removing files run `python3 Scripts/generate_project.py`.
  - Resolve any `project.pbxproj` conflict by regenerating, never by hand-merging.
- **Setup:** `Scripts/setup.sh`. Add `--test` for core tests, `--run` to build and launch on a simulator.
  - Orca runs it automatically for every new worktree (`orca.yaml`).
  - Orca also copies `Config/Local.xcconfig` and `Server/.env.local` from the main checkout into the worktree (`.worktreeinclude`), so builders never need the key pasted in.
- **Config pattern:**
  - Keys live in `Config/Local.xcconfig` (gitignored), flow into Info.plist keys in `generate_project.py`, and are read in `CoolMap/Services/AppConfiguration.swift`.
  - **An empty key means the feature is off.**
  - xcconfig treats `//` as a comment, so URLs must be written `https:/$()/host.example`.
- **Shade model today:**
  - `ShadeEngine.classify` casts a ray toward the sun and returns sun or shade per 4 m sample.
  - `RouteExposureService` turns samples into sun seconds.
  - `AppModel.load()` gets routes, then buildings (`CityBuildingProvider`, live OSM API), then runs `recalculate()`.
- **Team convention:**
  - Every feature PR appends one entry to `FEATURES.md`, following the existing format.
  - On a conflict there, keep both entries.
  - Teammates also push to `main`, so rebase on `origin/main` right before requesting review.
- **Scope decisions already made:**
  - City: **Abu Dhabi**.
  - Building heights: GlobalBuildingAtlas (CC BY-NC, fine for the hackathon), overridden by OSM `height` tags.
  - Trees: Meta canopy height map v2 (CC BY 4.0), with every tree treated as a palm that lets 65% of sunlight through.
  - Ranking: heat dose (option B).
- **Verified data access** (no account, no key):
  - GlobalBuildingAtlas: `https://data.source.coop/tge-labs/globalbuildingatlas-lod1/e050_n25_e055_n20.parquet`. Columns: `source,id,height,var,region,bbox{xmin,ymin,xmax,ymax},geometry(WKB)`. Read it with DuckDB `httpfs`, filtering on `bbox`. Central Abu Dhabi returns about 13.5k buildings in about 7 s, all with heights. Towers are underestimated (maximum about 95 m).
  - Meta canopy height v2: `https://data.source.coop/tge-labs/meta-chm-v2/`. Find tiles with `tiles.parquet` (`quadkey, cog_url, bbox_3857`); pixels are uint8 metres in EPSG:3857 at about 1.2 m. Central Abu Dhabi is tile `1230233010`, with canopy ≥ 3 m on 6.1% of the area.
  - OSM: Overpass. The main server is often busy; fall back to `https://overpass.private.coffee/api/interpreter`. Always send a User-Agent.
- **Jev:**
  - An evaluation model. The input is a `state` string or JSON plus named `questions` (`boolean` / `score` / `choice`). The output is typed answers with probabilities. It generates no text.
  - AI SDK: `experimental_evaluate` from `ai` ≥ 7.0.105.
  - Test with `Experimental_EvaluationMockModelV4` from `ai/test`.
  - HTTP: `POST https://ai-gateway.vercel.sh/v1/evaluate`.
  - Always send `providerOptions.gateway.zeroDataRetention: true`.
  - The Gateway key lives only in Vercel env and in `Server/.env.local`, never in the app or git.

---

## 2. Roles

| Role | Model | Does | Never does |
|---|---|---|---|
| Orchestrator | Opus 5.5 High | Creates the DAG, dispatches, re-runs gates, synthesises reviews, keeps the clock | Edits code, merges |
| Builder | SWE 2 | One task, own worktree and branch, self-verifies, opens a draft PR | Touches files outside Ownership |
| Reviewer | Astra 6 | Read-only review against spec and gates; replies APPROVE or CHANGES with file:line findings | Edits code |
| Labeller | Astra 6 | Writes the re-route eval scenarios independently | Reads `Server/lib/reroute*` |
| Human | you | Vercel link and key, merging PRs, making the repo public | — |

Launch placeholders (substitute real Orca IDs):
- `BUILDER = --agent <swe2-agent> --model <swe2-model>`
- `REVIEWER = --agent <astra6-agent> --model <astra6-model>`

---

## 3. Rules for every task

1. **One task, one branch, one draft PR.**
   - Branch `hk/<TASK>-<slug>`; worktree `--worktree new-top-level --name hk-<task>`; base `origin/main`.
   - Open the PR with `gh pr create --draft`.
2. **≤ 400 changed lines**, excluding generated `project.pbxproj`, lockfiles and data JSON. If it will be bigger, stop and ask the orchestrator to split it.
3. **Timebox: 35 minutes of building.** At 35 minutes, push what works, mark what's missing in the PR, and send `worker_done` with an honest outcome.
4. **`main` stays shippable.**
   - New app behaviour is either off behind an empty config key, or is covered by the smoke test.
   - Server endpoints are additive.
5. **Hotspot files** (several tasks touch them): `AppModel.swift`, `MapScreen.swift`, `WalkingSessionView.swift`, `ShadeEngine.swift`, `generate_project.py`, `FEATURES.md`.
   - Keep edits additive and local.
   - Don't reformat or reorder.
   - Rebase right before review.
6. **Match existing style:** compact Swift, existing naming, no new comments unless needed. Server code is TypeScript strict.
7. **Dependencies:**
   - Pin exact versions released at least 7 days ago; no `latest`.
   - Python tools go in `Scripts/requirements.txt`: `duckdb==1.3.2`, `rasterio==1.4.3`, `numpy`, `shapely`.
8. **Failures degrade safely:**
   - Missing data leads to the existing "Shade not available" path.
   - Jev failure falls back to the deterministic rule in R-J1; it never crashes and never blocks the walk.
9. **Jev never touches deterministic numbers.** Heat, sun minutes and shade stay in ShadeCore. Jev only decides whether to interrupt the walker.

---

## 4. Quality gates

### 4.1 Checks (built in D0, used everywhere)

| ID | Command | Proves |
|---|---|---|
| `C-core` | `Scripts/verify.sh core` | ShadeCore `swift test` green |
| `C-app` | `Scripts/verify.sh app` | App compiles for the iOS Simulator |
| `C-smoke` | `Scripts/smoke.sh` | App launches with `--demo-autoload`; `Documents/last-analysis.json` has ≥ 1 route with a numeric `sunSecondsUpperEstimate`; screenshot saved |
| `C-server` | `pnpm -C Server check` (`tsc --noEmit && eslint . && vitest run`) | Server types, lint, tests |
| `C-secrets` | `git diff origin/main... \| grep -nE '(sk-\|eyJ[A-Za-z0-9_-]{20,}\|service_role\|AI_GATEWAY_API_KEY=.+)'` returns nothing | No leaked secrets |
| `C-size` | `git diff --stat origin/main...`, excluding pbxproj, lockfiles and data JSON, ≤ 400 lines | Reviewable |
| `C-scope` | Every changed path is inside the task's Ownership | No drive-by edits |

`C-smoke` uses a lock (`mkdir /tmp/coolmap-smoke.lock`), because every worktree installs the same bundle ID on the same simulator. Only one smoke run happens at a time.

### 4.2 Per-PR gate

1. **Builder self-check:** runs the task's Acceptance checks and pastes the output into the PR body.
2. **Orchestrator re-run:** `C-scope`, `C-size`, `C-secrets` plus the task's checks, in the task worktree. Any failure goes back to the builder.
3. **Review:** a read-only Astra 6 review with APPROVE or CHANGES. It checks:
   - Is every acceptance item met, with evidence?
   - Would the tests fail if the feature broke?
   - Is failure behaviour safe?
   - Is behaviour unchanged with flags off?
   - Is anything out of scope?
4. **At most one fix loop** (time budget). A second CHANGES verdict escalates to the user with both positions summarised.
5. **Ready:** the orchestrator marks the PR ready and comments with the gate evidence. **The user merges.**
6. **Post-merge:** the orchestrator runs `C-core`, `C-app`, `C-smoke` on fresh `origin/main`. If any fails, revert that PR immediately (`gh pr revert` or a revert commit PR) and pause the lane.

### 4.3 Checkpoints

| Checkpoint | Clock | Pass condition |
|---|---|---|
| `CP1` | 0:50 | Wave 1 merged; post-merge checks green on `main`; Server deployed to a Vercel preview (H1) |
| `CP2` | 1:55 | Wave 2 merged; post-merge checks green; the app routes in Abu Dhabi with the new data |
| `CP3` | 2:35 | **Feature freeze.** Wave 3 merged or cut; final smoke; demo script run once end to end |

---

## 5. Clock

| Clock | Data lane | Re-route lane |
|---|---|---|
| 0:00–0:45 | **Wave 1:** D0 checks · D1 heat score · D2 buildings data · D4 shade data | **Wave 1:** R-J0 server scaffold · R-L scenarios · R-A1 off-route tracker |
| 0:45–0:50 | CP1 | CP1 |
| 0:50–1:50 | **Wave 2:** D3 partial-shade engine · D5 Abu Dhabi data + switch · D6 best time to leave | **Wave 2:** R-J1 re-route endpoint · R-A2 app integration (flag off) |
| 1:50–1:55 | CP2 | CP2 |
| 1:55–2:35 | **Wave 3:** D7 partial shade in the app | **Wave 3:** R-E eval + end-to-end demo run |
| 2:35–3:00 | CP3: freeze, final smoke, demo script, README, repo public (H3) | |

### 5.1 Cut list (drop from the top if a lane is behind at a checkpoint)

1. D6 best time to leave
2. R-E eval (keep the end-to-end demo run)
3. D7 partial shade in the app (D3 still improves the numbers without it)
4. D4 trees/structures data

**Never cut:** D0, D1, D2, D5, R-J0, R-J1, R-A2.

---

## 6. Task DAG

Every build task `X` implicitly gets review `X.R` (deps `[X]`) and an optional fix `X.F` (§4.2).

### Wave 1 (all start at 0:00)

**D0 Checks: `verify.sh` + `smoke.sh`** · deps `[]`
- **Target:** new `Scripts/verify.sh` (`core` | `app` | `all`), new `Scripts/smoke.sh`, one README line.
- **Change:**
  - `verify.sh core` runs the README `swift test` command.
  - `verify.sh app` runs `Scripts/setup.sh`, then `xcodebuild -project CoolMap.xcodeproj -scheme CoolMap -destination 'generic/platform=iOS Simulator' -quiet build`.
  - `smoke.sh`:
    - picks the booted iPhone simulator, else the newest (reuse the `setup.sh` logic);
    - takes the lock;
    - builds, installs, and runs `simctl launch --terminate-running-process <udid> com.hendrix.coolmap --demo-autoload`;
    - polls `$(simctl get_app_container <udid> com.hendrix.coolmap data)/Documents/last-analysis.json` for up to 90 s;
    - validates the file with `python3`;
    - saves a screenshot to `Verification/smoke/<short-sha>.png` (gitignored);
    - exits non-zero on failure and always releases the lock.
- **Constraints:** no app code changes; Apple Maps path only.
- **Ownership:** `Scripts/verify.sh`, `Scripts/smoke.sh`, `.gitignore` (one line), `README.md` (one line), `FEATURES.md`.
- **Acceptance:**
  - `verify.sh all` and `smoke.sh` pass on a clean worktree.
  - Breaking a ShadeCore test makes `verify.sh core` exit non-zero. Show it in the PR, then revert.

**D1 Heat score + "Coolest route"** · deps `[]`
- **Target:** new `Sources/ShadeCore/HeatScore.swift` plus tests; `AppModel.swift` (ranking only); `MapScreen.swift` (route card text only).
- **Change:**
  - `SunIntensity.weight(elevationDegrees:) -> Double`, normalised so the peak is 1, and 0 at or below the horizon. It is `f_p·DNI`, where:
    - `f_p = 0.308·cos(β·(0.998 − β²/50000))`, with β in degrees;
    - `DNI = 1353·0.7^(AM^0.678)`;
    - `AM = 1/(sin h + 0.50572·(h+6.07995)^−1.6364)`, the Kasten–Young air mass.
  - `extension ShadeDecision { var sunFraction: Double { directSun ? 1 : 0 } }`. D3 replaces this with a stored value.
  - `RouteHeat.cost(_ exposure: RouteExposure, expectedTravelTime:, k: Double = 2, fromDistance: Double = 0) -> Double`:
    - it sums, over samples from `fromDistance` onward, `seconds_i × (1 + k × sunFraction_i × weight_i)`;
    - `seconds_i` is the sample's share of travel time.
  - `AppModel`:
    - `coolest: UUID?` is the lowest heat cost among routes with exposure. It replaces the `bestShade` gating on unknown heights, so it shows even when some heights are estimated.
    - Also expose `heatCost(for:)`.
    - Add `heatCost` per route to `exportDiagnostics`.
  - Route card label: "Coolest · +N min · X% less sun" versus the fastest route. When fastest and coolest are the same route, the label is "Fastest · coolest".
- **Constraints:** no change to `ShadeEngine`/`RouteExposureService` logic; `k` lives in one constant.
- **Ownership:** `HeatScore.swift`, `Tests/ShadeCoreTests/HeatScoreTests.swift`, the named sections of `AppModel.swift` and `MapScreen.swift`, `FEATURES.md`.
- **Acceptance:**
  - `C-core` passes, with tests for:
    - weights at 10/20/30/45/60/75/85° ≈ 0.64/0.92/1.00/0.94/0.78/0.56/0.43 (±0.03);
    - night weight 0;
    - an all-shade route costing its travel time;
    - `fromDistance` halving the cost of a uniform route.
  - `C-app` and `C-smoke` pass.

**D2 Abu Dhabi buildings data** · deps `[]`
- **Target:** new `Scripts/build_buildings.py`, `Scripts/requirements.txt`, output `CoolMap/Resources/abudhabi-buildings.json`, one new `HeightSource` case.
- **Change:**
  - Area: bbox `lon 54.31–54.41, lat 24.42–24.52`.
  - Read GlobalBuildingAtlas via DuckDB `httpfs` for that area.
  - Fetch OSM buildings with `height` / `building:levels` for the same area through Overpass (with the fallback server).
  - Match OSM to GBA by footprint overlap: centroid inside, or IoU > 0.3.
  - Height priority: OSM `height`, then OSM `building:levels` × 3.5 m, then GBA `height`.
  - Write `[BuildingRecord]` JSON with `heightSource` set to `exact`, `levelsEstimate`, or a new `model` case (add `case model` to `HeightSource` in `ShadeEngine.swift`).
  - Round coordinates to 6 decimals; drop footprints smaller than 15 m².
  - Target ≤ 15 MB. If bigger, shrink the bbox and say so.
  - Print stats: count; share from OSM `height`, levels, and GBA; the 10 tallest buildings with names.
- **Constraints:** don't change the app's loading (that's D5); no network calls from the app.
- **Ownership:** `Scripts/build_buildings.py`, `Scripts/requirements.txt`, `CoolMap/Resources/abudhabi-buildings.json`, `ShadeEngine.swift` (one enum case), a new ShadeCore test, generated pbxproj, `FEATURES.md`.
- **Acceptance:**
  - The script reruns reproducibly.
  - The stats are in the PR, and the 10 tallest include real towers with plausible heights: at least one ≥ 150 m, which proves the OSM override worked.
  - A ShadeCore test decodes the file and asserts every record has a height and a valid polygon.
  - `C-app` passes.

**D4 Trees + shade structures data** · deps `[]`
- **Target:** new `Scripts/build_shade.py`, output `CoolMap/Resources/abudhabi-shade.json`.
- **Contract:** the output is `[BuildingRecord]` JSON with **extra optional fields** that D3 will decode: `minHeightMeters`, `transmissivity`, `kind` (`tree|canopy|covered|shelter|bridge`).
- **Change** (same bbox as D2):
  - **Trees:**
    - Read Meta canopy height v2 for the bbox.
    - Take pixels ≥ 3 m, group them into connected components, and turn each into a crown polygon (simplified convex hull, ≤ 12 points).
    - Drop crowns smaller than 4 m².
    - `height` = the 90th percentile of the crown's pixels; `minHeightMeters` = 0.5 × height; `transmissivity` = 0.65; `kind` = `tree`.
  - **Structures from OSM:**
    - `covered=yes|arcade|colonnade` highways: buffer 1.5 m each side; min 2.5 m, height 4 m, transmissivity 0.
    - `building=roof`, `man_made=canopy`: min 2.5 m, height from tag or 4 m, transmissivity 0 (0.1 if `material=fabric`).
    - `amenity=shelter`: polygon, or a 3×2 m box at a node; min 2 m, height 3 m, transmissivity 0.
    - `bridge=yes|viaduct` ways: buffer by `width` or 8 m; min 5 m, height 7 m, transmissivity 0.
  - Print counts per kind.
- **Constraints:** no Swift changes. The file must still decode with today's `BuildingRecord`, which ignores unknown keys.
- **Ownership:** `Scripts/build_shade.py`, `Scripts/requirements.txt` (append only), `CoolMap/Resources/abudhabi-shade.json`, generated pbxproj, `FEATURES.md`.
- **Acceptance:**
  - Stats are in the PR.
  - The file is ≤ 10 MB.
  - A PNG preview of crowns over one 500 m block (matplotlib is fine) is attached to the PR, to sanity-check against satellite imagery.
  - `C-app` passes.

**R-J0 Server scaffold** · deps `[]`
- **Target:** new Next.js App Router app in `Server/` (TypeScript strict, pnpm, ESLint, Vitest), plus a short `Server/README.md`.
  - `Server/.env.example` already exists: keep it, and add any new variables to it.
  - If the scaffolder refuses a non-empty folder, scaffold into a temporary folder and move the files in.
- **Change:**
  - `lib/jev.ts`: `evaluateWithJev({state, questions, model?})` wraps `experimental_evaluate` with `zeroDataRetention`, a 3 s AbortSignal timeout, and returns `{ok:true, answers, probabilities} | {ok:false, reason}`. The model is injectable.
  - `app/api/health/route.ts`.
  - A `check` script.
- **Constraints:** `ai` ≥ 7.0.105 pinned (if it's younger than 7 days, flag it to the orchestrator); `.env*` stays gitignored.
- **Ownership:** `Server/**`, `FEATURES.md`.
- **Acceptance:**
  - `C-server` passes, with tests for success, timeout → `ok:false`, and missing probabilities.
  - `pnpm -C Server dev` + `curl localhost:3000/api/health` returns 200.

**R-L Re-route scenarios** · labeller · deps `[]`
- **Target:** `Server/eval/reroute.scenarios.json`.
- **Change:**
  - 24 scenarios in the §6.1 request shape, each labelled `should_prompt` or `stay_quiet` with a one-line rationale.
  - Mix:
    - 8 clear wins (≥ 30% less heat, ≤ 2 min extra);
    - 6 marginal cases;
    - 4 "just prompted";
    - 3 near sunset;
    - 3 with hazards ahead.
- **Constraints:** do not read `Server/lib/reroute*`.
- **Ownership:** that file only.
- **Acceptance:** valid JSON against the §6.1 shape; the reviewer spot-checks 6 labels.

**R-A1 Off-route tracker** · deps `[]`
- **Target:** `Sources/ShadeCore/WalkingProgress.swift` (additive), tests.
- **Change:** `OffRouteTracker` with `mutating update(distanceOffRoute: Double, at: Date) -> (meters: Double, seconds: Double)`. The clock resets once the walker is back within 25 m.
- **Ownership:** `WalkingProgress.swift`, `Tests/ShadeCoreTests/WalkingCameraTests.swift` or a new test file, `FEATURES.md`.
- **Acceptance:** `C-core` passes, with tests for:
  - staying on route → 0 seconds;
  - 40 m off for 30 s → 30 seconds;
  - returning to the route resets the clock.

### Wave 2 (starts as deps merge, target 0:50)

**D3 Partial-shade engine** · deps `[D1]`
- **Target:** `ShadeEngine.swift`, `Geometry.swift`, `BuildingData.swift`, `RouteExposureService.swift`, `RouteDisplayRun.swift`, `HeatScore.swift` (remove the D1 shim), tests.
- **Change:**
  - `BuildingRecord` and `BuildingGeometry` gain `minHeightMeters` (default 0), `transmissivity` (default 0) and `kind`, all optional in JSON.
  - `RayIntersection.polygonSpan` returns entry and exit distances.
  - In `classify`:
    - For each hit, the ray is at heights `[d_in·tanβ, d_out·tanβ]` while it crosses the footprint. It is blocked if that range overlaps `[minH, H]`.
    - Multiply the transmissivities of the blocking objects together. Stop when the result is ≤ 0.01.
    - `ShadeDecision` gains a stored `sunFraction`. `directSun` = `sunFraction ≥ 0.5`.
  - `RouteExposure` weights sun distance and seconds by `sunFraction`.
  - `RouteDisplayRun` kinds: 0 night, 1 sun (≥ 0.8), 2 shade (≤ 0.2), 3 partial.
  - Add a uniform 50 m grid index to `PreparedBuilding.prepare`, so `classify` only checks cells along the ray.
- **Constraints:**
  - Existing tests must pass unchanged. Solid buildings (min 0, transmissivity 0) must give identical results.
  - Don't touch the app UI (that's D7).
- **Acceptance:** `C-core` passes, with new tests for:
  - one palm → 0.65;
  - two palms → 0.4225;
  - a canopy at 2.5–4 m shading a point under it at 60° sun;
  - the ray passing under a bridge at low sun but blocked at high sun;
  - a performance check: 50k objects × 1,000 samples in < 2 s (release build).

  `C-app` and `C-smoke` pass.

**D5 Abu Dhabi data + app switch** · deps `[D0, D2]`
- **Target:** `MapServices.swift` (`LocalBuildingProvider`), `CityBuildingProvider.swift`, `AppModel.swift`, `MapScreen.swift` (demo and labels only), `DestinationSearchView.swift`, `GoogleServices.swift` (location bias only).
- **Change:**
  - **Buildings:** load `abudhabi-buildings.json` once into memory and filter by the route's bbox plus buffer, as `LocalBuildingProvider` does today. If routes fall inside the Abu Dhabi bbox, use this data (`completeFetch = true`, note "Buildings: OpenStreetMap + GlobalBuildingAtlas estimates"). Otherwise use the existing live OSM path.
  - **Shade objects:** also merge `abudhabi-shade.json` if present.
  - **Switch the app to Abu Dhabi:**
    - `inCoverage` → the Abu Dhabi bbox;
    - search region and Google bias centre → 24.47, 54.37;
    - initial map region;
    - "Explore Abu Dhabi" quick picks: Corniche Beach, Qasr Al Watan, Central Market / World Trade Center, Abu Dhabi Mall;
    - "Dubai time" labels → "UAE time";
    - `--demo-autoload` and the "Try a walk" shortcut → a short Corniche walk with a fixed hour of 16:00.
  - Remove the Marina-only detour waypoint in `DirectionsService`.
- **Constraints:** no ShadeCore changes; Google path unchanged apart from the bias.
- **Acceptance:**
  - `C-app` and `C-smoke` pass; the smoke JSON shows Abu Dhabi coordinates and non-null exposure.
  - A screenshot of a Corniche route with coloured sun/shade is in the PR.

**D6 Best time to leave** · deps `[D1]` · first to cut
- **Target:** `AppModel.swift` (new function), `MapScreen.swift` (one chip).
- **Change:**
  - For the selected route, compute `RouteHeat.cost` at departures every 30 min over the next 12 h. Reuse the samples and re-run only the solar and shade classification, off the main thread.
  - If the best departure saves ≥ 25% of the heat, show a chip: "Leave at 17:30 · 40% less heat". Tapping it sets the departure time.
- **Acceptance:** a ShadeCore test of the pure part (e.g. `RouteHeat` at night is the time only); `C-app` and `C-smoke` pass; a screenshot.

**R-J1 `POST /api/reroute-decision`** · deps `[R-J0]` (R-L is used in its tests if merged)
- **Target:** `Server/app/api/reroute-decision/route.ts`, `Server/lib/reroute.ts` plus tests, `Server/lib/weather.ts`.
- **Contract:** §6.1.
- **Change:**
  1. **Validation:** zod.
  2. **Rules in code, applied first:**
     - `secondsSinceLastPrompt < 180` → no.
     - No alternative → no.
     - A `blocked` hazard ahead on the current route and an alternative exists → prompt with `reason: hard_trigger`.
     - Alternative heat not at least 10% lower → no.
  3. **Otherwise, ask Jev:**
     - State: the request, plus the current temperature from Open-Meteo (`api.open-meteo.com/v1/forecast?...&hourly=temperature_2m&timezone=Asia/Dubai`, cached 10 min, left out on failure).
     - Questions: `rerouteWorthIt` (boolean) and `urgency` (score 0–3), each with explicit criteria. The criteria cover heat saved versus extra time, the temperature, how close sunset is, how long the walker has been walking, and hazards.
     - Prompt when `P(rerouteWorthIt) ≥ 0.6`.
  4. **If Jev fails:** deterministic fallback. Prompt if heat saved ≥ 25% and extra time ≤ 180 s, with `reason: rule`.
  - Response: `{prompt, urgency, reason: "hard_trigger"|"jev"|"rule"|"none", confidence?}`.
- **Acceptance:**
  - `C-server` passes, with tests (mock model) for each rule branch, Jev yes and no, Jev timeout → rule, and weather failure.
  - Deployed to the Vercel preview (H1); `curl` against the preview with a sample body returns 200.

**R-A2 Walking-session re-route (flag `REROUTE_API_URL`)** · deps `[D1, R-A1]`, codes against §6.1
- **Target:**
  - `WalkingSessionView.swift`;
  - new `CoolMap/Services/RerouteService.swift`;
  - `AppModel.swift` (one helper);
  - `AppConfiguration.swift`, `Config/Local.xcconfig.example`, `generate_project.py` (one `INFOPLIST_KEY_REROUTE_API_URL` line).
- **Change:**
  - `route` becomes `@State`.
  - Every 30 s, while following GPS, or after 20 s off route:
    - request routes from the current fix to the destination through `DirectionsService`;
    - compute exposure and `RouteHeat` with the same pipeline (`AppModel` helper `evaluate(routes:departure:) async`);
    - compare the remaining heat on the current route (`fromDistance` = progress) with the best alternative;
    - count active hazards within 30 m of the remaining route (`RouteReportStore.shared.active`);
    - POST the §6.1 body with a 4 s timeout.
  - On `prompt: true`, show a non-modal banner: "Cooler way available · 40% less sun · +1 min" with [Switch] and [Dismiss]. Switch replaces `route` and resets the tracker.
  - Record `lastPromptAt`.
  - An empty key means none of this runs and behaviour is exactly as today.
- **Constraints:** don't break the existing hazard button or steps; no network on the main thread; failures are silent.
- **Acceptance:**
  - `C-app` and `C-smoke` pass with the key empty.
  - A ShadeCore test covers the remaining-heat comparison.
  - The PR describes a manual check with the key set to the preview URL.

### Wave 3 (target 1:55)

**D7 Partial shade in the app** · deps `[D3, D5]` (D4 optional)
- **Target:** `BatchedRouteMap.swift`, `MapScreen.swift` (legend and text), `RouteReports` untouched.
- **Change:**
  - Draw kind 3 (partial) in yellow, and add "Partial shade (trees)" to the legend.
  - The sun text reads "Up to X min sun · Y min partial".
  - Tree crowns are drawn in faint green only when "Debug shade on map" is on.
- **Acceptance:** `C-app` and `C-smoke` pass; a screenshot of a Corniche route with yellow segments.

**R-E Eval + end-to-end run** · deps `[R-J1, R-L, R-A2]`
- **Change:**
  - `pnpm -C Server eval:reroute` runs the 24 scenarios against real Jev and writes `Server/eval/results/reroute-<date>.md`.
  - Target: prompts on every `should_prompt` and on ≤ 10% of `stay_quiet`. Otherwise, report the gap.
  - Then the end-to-end run:
    - build with `REROUTE_API_URL` set to the preview;
    - run `xcrun simctl location <udid> start --speed=1.4 <lat,lon waypoints>`, walking off the planned Corniche route toward a sunnier street;
    - capture the banner screenshot and a short screen recording (`simctl io recordVideo`).
- **Acceptance:** the results file and media are in the PR; `C-server` passes.

### 6.1 Re-route contract (fixed up front so R-J1 and R-A2 build in parallel)

```json
POST /api/reroute-decision
{ "lat": 24.47, "lon": 54.37, "localTime": "2026-09-25T16:05:00+04:00",
  "offRouteMeters": 0, "offRouteSeconds": 0, "walkedSeconds": 300, "secondsSinceLastPrompt": 9999,
  "minutesToSunset": 140,
  "current":     { "remainingSeconds": 600, "remainingHeat": 1500, "remainingSunSeconds": 420 },
  "alternative": { "totalSeconds": 660, "heat": 950, "sunSeconds": 120 },
  "hazardsAhead": [ { "category": "Blocked crossing", "metersAhead": 120 } ] }
→ 200 { "prompt": true, "urgency": 2, "reason": "jev", "confidence": 0.82 }
```

`alternative` may be `null`. `heat` values come from `RouteHeat.cost`.

### Dependency overview

```
D0 ──────────────┐
D2 ──────────────┴─ D5 ─┐
D1 ─┬─ D3 ──────────────┴─ D7   (D4 feeds D5/D7 data)
    ├─ D6
    └────────┐
R-A1 ────────┴─ R-A2 ─┐
R-J0 ─ R-J1 ──────────┼─ R-E
R-L ──────────────────┘
```

---

## 7. Human steps

| ID | You do | When |
|---|---|---|
| H0 | Nothing: `main` is pushed with this plan and `Scripts/setup.sh` | Done |
| H1a | Paste the key into `Server/.env.local` in the **main checkout**. Orca copies it into each new worktree. | Before launch |
| H1b | After R-J0 merges: `cd Server && vercel link`, add `AI_GATEWAY_API_KEY` to the Vercel project env (Preview and Production), then `vercel deploy`. Give the orchestrator the preview URL. | ≈ 0:45 |
| H2 | Merge PRs the orchestrator marks ready | Continuous |
| H3 | Make the GitHub repo public, or invite the judges | 2:50 |

---

## 8. Orchestrator runbook (Orca)

```text
orca status --json
orca orchestration run-create --objective "Coolmap hackathon per docs/PLAN.md" --json
# Create every task up front with real deps; keep the returned IDs
orca orchestration task-create --task-title "D0 checks" --spec "<§1 + D0 + §3 + §4.2>" --json
orca orchestration task-create --task-title "D3 partial-shade engine" --spec "..." --deps '["<D1_id>"]' --json
...
orca orchestration task-list --ready --brief --json
# Builders: fresh worktree per task on origin/main
orca orchestration worker-start --task <id> --worktree new-top-level --name hk-d0 --base-branch origin/main <BUILDER> --json
# Reviewers: read-only on the builder's worktree
orca orchestration worker-start --spec "<review prompt + PR URL>" --worktree name:hk-d0 <REVIEWER> --json
orca orchestration check --wait --types "worker_done,escalation,question" --timeout-ms 600000 --json
# Fix loop: reuse the builder terminal
orca orchestration worker-start --task <X.F_id> --terminal <builder_handle> --worktree name:hk-d0 --json
# After every accepted settlement: reuse, retain, or release
orca orchestration worker-release --dispatch <dispatch_id> --json
```

**Loop policy:**
- Dispatch the review as soon as a build settles and its re-run checks pass.
- Tell the user the moment a PR is ready to merge.
- After each merge, run §4.2 step 6 on `main`, then start the tasks it unblocked.
- Report at each checkpoint: tasks, PR links, gate evidence, what was cut.

**Review prompt (Astra 6):**
> You are reviewing PR `<url>` for task `<X>`. The spec, rules and gates are below. Read-only. Answer each acceptance item with evidence (file:line or command output). Check that the tests are meaningful, failure is safe, flags-off behaviour is unchanged, and the change stays in scope. Check for secrets. Verdict: APPROVE, or CHANGES with numbered findings (blocker/major/minor). Minor-only findings mean APPROVE.

---

## 9. Demo script (CP3)

1. Launch the app, then choose Corniche → Qasr Al Watan.
2. The route cards show the fastest route next to "Coolest · +2 min · 40% less sun".
3. Drag the sun slider from 10:00 to 17:00 and watch the shade and the partial tree shade move. Tap "Leave at 17:30".
4. Start the walk. The simulated GPS drifts onto a sunny street, and the "Cooler way available" banner appears (decided by Jev). Tap Switch.
5. Report a hazard ("Blocked crossing") ahead. On the next check, the re-route triggers.
6. Close on the data slide:
   - 13.5k Abu Dhabi buildings, every one with a height;
   - OSM tower heights layered on top;
   - 1.2 m tree canopy data;
   - ties to the Abu Dhabi Public Realm Design Manual and Estidama outdoor-comfort goals.
