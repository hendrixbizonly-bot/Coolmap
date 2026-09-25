import type { decideReroute, RerouteRequest } from './reroute';
export type DecisionResponse = Awaited<ReturnType<typeof decideReroute>> & { debug: { temperatureC?: number } };
export type Decision = { id: string; receivedAt: string; request: RerouteRequest; response: DecisionResponse };
declare global { var __coolmapDecisions: Decision[] | undefined; }
export function recordDecision(request: RerouteRequest, response: DecisionResponse): void {
  try {
    const entry = structuredClone({ id: crypto.randomUUID(), receivedAt: new Date().toISOString(), request, response });
    const decisions = globalThis.__coolmapDecisions ??= [];
    decisions.unshift(entry);
    decisions.splice(20);
  } catch { return; }
}
export function recentDecisions(): Decision[] { return structuredClone(globalThis.__coolmapDecisions ?? []); }
