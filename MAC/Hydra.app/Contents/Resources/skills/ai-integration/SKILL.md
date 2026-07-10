---
name: ai-integration
description: Add a legitimate, near-zero-cost AI backend to a SaaS — one internal OpenAI-compatible router over OpenRouter + Groq + other commercial-free providers, with a best→cheapest priority ladder and automatic fallback. Use when a SaaS needs AI features (chat, generation, coaching, extraction) and you want free/cheap models without violating any provider's terms.
---

# AI integration — your own multi-provider layer

Build **one internal router** that every AI feature calls. It speaks the OpenAI API, tries
models in a **performance-ranked ladder (best first, free/cheap last)**, and falls back
automatically when a provider is rate-limited or down. This gives a SaaS a near-$0 AI backend
using only providers whose free tiers **permit commercial use** — no personal subscription
accounts, no multi-accounting, no ToS circumvention.

## The one rule that keeps this legitimate

Use providers that allow commercial use on their free/cheap tiers, within published rate limits:
**OpenRouter** (incl. `:free` models), **Groq**, **Google AI Studio (Gemini)**, **Cerebras**,
**Cloudflare Workers AI**. Do **not** route customer traffic through personal Claude Code /
Copilot / Codex subscriptions, and do not stack many free accounts to dodge limits — that gets
accounts banned and takes your product down with them. Respect each provider's rate limits; the
fallback handles the occasional 429 gracefully.

## Priority ladder (best model → cheapest fallback)

Keep this in ONE config array so you can re-rank as new models ship. Router tries each in order,
skipping any whose key is missing, dropping to the next on 429 / 5xx / timeout.

| # | Model | Provider | Cost | Use for |
|---|-------|----------|------|---------|
| 1 | `openai/gpt-4o` / `anthropic/claude-3.5-sonnet` | OpenRouter | ~$2.5–3/M | Hardest tasks, paid tiers |
| 2 | `google/gemini-2.5-pro` | OpenRouter / Gemini | cheap paid | Long context, reasoning |
| 3 | `deepseek/deepseek-r1` | OpenRouter | ~$0.5/M | Best cheap reasoning |
| 4 | `llama-3.3-70b-versatile` | **Groq** | **free** | Great default, fast |
| 5 | `deepseek/deepseek-chat:free` | **OpenRouter `:free`** | **free** | Strong general |
| 6 | `qwen/qwen-2.5-72b-instruct:free` | **OpenRouter `:free`** | **free** | Multilingual / Arabic |
| 7 | `gemini-2.0-flash` | **Google AI Studio** | **free** | Fast, generous free tier |
| 8 | `llama-3.1-8b-instant` | **Groq** | **free** | Lowest latency, cheap calls |
| 9 | `llama-3.3-70b` | **Cerebras** | **free** | Fastest inference |
| 10 | `@cf/meta/llama-3.1-8b-instruct` | **Cloudflare Workers AI** | **free** | Always-on last resort |

**Free tier of your SaaS** → serve rows 4–10 ($0 to you). **Paid tiers** → unlock rows 1–3, billed
per token so revenue covers cost. Meter usage per plan (tie into the subscription credits) so a
free user can't drain your paid models.

## Strategies to offer

- **Smart fallback (recommended)** — full ladder; free models for free users, frontier for paid.
- **OpenRouter only** — one `OPENROUTER_API_KEY`, 300+ models incl. many `:free`; simplest ops.
- **Groq only** — one `GROQ_API_KEY`, fastest free tokens/sec; great for latency-sensitive apps.
- **BYOK** — each customer pastes their own key (store encrypted, AES-256-GCM). $0 AI for you,
  fully within every provider's ToS. Optionally add a shared key for a limited free tier.

## Why one client covers them all

Groq, OpenRouter, Cerebras, and Gemini (its `/v1beta/openai` endpoint) all speak the OpenAI Chat
Completions API. So a single `openai` SDK client — just swap `baseURL` + key per provider — talks
to every rung. Cloudflare Workers AI uses its own REST shape; wrap it only if you need the final
fallback.

## Drop-in router (`src/server/ai/router.ts`)

