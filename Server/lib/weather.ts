import { z } from 'zod';
const forecastSchema = z.object({ hourly: z.object({ time: z.array(z.string()), temperature_2m: z.array(z.number().finite().nullable()) }) });
const cache = new Map<string, { temperature: number; expires: number }>();
export async function currentTemperature(lat: number, lon: number): Promise<number | undefined> {
  const key = `${lat.toFixed(2)},${lon.toFixed(2)}`;
  const now = Date.now();
  const cached = cache.get(key);
  if (cached && cached.expires > now) return cached.temperature;
  try {
    const url = new URL('https://api.open-meteo.com/v1/forecast');
    url.search = new URLSearchParams({ latitude: String(lat), longitude: String(lon), hourly: 'temperature_2m', timezone: 'Asia/Dubai', forecast_days: '1' }).toString();
    const response = await fetch(url, { signal: AbortSignal.timeout(1500), cache: 'no-store' });
    if (!response.ok) return undefined;
    const { hourly } = forecastSchema.parse(await response.json());
    const hour = new Date(now + 4 * 3600000).toISOString().slice(0, 13) + ':00';
    const temperature = hourly.temperature_2m[hourly.time.indexOf(hour)];
    if (temperature == null) return undefined;
    if (cache.size >= 100) cache.delete(cache.keys().next().value!);
    cache.set(key, { temperature, expires: now + 600000 });
    return temperature;
  } catch { return undefined; }
}
