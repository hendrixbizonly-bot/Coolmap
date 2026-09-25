# Connect Google Maps and shared reports

No accounts or billing have been created or activated by this project.

## Google Maps

1. Create a Google Cloud project and enable billing, Maps SDK for iOS, Routes API, and Places API (New).
2. Create a Maps SDK key restricted to iOS bundle `com.hendrix.coolmap` and the Maps SDK for iOS API.
3. Create a separate key for Routes/Places calls with appropriate API and iOS application restrictions. The client sends `X-Ios-Bundle-Identifier`. Check Google’s mobile web-service security guidance; use a protected server proxy for production where restrictions cannot adequately protect calls.
4. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill `GOOGLE_MAPS_API_KEY` and `GOOGLE_SERVICES_API_KEY` locally. Do not paste them into chat or commit them.
5. Rebuild in Xcode. Both keys must be present to switch the map, search and routing together. Without them the app explicitly stays on Apple Maps. Google SDK 11.1.0 is pinned through SPM.
6. Set quotas/budget alerts in your own account. Test actual key authorization and billing before release. These cannot be validated without your project.

Google-route polylines are only rendered on Google Maps. The Google renderer preserves its attribution. No Google service data is included in the OSM cache.

https://developers.google.com/maps/documentation/ios-sdk/config
https://developers.google.com/maps/api-security-best-practices
https://developers.google.com/maps/documentation/routes/policies

## Shared reports

Profiles and points use Supabase Auth and PostgreSQL. No live project has been provisioned by Codex; these steps must be completed in your own Supabase account.

1. Create a Supabase project. Keep the database password in your password manager; it does not belong in the app or in chat.
2. Open **SQL Editor**. For a fresh database, run `Backend/reports.sql` once, then run **`Backend/profiles.sql`**. For a project already using the original reports table, run only `profiles.sql`. The profile migration can be rerun safely. Do not run the old reports schema after the profile migration: it describes the retired anonymous write API.
3. Enable the **Email** provider under Authentication. In **Email Templates → Magic Link**, include the code `{{ .Token }}`, for example `<p>Your Coolmap sign-in code is {{ .Token }}</p>`. The app asks for this code directly, so no app deep link is required. New email addresses create an account automatically after code verification. Configure email delivery to allow your test users, and test two different email addresses.
4. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` if the local file does not already exist. Set `REPORTS_HOST` to the project hostname only, such as `abcdef.supabase.co`, and `REPORTS_PUBLIC_KEY` to the project's publishable key (or legacy anon key). Preserve any existing Google configuration. Never use a secret/service-role key or database password in iOS. This local file is gitignored.
5. Rebuild and open **Menu → Profile & points**. Enter your email, then the emailed code. Edit your display name. Sessions are saved in the iOS Keychain; points and history are loaded from the server.
6. Sign in as account A on one device and account B on another. A reports an obstacle. B opens the map nearby (within 40 m for the prompt) and taps **Yes · still there**. A's profile refreshes to **+5 points**. Use a different report for a **No** check: A loses **2 points**. Pull to refresh Profile or leave it open for its 20-second refresh.

### What is stored and enforced

- `walker_profiles`: account ID, generated stable username, editable display name, joined date and server-controlled points. Email stays in Supabase Auth, not the public reports table.
- `route_reports`: shared obstacle location, category, note, owner, expiry, latest confirmation and denial count. Historical anonymous reports retain no owner and cannot earn points.
- `route_report_votes`: one authenticated vote per walker per report. Users cannot vote on their own reports. The author receives points; the voter does not. A second No clears the obstacle. Yes does not extend the original expiry cap.
- `walker_point_events`: private, immutable-from-the-client audit trail of each +5/−2. Points may go below zero. The server applies the vote, event and balance change in one transaction; retries cannot double-credit points.
- Clients can edit only their own display name, read only their own profile/history/votes, and read community reports. All writes affecting reports and scores use the restricted database functions. The old anonymous insert routes and client-provided vote weights are disabled.
- Report submission is limited to 10 per account per hour; checks to 50 per account per day. The vote function requires a location no older than two minutes, accuracy ≤65 m and distance ≤60 m. GPS is client supplied, so this is not proof of physical presence. Multi-account collusion, device attestation, moderation, appeals and production abuse monitoring remain future work.

### Offline and demo behavior

When unconfigured, Profile explicitly says setup is pending. Reports can still be saved locally. New reports created while signed in are queued with that account's ID and can be retried from Profile; changing accounts never transfers report ownership. Older anonymous/local reports are not silently claimed by a later login. Create a new report while signed in to earn points.

Votes require an online server acknowledgement. A failed check stays visible with an error and retry; no local points are awarded. Stage-demo hazards never upload and never change real points. The app labels reports from demo positions, but production protection against GPS spoofing needs additional server/device controls.

### Verification

Run `npm ci --prefix Backend` and `npm test --prefix Backend`. The test suite executes the actual migrations, functions, grants and row policies against a local PostgreSQL WASM engine with a minimal Auth schema. It uses synthetic users and locations only. It verifies correct awards, deductions, ownership, duplicate requests, expiry, privacy and forbidden direct writes. It does not validate hosted Supabase Auth, SMTP or delivery across physical devices; complete step 6 before the demo.

Official references: [Email OTP](https://supabase.com/docs/guides/auth/auth-email-passwordless), [row-level security](https://supabase.com/docs/guides/database/postgres/row-level-security), [database functions](https://supabase.com/docs/guides/database/functions).
