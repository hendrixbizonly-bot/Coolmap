import {
  experimental_evaluate,
  type Experimental_EvaluationQuestion,
  type Experimental_EvaluationResult,
} from 'ai';

type Questions = Record<string, Experimental_EvaluationQuestion>;
type EvaluationInput = Parameters<typeof experimental_evaluate>[0];
export type JevResult<Q extends Questions> =
  | { ok: true; answers: Experimental_EvaluationResult<Q>['answers']; probabilities: Record<keyof Q, number | Record<string, number>> }
  | { ok: false; reason: 'missing_api_key' | 'timeout' | 'missing_probabilities' | 'evaluation_failed' };

export async function evaluateWithJev<const Q extends Questions>({
  state, questions, model,
}: { state: EvaluationInput['state']; questions: Q; model?: EvaluationInput['model'] }): Promise<JevResult<Q>> {
  if (!model && !process.env.AI_GATEWAY_API_KEY) return { ok: false, reason: 'missing_api_key' };
  const signal = AbortSignal.timeout(3000);
  let onAbort: () => void = () => {};
  const deadline = new Promise<never>((_, reject) => {
    onAbort = () => reject(signal.reason);
    signal.addEventListener('abort', onAbort, { once: true });
  });
  try {
    const { answers } = await Promise.race([
      experimental_evaluate({
        state, questions, model: model ?? 'typesafe-ai/jev',
        providerOptions: { gateway: { zeroDataRetention: true } },
        abortSignal: signal, maxRetries: 0,
      }),
      deadline,
    ]);
    const entries = Object.entries(answers).map(([id, answer]) => [
      id, answer.type === 'boolean' ? answer.probability : answer.probabilities,
    ] as const);
    if (entries.some(([, probability]) => probability === undefined)) {
      return { ok: false, reason: 'missing_probabilities' };
    }
    return {
      ok: true, answers,
      probabilities: Object.fromEntries(entries) as Record<keyof Q, number | Record<string, number>>,
    };
  } catch {
    return { ok: false, reason: signal.aborted ? 'timeout' : 'evaluation_failed' };
  } finally {
    signal.removeEventListener('abort', onAbort);
  }
}
