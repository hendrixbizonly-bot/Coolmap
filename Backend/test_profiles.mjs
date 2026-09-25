import { PGlite } from '@electric-sql/pglite';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

// Real PostgreSQL engine in WASM, with a minimal local Supabase Auth schema.
// No network, accounts, or real user data are used by these tests.
const db = new PGlite();
await db.exec(`
  create role anon; create role authenticated;
  create schema auth;
  create table auth.users(id uuid primary key,email_confirmed_at timestamptz);
  create function auth.uid() returns uuid language sql stable as
    'select nullif(current_setting(''request.jwt.claim.sub'',true),'''')::uuid';
  grant usage on schema public,auth to anon,authenticated;
  grant execute on function auth.uid() to anon,authenticated;
`);
await db.exec(await readFile(new URL('./reports.sql',import.meta.url),'utf8'));
const migration=await readFile(new URL('./profiles.sql',import.meta.url),'utf8');
await db.exec(migration);
await db.exec(migration); // Reruns must not duplicate triggers, policies, or points.
const users=Array.from({length:5},(_,i)=>`00000000-0000-0000-0000-00000000000${i+1}`);
for(const id of users) await db.query('insert into auth.users values($1,now())',[id]);
const report='10000000-0000-0000-0000-000000000001';
let passed=0;
async function asUser(id,sql,params=[]) {
  await db.exec('begin; set local role authenticated;');
  try {
    await db.query("select set_config('request.jwt.claim.sub',$1,true)",[id]);
    const result=await db.query(sql,params);
    await db.exec('commit'); return result;
  } catch(error) { await db.exec('rollback'); throw error; }
}
async function check(name,fn) { await fn(); passed++; console.log('PASS',name); }
async function points(id) { return (await db.query('select points from public.walker_profiles where id=$1',[id])).rows[0].points; }
const submit="select (public.submit_owned_report($1,'Other','Test obstacle',24.4991,54.3887,'Public demo point')).id";
const vote="select public.verify_owned_report($1,$2,$3,$4,$5,$6) as result";
const args=(yes,lat=24.4991,accuracy=10,time=new Date().toISOString())=>[report,yes,lat,54.3887,accuracy,time];
await check('auth signup creates a zero-point profile',async()=>assert.equal(await points(users[0]),0));
await check('reports are tied to authenticated owner',async()=>{
  await asUser(users[0],submit,[report]);
  assert.equal((await db.query('select reporter_id from route_reports where id=$1',[report])).rows[0].reporter_id,users[0]);
});
await check('report retries are idempotent',async()=>{
  await asUser(users[0],submit,[report]);
  assert.equal((await db.query('select count(*)::int as n from route_reports')).rows[0].n,1);
});
await check('another account cannot claim an existing report ID',async()=>assert.rejects(asUser(users[1],submit,[report]),/already used/));
await check('self-vote rejected',async()=>assert.rejects(asUser(users[0],vote,args(true)),/own report/));
await check('distant GPS rejected',async()=>assert.rejects(asUser(users[1],vote,args(true,25.2)),/closer/));
await check('stale GPS rejected',async()=>assert.rejects(asUser(users[1],vote,args(true,24.4991,10,'2020-01-01T00:00:00Z')),/fresh/));
await check('inaccurate GPS rejected',async()=>assert.rejects(asUser(users[1],vote,args(true,24.4991,100)),/fresh/));
await check('Yes awards the reporter five, not the voter',async()=>{
  await asUser(users[1],vote,args(true)); assert.equal(await points(users[0]),5); assert.equal(await points(users[1]),0);
});
await check('duplicate or changed vote has no further effect',async()=>{
  const r=await asUser(users[1],vote,args(false)); assert.equal(r.rows[0].result.recorded,false); assert.equal(await points(users[0]),5);
});
await check('No subtracts two from reporter',async()=>{
  await asUser(users[2],vote,args(false)); assert.equal(await points(users[0]),3);
});
await check('second No clears the hazard',async()=>{
  await asUser(users[3],vote,args(false)); assert.equal(await points(users[0]),1);
  assert.equal((await db.query('select denials from route_reports where id=$1',[report])).rows[0].denials,2);
});
await check('cleared reports reject further votes',async()=>assert.rejects(asUser(users[4],vote,args(true)),/expired or cleared/));
await check('profile points cannot be edited by client',async()=>assert.rejects(asUser(users[0],'update walker_profiles set points=999 where id=$1',[users[0]]),/permission denied/));
await check('display name can be edited by its owner',async()=>{
  await asUser(users[0],"update walker_profiles set display_name='Alex' where id=$1",[users[0]]);
  assert.equal((await asUser(users[0],'select display_name from walker_profiles')).rows[0].display_name,'Alex');
});
await check('profiles and point events are private',async()=>{
  assert.equal((await asUser(users[1],'select * from walker_profiles where id=$1',[users[0]])).rows.length,0);
  assert.equal((await asUser(users[1],'select * from walker_point_events')).rows.length,0);
});
await check('ledger matches points, each vote credited once',async()=>{
  const r=await asUser(users[0],'select count(*)::int as n,sum(delta)::int as total from walker_point_events');
  assert.equal(r.rows[0].n,3); assert.equal(r.rows[0].total,await points(users[0]));
});
await check('clients cannot insert arbitrary votes or events',async()=>{
  await assert.rejects(asUser(users[4],'insert into route_report_votes(report_id,still_there,weight) values($1,true,2)',[report]),/permission denied/);
  await assert.rejects(asUser(users[0],"insert into walker_point_events(walker_id,delta,reason) values($1,5,'confirmed')",[users[0]]),/permission denied/);
});
await check('anonymous writes are rejected',async()=>{
  await db.exec('begin; set local role anon');
  try { await assert.rejects(db.query(submit,['10000000-0000-0000-0000-000000000002']),/permission denied/); }
  finally { await db.exec('rollback'); }
});
await check('expired report rejects votes without changing points',async()=>{
  const expired='10000000-0000-0000-0000-000000000003';
  await asUser(users[0],submit,[expired]);
  await db.query("update route_reports set expires_at=now()-interval '1 minute' where id=$1",[expired]);
  const input=args(true); input[0]=expired;
  await assert.rejects(asUser(users[4],vote,input),/expired or cleared/);
  assert.equal(await points(users[0]),1);
});
await db.close();
console.log(`${passed} database checks passed`);
