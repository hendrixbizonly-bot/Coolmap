-- Run AFTER reports.sql. Safe to re-run. Existing anonymous reports keep no owner
-- and cannot earn points. Never guess ownership of historical reports.
begin;
create table if not exists public.walker_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  display_name text not null default 'Walker' check (char_length(display_name) between 1 and 40),
  points integer not null default 0,
  created_at timestamptz not null default now()
);
alter table public.walker_profiles enable row level security;
revoke all on public.walker_profiles from anon, authenticated;
grant select on public.walker_profiles to authenticated;
grant update (display_name) on public.walker_profiles to authenticated;
drop policy if exists "Own profile" on public.walker_profiles;
create policy "Own profile" on public.walker_profiles for select to authenticated using (id=auth.uid());
drop policy if exists "Edit own name" on public.walker_profiles;
create policy "Edit own name" on public.walker_profiles for update to authenticated using (id=auth.uid()) with check (id=auth.uid());

create or replace function public.create_walker_profile() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  insert into public.walker_profiles(id,username) values (new.id,'walker_'||replace(new.id::text,'-','')) on conflict(id) do nothing;
  return new;
end $$;
revoke all on function public.create_walker_profile() from public,anon,authenticated;
drop trigger if exists create_walker_profile on auth.users;
create trigger create_walker_profile after insert on auth.users for each row execute function public.create_walker_profile();
insert into public.walker_profiles(id,username) select id,'walker_'||replace(id::text,'-','') from auth.users on conflict(id) do nothing;

alter table public.route_reports add column if not exists reporter_id uuid references public.walker_profiles(id) on delete set null;
alter table public.route_reports add column if not exists confirmed_at timestamptz;
alter table public.route_reports add column if not exists denials integer not null default 0;
alter table public.route_reports add column if not exists expires_at timestamptz;
update public.route_reports set expires_at=created_at+case
  when category='Blocked crossing' then interval '6 hours'
  when category in ('No shade','Missing shade') then interval '30 days'
  when category='Other' then interval '1 day' else interval '14 days' end where expires_at is null;
alter table public.route_reports alter column expires_at set not null;
alter table public.route_report_votes add column if not exists voter_id uuid references public.walker_profiles(id) on delete set null;
create unique index if not exists report_one_vote_per_walker on public.route_report_votes(report_id,voter_id) where voter_id is not null;
create index if not exists reports_by_reporter on public.route_reports(reporter_id,created_at);
create index if not exists votes_by_walker on public.route_report_votes(voter_id,created_at);

create table if not exists public.walker_point_events (
  id bigint generated always as identity primary key,
  walker_id uuid not null references public.walker_profiles(id) on delete cascade,
  report_id uuid references public.route_reports(id) on delete set null,
  vote_id bigint unique references public.route_report_votes(id) on delete set null,
  delta integer not null check(delta in (5,-2)),
  reason text not null check(reason in ('confirmed','not_there')),
  created_at timestamptz not null default now()
);
alter table public.walker_point_events enable row level security;
revoke all on public.walker_point_events from anon,authenticated;
grant select on public.walker_point_events to authenticated;
drop policy if exists "Own points history" on public.walker_point_events;
create policy "Own points history" on public.walker_point_events for select to authenticated using(walker_id=auth.uid());

-- Retire both anonymous write paths, including their old column-level grants.
drop policy if exists "Submit route reports" on public.route_reports;
drop policy if exists "Submit report votes" on public.route_report_votes;
revoke all on public.route_reports,public.route_report_votes from anon,authenticated;
revoke insert (id,category,note,latitude,longitude,location_description) on public.route_reports from anon,authenticated;
revoke insert (report_id,still_there,weight) on public.route_report_votes from anon,authenticated;
grant select on public.route_reports to anon,authenticated;
grant select on public.route_report_votes to authenticated;
drop policy if exists "Own votes" on public.route_report_votes;
create policy "Own votes" on public.route_report_votes for select to authenticated using(voter_id=auth.uid());

