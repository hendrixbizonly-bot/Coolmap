import { afterEach, describe, expect, it, vi } from 'vitest';

const NOW = Date.parse('2026-09-25T12:05:00Z');
const hourly = { time: ['2026-09-25T15:00', '2026-09-25T16:00', '2026-09-25T17:00'], temperature_2m: [40, 42, 41] };
const ok = (body: unknown = { hourly }) => ({ ok: true, json: async () => body }) as Response;
async function load() {
  vi.resetModules();
  return import('./weather');
}
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('currentTemperature', () => {
  it('returns the Dubai current-hour temperature', async () => {
    const fetchMock = vi.fn(async () => ok());
    vi.stubGlobal('fetch', fetchMock);
    vi.spyOn(Date, 'now').mockReturnValue(NOW);
    const { currentTemperature } = await load();
    expect(await currentTemperature(24.47, 54.37)).toBe(42);
    expect(fetchMock).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({
      search: expect.stringContaining('latitude=24.47'),
    }), expect.objectContaining({ cache: 'no-store' }));
  });
  it('caches per rounded coordinate for ten minutes', async () => {
    const fetchMock = vi.fn(async () => ok());
    vi.stubGlobal('fetch', fetchMock);
    const now = vi.spyOn(Date, 'now').mockReturnValue(NOW);
    const { currentTemperature } = await load();
    await currentTemperature(24.47, 54.37);
    await currentTemperature(24.47, 54.37);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    now.mockReturnValue(NOW + 600000);
    await currentTemperature(24.47, 54.37);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    await currentTemperature(25.01, 54.37);
    expect(fetchMock).toHaveBeenCalledTimes(3);
  });
  it.each([
    ['fetch rejection', vi.fn(async () => { throw new Error('offline'); })],
    ['non-ok response', vi.fn(async () => ({ ok: false }) as Response)],
    ['invalid shape', vi.fn(async () => ok({ hourly: { time: [], temperature_2m: 'x' } }))],
    ['null temperature', vi.fn(async () => ok({ hourly: { ...hourly, temperature_2m: [40, null, 41] } }))],
    ['missing current hour', vi.fn(async () => ok({ hourly: { ...hourly, time: ['2026-09-25T15:00', '2026-09-25T14:00', '2026-09-25T17:00'] } }))],
  ])('returns undefined on %s', async (_name, fetchMock) => {
    vi.stubGlobal('fetch', fetchMock);
    vi.spyOn(Date, 'now').mockReturnValue(NOW);
    const { currentTemperature } = await load();
    expect(await currentTemperature(24.47, 54.37)).toBeUndefined();
  });
});
