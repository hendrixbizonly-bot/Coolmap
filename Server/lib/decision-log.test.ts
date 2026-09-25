import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { DecisionResponse } from './decision-log';

const base = {
  lat: 24.47, lon: 54.37, localTime: '2026-09-25T16:05:00+04:00',
  offRouteMeters: 0, offRouteSeconds: 0, walkedSeconds: 300, secondsSinceLastPrompt: 9999,
  minutesToSunset: 140,
  current: { remainingSeconds: 600, remainingHeat: 1500, remainingSunSeconds: 420 },
  alternative: { totalSeconds: 660, heat: 950, sunSeconds: 120 },
  hazardsAhead: [] as { category: string; note?: string; metersAhead: number }[],
};
const req = (over: object = {}) => structuredClone({ ...base, ...over });
const res = (): DecisionResponse => ({ prompt: false, urgency: 0, reason: 'none', debug: { decidedBy: 'none', jev: 'skipped', questions: [] } });

describe('decision-log', () => {
  beforeEach(() => { delete globalThis.__coolmapDecisions; });
  afterEach(() => { delete globalThis.__coolmapDecisions; vi.restoreAllMocks(); });

  it('returns an empty list before any decision', async () => {
    const { recentDecisions } = await import('./decision-log');
    expect(recentDecisions()).toEqual([]);
  });

  it('keeps newest first with unique ids and ISO timestamps', async () => {
    const { recordDecision, recentDecisions } = await import('./decision-log');
    for (const walkedSeconds of [1, 2, 3]) recordDecision(req({ walkedSeconds }), res());
    const decisions = recentDecisions();
    expect(decisions.map(d => d.request.walkedSeconds)).toEqual([3, 2, 1]);
    expect(new Set(decisions.map(d => d.id)).size).toBe(3);
    for (const d of decisions) expect(d.receivedAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  });

  it('caps the log at 20 entries', async () => {
    const { recordDecision, recentDecisions } = await import('./decision-log');
    for (let i = 0; i < 25; i++) recordDecision(req({ walkedSeconds: i }), res());
    const decisions = recentDecisions();
    expect(decisions).toHaveLength(20);
    expect(decisions.map(d => d.request.walkedSeconds)).toEqual([24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5]);
  });

  it('retains decisions across module reload', async () => {
    const first = await import('./decision-log');
    first.recordDecision(req(), res());
    const stored = first.recentDecisions()[0];
    vi.resetModules();
    const second = await import('./decision-log');
    expect(second.recentDecisions()).toEqual([stored]);
    expect(second.recentDecisions()[0].id).toBe(stored.id);
  });

  it('never throws when recording fails', async () => {
    const { recordDecision, recentDecisions } = await import('./decision-log');
    vi.spyOn(crypto, 'randomUUID').mockImplementation(() => { throw new Error('no uuid'); });
    expect(() => recordDecision(req(), res())).not.toThrow();
    expect(recentDecisions()).toEqual([]);
  });

  it('snapshots payloads so later mutation does not change the log', async () => {
    const { recordDecision, recentDecisions } = await import('./decision-log');
    const request = req();
    const response = res();
    recordDecision(request, response);
    request.walkedSeconds = 99999;
    response.debug.questions.push({ id: 'x', label: 'x', type: 'boolean', answer: true, probability: 1 });
    const decisions = recentDecisions();
    expect(decisions[0].request.walkedSeconds).toBe(300);
    expect(decisions[0].response.debug.questions).toEqual([]);
    decisions[0].request.walkedSeconds = -1;
    expect(recentDecisions()[0].request.walkedSeconds).toBe(300);
  });
});

describe('GET /api/decisions', () => {
  beforeEach(() => { delete globalThis.__coolmapDecisions; });
  afterEach(() => { delete globalThis.__coolmapDecisions; vi.restoreAllMocks(); });

  it('serves newest first with no-store', async () => {
    const { recordDecision } = await import('./decision-log');
    for (const walkedSeconds of [1, 2]) recordDecision(req({ walkedSeconds }), res());
    const { GET, dynamic } = await import('../app/api/decisions/route');
    expect(dynamic).toBe('force-dynamic');
    const response = await GET();
    expect(response.status).toBe(200);
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    const body = await response.json();
    expect(body.decisions.map((d: { request: { walkedSeconds: number } }) => d.request.walkedSeconds)).toEqual([2, 1]);
  });
});

describe('POST /api/reroute-decision logging', () => {
  beforeEach(() => { delete globalThis.__coolmapDecisions; });
  afterEach(() => { delete globalThis.__coolmapDecisions; vi.restoreAllMocks(); });

  it('does not log malformed requests', async () => {
    const { POST } = await import('../app/api/reroute-decision/route');
    const { recentDecisions } = await import('./decision-log');
    const bad = await POST(new Request('http://localhost/api/reroute-decision', { method: 'POST', body: 'not json{' }));
    expect(bad.status).toBe(400);
    const invalid = await POST(new Request('http://localhost/api/reroute-decision', { method: 'POST', body: JSON.stringify({ ...base, lat: 91 }) }));
    expect(invalid.status).toBe(400);
    expect(recentDecisions()).toEqual([]);
  });

  it('logs a skipped decision for a valid request', async () => {
    const { POST } = await import('../app/api/reroute-decision/route');
    const { recentDecisions } = await import('./decision-log');
    const response = await POST(new Request('http://localhost/api/reroute-decision', { method: 'POST', body: JSON.stringify({ ...base, alternative: null }) }));
    expect(response.status).toBe(200);
    const decisions = recentDecisions();
    expect(decisions).toHaveLength(1);
    expect(decisions[0].request.alternative).toBeNull();
    expect(decisions[0].response.reason).toBe('none');
  });
});
