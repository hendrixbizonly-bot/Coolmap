import { describe, expect, it } from 'vitest';
import { POST } from './route';

const base = {
  lat: 24.47, lon: 54.37, localTime: '2026-09-25T16:05:00+04:00',
  offRouteMeters: 0, offRouteSeconds: 0, walkedSeconds: 300, secondsSinceLastPrompt: 9999,
  minutesToSunset: 140,
  current: { remainingSeconds: 600, remainingHeat: 1500, remainingSunSeconds: 420 },
  alternative: { totalSeconds: 660, heat: 950, sunSeconds: 120 },
  hazardsAhead: [] as unknown[],
};
const post = (body: string | object) => POST(new Request('http://localhost/api/reroute-decision', {
  method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body),
}));

describe('POST /api/reroute-decision', () => {
  it.each([
    ['bad JSON', 'not json{'],
    ['invalid latitude', { ...base, lat: 91 }],
    ['missing alternative', Object.fromEntries(Object.entries(base).filter(([k]) => k !== 'alternative'))],
    ['negative seconds', { ...base, walkedSeconds: -1 }],
    ['invalid localTime', { ...base, localTime: 'yesterday' }],
  ])('rejects %s with 400', async (_name, body) => {
    const response = await post(body);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: expect.any(String) });
  });
  it('returns a skipped decision for a valid request with no alternative', async () => {
    const response = await post({ ...base, alternative: null });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ prompt: false, urgency: 0, reason: 'none',
      debug: { decidedBy: 'none', jev: 'skipped', questions: [] } });
  });
  it('hard-triggers on a stage demo hazard', async () => {
    const response = await post({ ...base, hazardsAhead: [{ category: 'Other', note: 'Fallen tree across the path', metersAhead: 150 }] });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ prompt: true, urgency: 3, reason: 'hard_trigger',
      debug: { decidedBy: 'hard_trigger', jev: 'skipped', questions: [] } });
  });
});