create or replace function public.submit_owned_report(p_id uuid,p_category text,p_note text,p_latitude double precision,p_longitude double precision,p_description text)
returns public.route_reports language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); result public.route_reports;
begin
  if uid is null or not exists(select 1 from auth.users where id=uid and email_confirmed_at is not null) then raise exception 'Sign in with a verified email first'; end if;
  -- Serialize per user for the submission limit, and retain UUID retry idempotency.
  perform 1 from public.walker_profiles where id=uid for update;
  select * into result from public.route_reports where id=p_id;
  if found then
    if result.reporter_id=uid then return result; end if;
    raise exception 'Report ID is already used';
  end if;
  if (select count(*) from public.route_reports where reporter_id=uid and created_at>now()-interval '1 hour')>=10 then raise exception 'Report limit reached. Try again later'; end if;
  insert into public.route_reports(id,reporter_id,category,note,latitude,longitude,location_description,expires_at)
  values(p_id,uid,p_category,p_note,p_latitude,p_longitude,p_description,now()+case
    when p_category='Blocked crossing' then interval '6 hours'
    when p_category in ('No shade','Missing shade') then interval '30 days'
    when p_category='Other' then interval '1 day' else interval '14 days' end) returning * into result;
  return result;
end $$;
revoke all on function public.submit_owned_report(uuid,text,text,double precision,double precision,text) from public,anon;
grant execute on function public.submit_owned_report(uuid,text,text,double precision,double precision,text) to authenticated;

create or replace function public.verify_owned_report(p_report_id uuid,p_still_there boolean,p_latitude double precision,p_longitude double precision,p_accuracy double precision,p_observed_at timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); r public.route_reports; vote bigint; change integer; distance_m double precision; haversine double precision;
begin
  if uid is null or not exists(select 1 from auth.users where id=uid and email_confirmed_at is not null) then raise exception 'Sign in with a verified email first'; end if;
  -- Serialize checks and writes across this transaction; locks acquired in the same order.
  perform pg_catalog.pg_advisory_xact_lock(73421);
  select * into r from public.route_reports where id=p_report_id for update;
  if not found or r.reporter_id is null then raise exception 'This report is not eligible for points'; end if;
  if r.reporter_id=uid then raise exception 'You cannot verify your own report'; end if;
  if exists(select 1 from public.route_report_votes where report_id=p_report_id and voter_id=uid) then
    return jsonb_build_object('recorded',false,'message','You already checked this report');
  end if;
  if r.expires_at<=now() or r.denials>=2 then raise exception 'This report has expired or cleared'; end if;
  if p_still_there is null or p_latitude is null or p_longitude is null or p_accuracy is null or p_observed_at is null
     or not(p_latitude between -90 and 90) or not(p_longitude between -180 and 180)
     or not(p_accuracy between 0 and 65) or abs(extract(epoch from now()-p_observed_at))>120 then raise exception 'A fresh, accurate location is required'; end if;
  haversine=power(sin(radians(p_latitude-r.latitude)/2),2)+cos(radians(r.latitude))*cos(radians(p_latitude))*power(sin(radians(p_longitude-r.longitude)/2),2);
  distance_m=6371000*2*asin(sqrt(least(1,haversine)));
  if distance_m>60 then raise exception 'Move closer to the obstacle to check it'; end if;
  if (select count(*) from public.route_report_votes where voter_id=uid and created_at>now()-interval '1 day')>=50 then raise exception 'Daily verification limit reached'; end if;
  insert into public.route_report_votes(report_id,voter_id,still_there,weight) values(p_report_id,uid,p_still_there,1) returning id into vote;
  change=case when p_still_there then 5 else -2 end;
  insert into public.walker_point_events(walker_id,report_id,vote_id,delta,reason) values(r.reporter_id,p_report_id,vote,change,case when p_still_there then 'confirmed' else 'not_there' end);
  update public.walker_profiles set points=points+change where id=r.reporter_id;
  -- Positive confirmations preserve the initial expiry cap; old pins cannot farm points forever.
  update public.route_reports set confirmed_at=case when p_still_there then now() else confirmed_at end,
    denials=denials+case when p_still_there then 0 else 1 end where id=p_report_id;
  return jsonb_build_object('recorded',true,'message','Thanks — your check was saved','points_delta',change);
end $$;
revoke all on function public.verify_owned_report(uuid,boolean,double precision,double precision,double precision,timestamptz) from public,anon;
grant execute on function public.verify_owned_report(uuid,boolean,double precision,double precision,double precision,timestamptz) to authenticated;
commit;