```ts
import OpenAI from "openai";

type Rung = { provider: string; model: string; baseURL: string; keyEnv: string };
const LADDER: Rung[] = [
  // frontier (paid — premium tiers)
  { provider: "openrouter", model: "openai/gpt-4o",                    baseURL: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY" },
  { provider: "openrouter", model: "google/gemini-2.5-pro",           baseURL: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY" },
  { provider: "openrouter", model: "deepseek/deepseek-r1",            baseURL: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY" },
  // free, commercial-use OK
  { provider: "groq",       model: "llama-3.3-70b-versatile",         baseURL: "https://api.groq.com/openai/v1", keyEnv: "GROQ_API_KEY" },
  { provider: "openrouter", model: "deepseek/deepseek-chat:free",     baseURL: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY" },
  { provider: "openrouter", model: "qwen/qwen-2.5-72b-instruct:free", baseURL: "https://openrouter.ai/api/v1", keyEnv: "OPENROUTER_API_KEY" },
  { provider: "gemini",     model: "gemini-2.0-flash",                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", keyEnv: "GEMINI_API_KEY" },
  { provider: "groq",       model: "llama-3.1-8b-instant",            baseURL: "https://api.groq.com/openai/v1", keyEnv: "GROQ_API_KEY" },
  { provider: "cerebras",   model: "llama-3.3-70b",                   baseURL: "https://api.cerebras.ai/v1", keyEnv: "CEREBRAS_API_KEY" },
];

export type ChatMsg = { role: "system" | "user" | "assistant"; content: string };

// Try each configured rung in order; fall through on rate-limit / 5xx / network error.
// maxRung caps quality/cost per plan: free plan -> start at the free rungs, paid -> full ladder.
export async function aiChat(messages: ChatMsg[], opts: { minRung?: number; maxRung?: number } = {}) {
  const rungs = LADDER
    .slice(opts.minRung ?? 0, opts.maxRung ?? LADDER.length)
    .filter(r => process.env[r.keyEnv]);
  if (!rungs.length) throw new Error("No AI provider keys configured — set at least one in .env.server");
  let lastErr: unknown;
  for (const r of rungs) {
    try {
      const client = new OpenAI({ apiKey: process.env[r.keyEnv]!, baseURL: r.baseURL });
      const res = await client.chat.completions.create({ model: r.model, messages });
      console.log(`[ai] served by ${r.provider}:${r.model}`);
      return { text: res.choices[0]?.message?.content ?? "", provider: r.provider, model: r.model };
    } catch (e: any) {
      const status = e?.status ?? e?.response?.status;
      lastErr = e;
      if (status && ![429, 500, 502, 503, 504].includes(status)) throw e; // real error → stop
      console.warn(`[ai] ${r.provider}:${r.model} failed (${status ?? "network"}) → next`);
    }
  }
  throw lastErr ?? new Error("All AI providers exhausted");
}
```

Usage: `const { text } = await aiChat([{ role: "user", content: prompt }])`. For a free-plan user:
`aiChat(msgs, { minRung: 3 })` (skip the paid frontier rows). For a paid user, use the full ladder.

## Provider signup (all commercial-use-OK free tiers)

- **OpenRouter** — https://openrouter.ai/keys — one key → 300+ models incl. many `:free`
- **Groq** — https://console.groq.com/keys — fastest free inference
- **Google AI Studio (Gemini)** — https://aistudio.google.com/apikey — generous free tier
- **Cerebras** — https://cloud.cerebras.ai — fast free tier
- **Cloudflare Workers AI** — https://dash.cloudflare.com — free neurons/day, always-on fallback

## `.env.ai.example`

```
# Set only the ones you use; the router skips missing keys. SERVER-ONLY — never expose to the browser.
OPENROUTER_API_KEY=
GROQ_API_KEY=
GEMINI_API_KEY=
CEREBRAS_API_KEY=
# CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN for the Workers AI last-resort fallback
```

## Checklist

- [ ] Router lives server-side; keys are in `.env.server` only, never sent to the browser.
- [ ] Every AI feature calls `aiChat()` — no direct provider calls scattered around.
- [ ] Plans map to rung ranges (free → free rungs, paid → full ladder); usage metered per user.
- [ ] Streaming variant added if the UI needs it (same pattern, `stream: true`, iterate chunks).
- [ ] Ladder kept in one array; re-rank as better/cheaper models ship.
- [ ] Graceful message to the user if `aiChat` throws (all providers exhausted / no keys).
