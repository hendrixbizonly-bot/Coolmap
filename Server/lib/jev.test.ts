import { afterEach, describe, expect, it, vi } from 'vitest';
import { Experimental_EvaluationMockModelV4 } from 'ai/test';
import { evaluateWithJev } from './jev';

const questions = {
  interrupt: { type: 'boolean', instructions: 'Does the supplied state say interrupt?' },
  route: { type: 'choice', instructions: 'Select the named route.', criteria: { a: null, b: null } },
  severity: { type: 'score', instructions: 'Rate the supplied severity.', criteria: ['low', 'high'] },
} as const;
const answers = {
  interrupt: { type: 'boolean', probability: 0.8 },
  route: { type: 'choice', choice: 'a', probabilities: { a: 0.75, b: 0.25 } },
  severity: { type: 'score', score: 0.6, probabilities: { '0': 0.4, '1': 0.6 } },
} as const;
afterEach(() => vi.unstubAllEnvs());

describe('evaluateWithJev', () => {
  it('preserves typed answers and probabilities without requiring a paid gateway plan', async () => {
    const doEvaluate = vi.fn(async () => ({ answers, warnings: [] }));
    const model = new Experimental_EvaluationMockModelV4({ doEvaluate });
    expect(await evaluateWithJev({ state: { interrupt: true }, questions, model })).toEqual({
      ok: true, answers,
      probabilities: { interrupt: 0.8, route: { a: 0.75, b: 0.25 }, severity: { '0': 0.4, '1': 0.6 } },
    });
    expect(doEvaluate).toHaveBeenCalledExactlyOnceWith(expect.objectContaining({
      state: { interrupt: true }, questions,
      providerOptions: {},
      abortSignal: expect.any(AbortSignal),
    }));
  });
  it('returns timeout after three seconds even when the provider ignores abort', async () => {
    let signal: AbortSignal | undefined;
    const model = new Experimental_EvaluationMockModelV4({ doEvaluate: options => {
      signal = options.abortSignal;
      return new Promise(() => {});
    } });
    expect(await evaluateWithJev({ state: 'interrupt', questions, model })).toEqual({ ok: false, reason: 'timeout' });
    expect(signal?.aborted).toBe(true);
  }, 5000);
  it.each(['route', 'severity'] as const)('fails safely when %s probabilities are absent', async id => {
    const incomplete = structuredClone(answers);
    Reflect.deleteProperty(incomplete[id], 'probabilities');
    const model = new Experimental_EvaluationMockModelV4({ doEvaluate: async () => ({ answers: incomplete, warnings: [] }) });
    expect(await evaluateWithJev({ state: 'interrupt', questions, model })).toEqual({ ok: false, reason: 'missing_probabilities' });
  });
  it('does not expose provider errors or retry failures', async () => {
    const doEvaluate = vi.fn(async () => { throw new Error('private provider details'); });
    const model = new Experimental_EvaluationMockModelV4({ doEvaluate });
    expect(await evaluateWithJev({ state: 'interrupt', questions, model })).toEqual({ ok: false, reason: 'evaluation_failed' });
    expect(doEvaluate).toHaveBeenCalledTimes(1);
  });
  it('disables the default model without a key', async () => {
    vi.stubEnv('AI_GATEWAY_API_KEY', '');
    expect(await evaluateWithJev({ state: 'interrupt', questions })).toEqual({ ok: false, reason: 'missing_api_key' });
  });
});
