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

1. Create a Supabase project in your own account.
2. Run `Backend/reports.sql` once in its SQL editor.
3. In `Config/Local.xcconfig`, set `REPORTS_HOST` to your project host, e.g. `abcdef.supabase.co`, and `REPORTS_PUBLIC_KEY` to a publishable/anon key. Never use a service-role key.
4. Rebuild. Submit a report, verify it appears on a second device, test offline retry and duplicate-send handling.

The schema intentionally shares report coordinates, category and note with other walkers. There are no accounts in this prototype; the UI discloses sharing. Local reports remain in an outbox until successfully posted. Client updates and deletes are not allowed. An anonymous endpoint needs moderation, rate limiting, authentication/abuse controls and a retention policy before a public launch. Do not claim production readiness.

When unconfigured, the app says sharing is unavailable and keeps reports locally. It never claims an unsent report was shared.
