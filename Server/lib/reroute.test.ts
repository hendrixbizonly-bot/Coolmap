import { describe, expect, it, vi } from 'vitest';
import { Experimental_EvaluationMockModelV4 } from 'ai/test';
import { decideReroute } from './reroute';
import scenarios from '../eval/reroute.scenarios.json';

const base = {
  lat: 24.47, lon: 54.37, localTime: '2026-09-25T16:05:00+04:00',
  offRouteMeters: 0, offRouteSeconds: 0, walkedSeconds: 300, secondsSinceLastPrompt: 9999,
  minutesToSunset: 140,
  current: { remainingSeconds: 600, remainingHeat: 1500, remainingSunSeconds: 420 },
  alternative: { totalSeconds: 660, heat: 950, sunSeconds: 120 },
  hazardsAhead: [] as { category: string; note?: string; metersAhead: number }[],
};
const req = (over: object = {}) => structuredClone({ ...base, ...over });
const answers = (p: number) => ({
  rerouteWorthIt: { type: 'boolean', probability: p },
  urgency: { type: 'score', score: 1.92, probabilities: { '0': 0.04, '1': 0.12, '2': 0.72, '3': 0.12 } },
}) as const;
const evaluator = (p: number) => vi.fn<(options: { state: unknown }) => Promise<{ answers: ReturnType<typeof answers>; warnings: never[] }>>(async () => ({ answers: answers(p), warnings: [] }));
const mockModel = (p: number) => new Experimental_EvaluationMockModelV4({ doEvaluate: evaluator(p) });
const debugQuestions = (answer: boolean, probability: number, urgencyP = 0.72) => [
  { id: 'rerouteWorthIt', label: 'Worth rerouting?', type: 'boolean', answer, probability },
  { id: 'urgency', label: 'Urgency', type: 'score', answer: 2, max: 3, probability: urgencyP },
];
const blocked = [{ category: 'Blocked crossing', metersAhead: 150 }];
const noQuestions = { decidedBy: 'none', jev: 'skipped', questions: [] };

