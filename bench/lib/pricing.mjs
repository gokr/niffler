// bench/lib/pricing.mjs — token pricing with two bases per model.
//
// provider: rates of the endpoint actually used. For Synthetic these come
//   from its published model catalog (GET /openai/v1/models → pricing,
//   $/M). Cache writes bill at the prompt rate: the catalog's
//   input_cache_writes=0 reads as "no separate write SKU" (OpenRouter-style
//   schema; DeepSeek's own convention bills cache-populating tokens as
//   ordinary input), not as free writes — the OpenAI dialect reports
//   first-seen tokens as plain prompt, never as a write category.
// official: what the same token volumes would cost at the model's official
//   first-party API list prices (peak tier; DeepSeek off-peak is half).
//   Synthetic-style hosted providers with quota business models can
//   mislead as a market reference, so reports carry both bases.
//
// Keyed by bench model key, with API model ids as aliases.
export const PRICING = {
  // Direct first-party endpoint (config model key `deepseek-v4-flash` →
  // https://api.deepseek.com/v1, model id `deepseek-v4-flash`). Here the
  // provider rates ARE the official list rates, so both bases carry the
  // same numbers — unlike the hosted-gateway entries below. Peak tier;
  // DeepSeek off-peak is half. Cache-populating tokens bill as ordinary
  // input there (no separate write SKU), hence cacheWrite = input.
  "deepseek-v4-flash": {
    label: "DeepSeek V4.1 Flash (direct api.deepseek.com)",
    provider: {
      name: "DeepSeek API (first party)",
      input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: 0.3,
    },
    official: {
      name: "DeepSeek peak list",
      input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: 0.3,
    },
  },
  "syn-deepseek-v41": {
    label: "DeepSeek V4.1 Flash",
    provider: {
      name: "Synthetic catalog",
      input: 0.8, output: 1.2, cacheRead: 0.16, cacheWrite: 0.8,
    },
    official: {
      name: "DeepSeek peak list",
      input: 0.3, output: 1.2, cacheRead: 0.006, cacheWrite: 0.3,
    },
  },
  "syn:large:text": {
    label: "GLM-5.3-Flash",
    provider: {
      name: "Synthetic catalog",
      input: 0.15, output: 0.5, cacheRead: 0.04, cacheWrite: 0,
    },
    official: null, // no verified first-party reference (Zhipu list unchecked)
  },
};

const ALIASES = {
  "hf:deepseek-ai/DeepSeek-V4.1-Flash": "syn-deepseek-v41",
};

export function pricingFor(modelKey) {
  return PRICING[modelKey] || PRICING[ALIASES[modelKey]] || null;
}

// costOnBasis(basis, tokens) — tokens: {input, output, cacheRead, cacheWrite}.
// Returns $ or null when the basis is unavailable.
export function costOnBasis(basis, t = {}) {
  if (!basis) return null;
  return (
    ((t.input || 0) * basis.input +
      (t.output || 0) * basis.output +
      (t.cacheRead || 0) * basis.cacheRead +
      (t.cacheWrite || 0) * basis.cacheWrite) /
    1e6
  );
}
