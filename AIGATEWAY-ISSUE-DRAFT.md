## Summary

The `finops-framework` cost model under-reports Anthropic/Claude spend by **~2.6×** on real traffic,
because it prices `PromptTokens` from `ApiManagementGatewayLlmLog` as if it were the full prompt.
For Anthropic models it is not — it excludes all prompt-caching tokens, which on measured production
traffic were **62% of total cost**.

Related to #392, which raises per-user cost control and notes cache-tiered billing generally. This
issue is narrower and concrete: the sample's arithmetic is wrong for Anthropic, and the custom-log
schema cannot express the correct rates.

## The cost model

`labs/finops-framework/workbooks/cost-analysis.json`, duplicated into the alert rules in
`main.bicep` (~L709, ~L760) and into `dashboard.bicep`:

```kusto
| extend InputCost  = PromptTokens     * InputTokensPrice
| extend OutputCost = CompletionTokens * OutputTokensPrice
```

`PRICING_CL` (`main.bicep` ~L100–152) declares exactly four columns:
`TimeGenerated`, `Model`, `InputTokensPrice`, `OutputTokensPrice`.

## Why this is wrong for Anthropic

Anthropic's usage object reports **four** input-side quantities, not one:

```json
"usage": {
  "input_tokens": 2,                      // uncached input ONLY
  "cache_creation_input_tokens": 42334,   // cache write — billed 1.25x (5m TTL) / 2x (1h TTL)
  "cache_read_input_tokens": 0,           // cache read  — billed 0.1x
  "cache_creation": { "ephemeral_5m_input_tokens": 42334, "ephemeral_1h_input_tokens": 0 },
  "output_tokens": 121
}
```

Documented identity: `total_input = input_tokens + cache_creation_input_tokens + cache_read_input_tokens`.

APIM populates `PromptTokens` from `input_tokens` — the **uncached-only** value. So a field named
`PromptTokens`, multiplied by an input price, silently omits the majority of billable input.
`ApiManagementGatewayLlmLog` has no cache columns, and neither does the raw `GatewayLlmLogs`
Event Hub payload, so the sample has no way to recover them.

Repo-wide search confirms none of this is handled anywhere:
`cache_creation_input_tokens` → 0 hits, `cache_read_input_tokens` → 0 hits,
`prompt_tokens_details` → 0 hits (the `cached_tokens` matches are inert OpenAPI schema JSON).

## Measured evidence

Live BasicV2 gateway, Claude on Foundry, requests correlated to log rows by Anthropic message id
(`ApiManagementGatewayLlmLog.RequestId`), ground truth taken from the wire.

**Two requests differing only in cache state — indistinguishable in the log:**

| | cache write | cache read |
|---|---|---|
| Log row | `PromptTokens=17, CompletionTokens=7` | `PromptTokens=17, CompletionTokens=7` |
| Actual | 4,460 tokens written | 4,460 tokens read |
| True cost | **$0.028135** | **$0.002490** |
| Sample's cost | $0.000260 | $0.000260 |
| Under-report | **108×** | **9.6×** |

Two rows the model cannot tell apart, 11× apart in reality. A single real `claude -p` request
measured `input_tokens=2, cache_creation_input_tokens=42334, output_tokens=121` — true cost
$0.2676, sample's cost $0.0030, an **88× under-report on one ordinary request**.

**Seven days of production traffic, claude-opus-5:**

| Component | Tokens | Effective rate | Cost |
|---|---:|---:|---:|
| Input (uncached) | 181,428 | $5.00 | $0.91 |
| Output | 97,972 | $25.00 | $2.45 |
| Cache read (0.1×) | 5,311,188 | $0.50 | $2.66 |
| Cache write 5m (1.25×) | 159,197 | $6.25 | $0.99 |
| Cache write 1h (2×) | 875,313 | $10.00 | $8.75 |
| **Total** | | | **$15.76** |

Cache writes are **62% of spend**; 1-hour writes alone are 55%. The sample bills **$6.03 of a true
$15.79 — 38% of actual.**

Note the error is not a constant factor that could be corrected with a multiplier: it swings by an
order of magnitude with cache behaviour the log cannot observe.

## The data does exist — just not in APIM

`Microsoft.CognitiveServices/accounts` emits three Anthropic-specific Azure Monitor metrics
(category "Models - Usage", PT1M, exportable via diagnostic settings):

| Metric | Maps to |
|---|---|
| `cacheReadInputTokens` | `cache_read_input_tokens` |
| `ephemeral5mInputTokens` | `cache_creation.ephemeral_5m_input_tokens` |
| `ephemeral1hInputTokens` | `cache_creation.ephemeral_1h_input_tokens` |

Verified exact against known ground truth (42,334 and 4,460, both matched to the token). Also
verified empirically that the `InputTokens` metric is **uncached-only**, consistent with Anthropic's
convention — so the components sum without double-counting:

```
cost = InputTokens×base
     + cacheReadInputTokens   × 0.1  × base
     + ephemeral5mInputTokens × 1.25 × base
     + ephemeral1hInputTokens × 2.0  × base
     + OutputTokens × out_rate
```

Caveat: these metrics carry no caller dimension (`ApiName, Region, ModelDeploymentName, ModelName,
ModelVersion, ContextLength`), so they give exact aggregate cost but cannot attribute per user —
the inverse of APIM's table. That trade-off is the substance of #392.

## Suggested fix

1. **Extend `PRICING_CL`** with `CachedInputTokensPrice`, `CacheWrite5mTokensPrice`,
   `CacheWrite1hTokensPrice`. The current four-column schema cannot express cache rates at all, so
   this is a prerequisite rather than a query change.
2. **Source cache tokens from the Foundry metrics above**, joined to the APIM log, rather than from
   `ApiManagementGatewayLlmLog` alone.
3. **At minimum, document the limitation** in the lab README — the sample is currently presented as a
   cost-attribution reference, and anyone applying it to Claude will under-bill by roughly 2.6×
   without any indication that something is missing.

Also worth noting for a separate pass: `labs/finops-framework/policy.xml` and
`labs/token-metrics-emitting/policy.xml` still use `azure-openai-emit-token-metric`, which has been
retired in favour of `llm-emit-token-metric`.

## Environment

- APIM **BasicV2**, Anthropic Messages API passthrough (`/anthropic/v1/messages`)
- Claude on Microsoft Foundry (`claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5`), Marketplace CCU billing
- Clients: Claude Code and Claude Desktop (both stream; all figures above are from streamed requests)
- `GatewayLlmLogs` + `GatewayLogs` → Log Analytics (Dedicated) and Event Hub

Happy to supply the full reproduction — request bodies, wire captures, and the KQL/metric queries —
if useful.