describe('decideReroute', () => {
  it('skips on cooldown and missing alternative even with a hazard', async () => {
    const doEvaluate = evaluator(0.82);
    const weather = vi.fn();
    const model = new Experimental_EvaluationMockModelV4({ doEvaluate });
    const o = { model, weather };
    expect(await decideReroute(req({ secondsSinceLastPrompt: 179, hazardsAhead: blocked }), o))
      .toEqual({ prompt: false, urgency: 0, reason: 'none', debug: noQuestions });
    expect(await decideReroute(req({ alternative: null, hazardsAhead: blocked }), o))
      .toEqual({ prompt: false, urgency: 0, reason: 'none', debug: noQuestions });
    expect(doEvaluate).not.toHaveBeenCalled();
    expect(weather).not.toHaveBeenCalled();
  });
  it.each([{ category: 'blocked' }, { category: 'Blocked crossing' }, { category: 'Closed sidewalk' },
    { category: 'Other', note: 'Fallen tree across the path' },
    { category: 'Other', note: 'CLOSED PATH' }])('hard-triggers on %o even with a worse alternative', async hazard => {
    const doEvaluate = evaluator(0.82);
    const weather = vi.fn(async () => 42);
    const result = await decideReroute(req({ alternative: { ...base.alternative, heat: 1600 },
      hazardsAhead: [{ metersAhead: 80, ...hazard }] }),
      { model: new Experimental_EvaluationMockModelV4({ doEvaluate }), weather });
    expect(result).toEqual({ prompt: true, urgency: 3, reason: 'hard_trigger',
      debug: { decidedBy: 'hard_trigger', jev: 'skipped', questions: [] } });
    expect(doEvaluate).not.toHaveBeenCalled();
    expect(weather).not.toHaveBeenCalled();
  });
  it('skips when heat saving is too small or heat is zero', async () => {
    const doEvaluate = evaluator(0.82);
    const weather = vi.fn();
    const model = new Experimental_EvaluationMockModelV4({ doEvaluate });
    for (const over of [{ alternative: { ...base.alternative, heat: 1351 } },
      { current: { ...base.current, remainingHeat: 0 }, alternative: { ...base.alternative, heat: 0 } }]) {
      expect(await decideReroute(req(over), { model, weather }))
        .toEqual({ prompt: false, urgency: 0, reason: 'none', debug: noQuestions });
    }
    expect(doEvaluate).not.toHaveBeenCalled();
    expect(weather).not.toHaveBeenCalled();
  });
  it('passes state plus temperatureC to Jev at the boundaries', async () => {
    const doEvaluate = evaluator(0.82);
    const request = req({ secondsSinceLastPrompt: 180, alternative: { ...base.alternative, heat: 1350 } });
    const result = await decideReroute(request, {
      model: new Experimental_EvaluationMockModelV4({ doEvaluate }), weather: vi.fn(async () => 42) });
    expect(result).toEqual({ prompt: true, urgency: 2, reason: 'jev', confidence: 0.82,
      debug: { decidedBy: 'jev', jev: 'ok', questions: debugQuestions(true, 0.82) } });
    expect(doEvaluate).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({
      state: { ...request, temperatureC: 42 },
    }));
  });
  it.each([[0.82, true, true, 0.82], [0.2, false, false, 0.8], [0.59, false, true, 0.59], [0.6, true, true, 0.6], [0.5, false, true, 0.5]] as const)
    ('probability %f', async (p, prompt, answer, probability) => {
      const result = await decideReroute(req(), { model: mockModel(p), weather: vi.fn(async () => 42) });
      expect(result).toEqual({ prompt, urgency: 2, reason: 'jev', confidence: p,
        debug: { decidedBy: 'jev', jev: 'ok', questions: debugQuestions(answer, probability) } });
    });
  it('falls back to the rule when the provider throws', async () => {
    const model = new Experimental_EvaluationMockModelV4({ doEvaluate: vi.fn(async () => { throw new Error('private'); }) });
    const weather = vi.fn(async () => 42);
    const alt = (heat: number, totalSeconds: number) => ({ alternative: { ...base.alternative, heat, totalSeconds } });
    expect(await decideReroute(req(alt(1125, 780)), { model, weather })).toEqual(
      { prompt: true, urgency: 2, reason: 'rule', debug: { decidedBy: 'rule', jev: 'failed', questions: [] } });
    const failed = { decidedBy: 'rule', jev: 'failed', questions: [] };
    expect(await decideReroute(req(alt(1126, 780)), { model, weather }))
      .toEqual({ prompt: false, urgency: 0, reason: 'rule', debug: failed });
    expect(await decideReroute(req(alt(1125, 781)), { model, weather }))
      .toEqual({ prompt: false, urgency: 0, reason: 'rule', debug: failed });
  });
  it('reports the modal urgency rather than the rounded mean', async () => {
    const model = new Experimental_EvaluationMockModelV4({ doEvaluate: async () => ({ answers: {
      ...answers(0.82), urgency: { type: 'score', score: 1.5, probabilities: { '0': 0.35, '1': 0.2, '2': 0.05, '3': 0.4 } },
    }, warnings: [] }) });
    const result = await decideReroute(req(), { model, weather: vi.fn(async () => 42) });
    expect(result.urgency).toBe(3);
    expect(result.debug.questions[1]).toEqual({ id: 'urgency', label: 'Urgency', type: 'score', answer: 3, max: 3, probability: 0.4 });
  });
  it.each(scenarios.filter(s => s.group === 'just_prompted' || s.group === 'hazard_ahead'))('honors deterministic scenario $id', async scenario => {
    const doEvaluate = evaluator(0.82);
    const weather = vi.fn();
    const result = await decideReroute(scenario.request, { model: new Experimental_EvaluationMockModelV4({ doEvaluate }), weather });
    const prompt = scenario.label === 'should_prompt';
    expect(result).toEqual({ prompt, urgency: prompt ? 3 : 0, reason: prompt ? 'hard_trigger' : 'none',
      debug: { decidedBy: prompt ? 'hard_trigger' : 'none', jev: 'skipped', questions: [] } });
    expect(doEvaluate).not.toHaveBeenCalled();
    expect(weather).not.toHaveBeenCalled();
  });
  it('times out a hung provider and still answers via the rule', async () => {
    const model = new Experimental_EvaluationMockModelV4({ doEvaluate: () => new Promise(() => {}) });
    expect(await decideReroute(req(), { model, weather: vi.fn(async () => 42) })).toEqual(
      { prompt: true, urgency: 2, reason: 'rule', debug: { decidedBy: 'rule', jev: 'failed', questions: [] } });
  }, 5000);
  it('omits temperatureC when weather fails but still asks the model', async () => {
    const doEvaluate = evaluator(0.82);
    const weather = vi.fn(async () => { throw new Error('offline'); });
    const request = req();
    const result = await decideReroute(request, { model: new Experimental_EvaluationMockModelV4({ doEvaluate }), weather });
    expect(result).toEqual({ prompt: true, urgency: 2, reason: 'jev', confidence: 0.82,
      debug: { decidedBy: 'jev', jev: 'ok', questions: debugQuestions(true, 0.82) } });
    expect(weather).toHaveBeenCalledExactlyOnceWith(24.47, 54.37);
    const state = doEvaluate.mock.calls[0]![0].state;
    expect(state).toEqual(request);
    expect('temperatureC' in (state as object)).toBe(false);
  });
});
