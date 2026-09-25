import { setTimeout as wait } from 'node:timers/promises';
const baseURL = (process.env.BASE_URL || 'http://localhost:3000').replace(/\/$/, '');
const base = {
  lat: 24.4995, lon: 54.3888, localTime: '2026-09-25T16:05:00+04:00',
  offRouteMeters: 0, offRouteSeconds: 0, walkedSeconds: 300, secondsSinceLastPrompt: 9999, minutesToSunset: 140,
  current: { remainingSeconds: 600, remainingHeat: 1500, remainingSunSeconds: 420 },
  alternative: { totalSeconds: 780, heat: 1425, sunSeconds: 400 }, hazardsAhead: [],
};
const states = [
  base,
  { ...base, localTime: '2026-09-25T16:06:00+04:00', walkedSeconds: 360, minutesToSunset: 139, alternative: { totalSeconds: 840, heat: 1425, sunSeconds: 400 } },
  { ...base, localTime: '2026-09-25T16:07:00+04:00', walkedSeconds: 420, minutesToSunset: 138, alternative: { totalSeconds: 660, heat: 900, sunSeconds: 120 }, hazardsAhead: [{ category: 'Other', note: 'Fallen tree across the path', metersAhead: 80 }] },
  { ...base, localTime: '2026-09-25T16:11:00+04:00', lat: 24.4998, lon: 54.3892, walkedSeconds: 660, minutesToSunset: 134, secondsSinceLastPrompt: 240, offRouteMeters: 40, offRouteSeconds: 20, alternative: { totalSeconds: 660, heat: 900, sunSeconds: 120 } },
  { ...base, localTime: '2026-09-25T16:15:00+04:00', lat: 24.5001, lon: 54.3895, walkedSeconds: 900, minutesToSunset: 130, secondsSinceLastPrompt: 240, offRouteMeters: 70, offRouteSeconds: 40, alternative: { totalSeconds: 660, heat: 900, sunSeconds: 120 } },
];
try {
  for (const [index, state] of states.entries()) {
    if (index) await wait(6000);
    const response = await fetch(`${baseURL}/api/reroute-decision`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(state), signal: AbortSignal.timeout(15000) });
    if (!response.ok) throw new Error(`Check ${index + 1}: HTTP ${response.status}`);
    const { reason, prompt, confidence } = await response.json();
    console.log(`${index + 1}/5 reason=${reason} prompt=${prompt} confidence=${confidence ?? '—'}`);
  }
} catch (error) { console.error(error instanceof Error ? error.message : 'Replay failed'); process.exitCode = 1; }
