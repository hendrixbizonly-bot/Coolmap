# Coolmap Server

Next.js App Router backend for Coolmap.

## Requirements

- Node.js 22+
- pnpm 10 (`packageManager` field pins `pnpm@10.34.5`)

## Setup

```sh
pnpm install
cp .env.example .env.local   # fill in AI_GATEWAY_API_KEY — local only, never commit
pnpm dev
```

Verify:

```sh
curl http://localhost:3000/api/health   # {"ok":true}
pnpm check   # tsc --noEmit && eslint . && vitest run
pnpm build
```

## Jev evaluation (`lib/jev.ts`)

`evaluateWithJev({ state, questions, model? })` wraps the AI SDK's
`experimental_evaluate` for the `typesafe-ai/jev` model.

- **Key**: uses `AI_GATEWAY_API_KEY` (Vercel AI Gateway). The key lives only in
  `Server/.env.local` / server env — never shipped to clients. Passing an
  explicit `model` bypasses the key check (tests use a mock model).
- **Privacy**: every call sends `providerOptions.gateway.zeroDataRetention = true`.
- **Latency**: hard 3 s `AbortSignal.timeout`; `maxRetries: 0` — no retries.
- **Return contract**:
  - `{ ok: true, answers, probabilities }` — `answers` are the typed SDK
    answers; `probabilities` maps each question id to a `number` (boolean
    questions) or `Record<option, number>` distribution (choice/score).
    Boolean numbers are P(true), not confidence in a selected answer; score
    distribution keys are zero-based level indices. These are model estimates.
  - `{ ok: false, reason }` where reason is `missing_api_key` (no model and no
    key), `timeout` (>3 s), `missing_probabilities` (model answered but did not
    return a distribution — treated as failure rather than guessing), or
    `evaluation_failed` (any provider error; details are not surfaced).
