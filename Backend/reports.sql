-- Run once in the Supabase SQL editor. No service-role key belongs in the iOS app.
create table if not exists public.route_reports (
  id uuid primary key,
  category text not null check (category in ('Broken sidewalk','Blocked crossing','No shade','Construction','Other','Blocked path','Missing shade','No pavement')),
  note text not null default '' check (char_length(note) <= 1000),
  latitude double precision not null check (latitude between 24 and 26.5),
  longitude double precision not null check (longitude between 54 and 57),
  location_description text not null default '' check (char_length(location_description) <= 120),
  created_at timestamptz not null default now()
);
alter table public.route_reports enable row level security;
revoke all on public.route_reports from anon, authenticated;
grant select on public.route_reports to anon, authenticated;
grant insert (id,category,note,latitude,longitude,location_description) on public.route_reports to anon, authenticated;
create policy "Read public route reports" on public.route_reports for select to anon, authenticated using (true);
create policy "Submit route reports" on public.route_reports for insert to anon, authenticated with check (true);
create index if not exists route_reports_location on public.route_reports (latitude,longitude,created_at desc);
-- No client update/delete policy. This is an anonymous hackathon endpoint.
-- Add authentication, server-side rate limits, moderation and retention before public release.
