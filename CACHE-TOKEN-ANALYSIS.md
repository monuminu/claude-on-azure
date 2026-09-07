# Cache-token blindness in Azure APIM `GatewayLlmLogs` for Anthropic Claude

**Status:** measured, reproduced, root-caused. Design review and local corrections added in §8–§10;
streaming-meter deployment remains proposed.
**Date:** 2026-09-06

---

## 1. System under analysis

An Azure API Management gateway (BasicV2) fronts Anthropic Claude models hosted on Microsoft Foundry.

```
Claude Code / Claude Desktop
        │  Entra ID bearer token (per-user)
        ▼
   APIM BasicV2  ──────────► Foundry (Claude on Azure Marketplace, CCU billing)
        │
        ├─► Log Analytics : ApiManagementGatewayLlmLog  (workbook / KQL)
        └─► Event Hub ─► Azure Function ─┬─► Redis  : mtd:{yyyyMM}:{oid}  (monthly $ per user)
                                         └─► Cosmos : per-request ledger
```

A budget API returns **402** when a developer exceeds their tier's monthly dollar cap; the APIM policy
then **403**s them. Every dollar figure in the system — workbook, Redis counters, enforcement —
derives from the token counts APIM emits.

Authentication is per-user Entra ID. APIM subscription keys are deliberately not used, so
`context.Subscription.*` is unavailable as an attribution key. The user's `oid` is captured in policy
and does **not** reach Foundry (the backend hop swaps to managed identity).

---

## 2. What is correct (verified, do not re-investigate)

**`GatewayLlmLogs` token counts are exact on streamed requests.** This was the original hypothesis
under test, because Microsoft's `llm-token-limit` documentation states token counts are *estimated*
when streaming, and every real Claude client streams.

Method: 12 requests through the live gateway, each correlated to its log row by the Anthropic message
id, which lands in `ApiManagementGatewayLlmLog.RequestId` — an exact join key. Ground truth taken
from the wire (`message_start` + `message_delta` for streamed, response body for non-streamed).

| Test | Mode | Wire in/out | Log prompt/completion |
|---|---|---|---|
| 12,000-char random hex blob | non-stream | 7783 / 1 | 7783 / 1 ✅ |
| same blob | **stream** | 7783 / 1 | 7783 / 1 ✅ |
| count to 200 | non-stream | 25 / 427 | 25 / 427 ✅ |
| count to 200 | **stream** | 25 / 431 | 25 / 431 ✅ |
| 5 header/auth variants | **stream** | 25 / 263 | 25 / 263 ✅ ×5 |
| long output | **stream** | 28 / 861 | 28 / 861 ✅ |
| truncated at `max_tokens` | **stream** | 21 / 150 | 21 / 150 ✅ |
| real `claude -p` | **stream** | 2 / 121 | 2 / 121 ✅ |

The hex-blob case is decisive: the prompt was engineered so a `chars/4` heuristic predicts 3,013.
Landing on 7,783 exactly, streamed, is not estimator behaviour.

**The estimation warning applies to the throttle, not the log.** `x-tokens-consumed` (emitted by
`llm-token-limit`) on the same requests:

| | true total | throttle header | error |
|---|---|---|---|
| hex, non-streamed | 7,784 | 7,784 | exact |
| hex, **streamed** | 7,784 | 6,796 | **−12.7%** |
| count, non-streamed | 452 | 452 | exact |
| count, **streamed** | 456 | 24 | **−94.7%** |

On streams the header approximates the *estimated prompt count alone*; completion tokens are absent
from it. So "policy for enforcement, log for chargeback" is the correct split.

**`IsStreamCompletion` is unreliable but harmless.** A real `claude -p` request, genuinely streamed,
logged `IsStreamCompletion=False`. Five curl variants (gzip, `claude-cli` UA, `x-api-key` + dummy
bearer, `anthropic-beta`, all combined) all logged `True`. The flag does not indicate streaming —
but token counts are exact regardless of what it says. Cosmetic only.

---

## 3. The defect

**`ApiManagementGatewayLlmLog` has three token columns — `PromptTokens`, `CompletionTokens`,
`TotalTokens` — and no cache-token columns.** Distinguish the table from the raw Event Hub payload:
the processor's recorded observation and §6 identify `promptCachedTokens` for **cache reads** in
Event Hub. The earlier captured field list omitted that field and must not be treated as an
exhaustive schema. Cache **writes**, including the TTL split, are absent from both destinations.
Reads are therefore a table-projection gap; writes are a diagnostic-emission gap.

Anthropic's usage object reports four input-side quantities:

```json
"usage": {
  "input_tokens": 2,                        // uncached input ONLY
  "cache_creation_input_tokens": 42334,     // cache WRITE  — billed 1.25x (5m TTL) / 2x (1h TTL)
  "cache_read_input_tokens": 0,             // cache READ   — billed 0.1x
  "cache_creation": { "ephemeral_5m_input_tokens": 42334, "ephemeral_1h_input_tokens": 0 },
  "output_tokens": 121
}
```

Documented identity: `total_input = input_tokens + cache_creation_input_tokens + cache_read_input_tokens`.

APIM populates `PromptTokens` from `input_tokens` — the **uncached-only** value. The field named
"PromptTokens" therefore contains an unlabelled subset of the prompt.

### 3.1 Demonstration

Two requests differing only in cache state, both streamed, byte-identical in the log:

| | cache write | cache read |
|---|---|---|
| APIM log | `prompt=17, completion=7` | `prompt=17, completion=7` |
| Actual | 4,460 tokens written | 4,460 tokens read |
| **True cost** | **$0.028135** | **$0.002490** |
| Log-derived cost | $0.000260 | $0.000260 |
| Under-report | **108×** | **9.6×** |

Two rows the billing pipeline cannot distinguish, 11× apart in real cost. Note the error is not a
constant factor — it swings by an order of magnitude with cache behaviour the log cannot observe.

### 3.2 Magnitude on real traffic

Seven days of production traffic, from Foundry platform metrics (see §4), priced correctly:

**claude-opus-5** ($5/MTok input, $25/MTok output)

| Component | Tokens | Effective rate | Cost |
|---|---:|---:|---:|
| Input (uncached) | 181,428 | $5.00 | $0.91 |
| Output | 97,972 | $25.00 | $2.45 |
| Cache read (0.1×) | 5,311,188 | $0.50 | $2.66 |
| Cache write 5m (1.25×) | 159,197 | $6.25 | $0.99 |
| **Cache write 1h (2×)** | **875,313** | **$10.00** | **$8.75** |
| **Total** | | | **$15.76** |

- Cache writes are **62% of spend**.
- 1-hour cache writes alone are **55% of Opus 5 cost** — the single largest line item.
- Across all Claude models the pipeline currently bills **$6.03 of a true $15.79 → 38% of actual.**

---

## 4. What the platform *does* expose

`Microsoft.CognitiveServices/accounts` emits three Anthropic-specific Azure Monitor metrics
(category "Models - Usage", PT1M grain, exportable to Log Analytics):

| Metric | Maps to |
|---|---|
| `cacheReadInputTokens` | `cache_read_input_tokens` |
| `ephemeral5mInputTokens` | `cache_creation.ephemeral_5m_input_tokens` |
| `ephemeral1hInputTokens` | `cache_creation.ephemeral_1h_input_tokens` |

Verified against known ground truth twice — 42,334 and 4,460 — exact both times, with all five calls
of a controlled test reconciling (2 writes + 3 reads).

Also verified empirically: **`InputTokens` is uncached-only**, matching Anthropic's convention. So:

```
cost = InputTokens×base
     + cacheReadInputTokens   × 0.1  × base
     + ephemeral5mInputTokens × 1.25 × base
     + ephemeral1hInputTokens × 2.0  × base
     + OutputTokens × out_rate
```

**Limitation:** dimensions are `ApiName, Region, ModelDeploymentName, ModelName, ModelVersion,
ContextLength`. There is **no caller/user/subscription dimension**, and there cannot be — the user's
`oid` never reaches Foundry. This is the precise inverse of APIM's table: attribution without
numbers, vs numbers without attribution.

---

## 5. Ruled out (with evidence — do not re-explore)

1. **`AzureOpenAIRequestUsage` diagnostic category.** Enabled on the live Foundry resource, five
   cache-heavy requests (streamed and non-streamed) over 15 minutes → **zero rows in any table**.
   Does not emit for Anthropic deployments. Setting has been removed.

2. **Reading the response body in APIM policy.** Requires `buffer-response="true"`, which breaks SSE
   passthrough. Every real Claude client streams.

3. **`llm-token-limit` for cache accounting.** Documented: "counts prompt and completion tokens
   only." Cache-blind by design — see §6 open question 2.

4. **`llm-emit-token-metric` preview (June 2026).** Adds "cached, reasoning, thinking" categories,
   but that is the OpenAI `prompt_tokens_details.cached_tokens` shape, which is **read-only**.
   Anthropic's cache *writes* have no OpenAI analogue and no documented metric. Also a tier conflict:
   Anthropic Messages API requires **v2 tiers**, while the Early release channel gating preview AI
   features is documented as **classic tiers only**. Gateway is BasicV2.

5. **Anthropic Admin/Usage API** (`/v1/organizations/usage_report/messages`), which *does* report
   cache tokens split by TTL per API key: explicitly **unsupported for Foundry traffic**. Same for the
   Claude Code Analytics API.

6. **Azure Cost Management.** Claude bills through a single Marketplace CCU meter at $0.01/CCU;
   Learn states usage is "aggregated under the CCU meter rather than broken down by Claude model."
   No cache breakout, no per-model breakout.

7. **`Azure-Samples/AI-Gateway`.** Repo-wide search: `cache_creation_input_tokens`, `cache_read_input_tokens`,
   `prompt_tokens_details` → **zero hits**. The flagship `finops-framework` sample computes
   `PromptTokens × InputPrice + CompletionTokens × OutputPrice` and its `PRICING_CL` table has only
   `InputTokensPrice` / `OutputTokensPrice` — structurally incapable of expressing a cache rate.
   Open issue [#392](https://github.com/Azure-Samples/AI-Gateway/issues/392) names this gap; unanswered since Aug 2026.

8. **`koureasstavros/AzureAIGatewayCostMechanism`** (the only public third-party attempt). Reviewed:
   reads only `cache_read_input_tokens`; computes `rate × (input_tokens − cached)` which
   **double-subtracts** (Anthropic's `input_tokens` is already exclusive) and **goes negative** on
   cache-heavy requests — a realistic mid-session call yields −$0.165, crediting the user's counter.
   Its streaming path scans for `response.completed`, an *OpenAI Responses* event that never appears
   in an Anthropic stream, so streamed requests bill $0. Also buffers the body and keys attribution
   off `context.Subscription.Key`. Nothing salvageable.

---

## 6. Open questions for analysis

**Q1 — Apportionment model.** Per-user data available: `input_tokens`, `output_tokens`, and
`cache_read_input_tokens` (the Event Hub payload carries `promptCachedTokens`, which the Log
Analytics table drops). Missing per-user: **cache writes only**. Aggregate cache-write totals are
exact from Foundry metrics.

Proposed: apportion aggregate cache-write cost across users by each user's share of cache *reads*,
on the reasoning that reads follow writes within a session. **Is there a better estimator?** Consider
that a write is followed by a variable number of reads depending on session length, so read-share may
systematically under-attribute users with short sessions (write once, read once) relative to users
with long ones. Is per-user *request count at a cache breakpoint*, or first-request-per-session, a
better proxy? What is the bounded error of each?

**Q2 — Second enforcement hole.** `llm-token-limit` counts prompt + completion only, so tier TPM
quotas are also cache-blind. A developer can consume 42,000 cache-write tokens per request without
moving their token quota. Does this warrant a separate mitigation, or is the dollar cap sufficient
once corrected?

**Q3 — Cap recalibration.** Accepting no per-user cache-write attribution means per-user figures read
~38% of reality, making tier dollar caps ~2.6× more generous than intended. Should caps be divided by
a ratio recomputed monthly from Foundry metrics, or is a static correction factor acceptable given the
ratio drifts with caching behaviour?

**Q4 — The 1-hour cache anomaly.** 875,313 tokens of 1-hour-TTL cache writes in 7 days — 55% of all
Opus 5 cost, and the dominant cost driver. Nothing in the current stack identifies which client or
workload sets `ttl: "1h"`. How would you attribute this without per-request cache visibility?

**Q5 — Is a sidecar justified?** Every gateway that solves this (LiteLLM, Helicone, Envoy AI Gateway,
agentgateway) uses the same architecture: a linear streaming transform that copies each chunk into a
bounded decode buffer, extracts complete SSE frames, and forwards the original chunk untouched —
explicitly *not* `tee()`, which buffers without backpressure. APIM has no equivalent primitive.
Is inserting such a component worth the operational cost versus accepting apportionment?

If pursuing this, three known traps: (a) `message_delta.usage` is **cumulative**, not incremental —
set, never add (Envoy #2279 was cache tokens double-counted this way); (b) do **not** assume
`message_start` carries the cache fields — some backends report them only on `message_delta`; merge
both events per-field taking the non-zero value (Envoy #2290); (c) handle interrupted streams
explicitly or a dropped connection bills as zero.

---

## 7. Corrections to apply regardless of design

1. **1-hour cache writes bill at 2×, not 1.25×.** Current pricing assumes a flat 1.25×. On the 7-day
   sample this alone under-prices by $3.28 of $15.76 (~21%).
2. **Documentation and panels:** the claim that `IsStreamCompletion` marks streamed rows is false (§2).
3. **Log hygiene:** 152 rows in 7 days have empty `ModelName` and zero tokens — Claude Code's
   `HEAD /api/hello` connectivity probes, ~44% of all rows. Zero-cost, but they skew per-request
   averages. Filter with `| where isnotempty(RequestId)`.

---

## 8. Design review — decisions and limits

**Recommendation:** retain directly observed per-user input, output and cache-read costs; report
aggregate cache-write cost separately until a streaming meter can attribute it. Do not turn
read-share allocation or a global multiplier into individual suspension decisions. For the stated
requirement of accurate per-developer dollar budgets, a streaming meter is justified. For a small
pilot that can accept a shared write-cost pool, aggregate reconciliation is sufficient temporarily.

These are design conclusions from the recorded measurements, not additional live verification.
The existing dollar cap remains a cap on **observed partial cost**, not a ceiling on actual spend.

### Q1 — Apportionment cannot recover the missing attribution

For one aligned resource/deployment/model/time window, define:

```
E_i = uncached_i × input_rate + read_i × read_rate + output_i × output_rate
W   = write_5m_total × write_5m_rate + write_1h_total × write_1h_rate
A_i = the unknown cache-write cost attributable to user i
```

Rates in this equation are dollars per token. The loader uses dollars per **1,000** tokens, so
divide its calculated products by 1,000. In a closed population, `sum(A_i) = W`, `A_i >= 0` and the
fleet cost is `sum(E_i) + W`. If the Foundry deployment has direct callers or other gateways,
some of `W` belongs outside this population; keep that part unattributed.

No available proxy identifies `A_i`:

| Proxy | Failure case | Appropriate use |
|---|---|---|
| Cache-read token share | Write once and leave: positive write cost, zero weight. Long sessions accumulate reads against one write. Shared prefixes may also be read by another user. | Optional, explicitly estimated team allocation |
| Request count | Many short, uncached requests outweigh one large cold prefix; ignores prefix size and TTL. | Operational activity only |
| Requests declaring a cache breakpoint | A breakpoint can hit or miss; its presence does not measure a write. Multiple breakpoints and partial prefix hits complicate counts. | Candidate-write telemetry |
| First request per session | Session identity is not in these logs. Concurrent sessions, idle expiry, compaction, prefix changes and shared caches break the one-session/one-write assumption. | A feature for a later calibrated model |
| Positive growth in cache-read tokens | Can suggest a previous prefix extension, but misses write-only traffic, failed reuse and cross-user reuse. | Investigation, not billing |

For example, two users each write an equally large prefix. One reads it once, the other 100 times.
Their true write shares are 50% each; read-share assigns about 1% and 99%. The estimate penalizes
reuse and undercharges the short session. A user with no reads is the more severe failure.

**Error bound:** for any chosen share `s_i`, the estimate is `W × s_i` while actual `A_i` can be
anywhere in `[0, W]`. Its signed error lies in
`[-W × (1 − s_i), W × s_i]`; its worst absolute error is
`W × max(s_i, 1 − s_i)`. There is no finite relative-error guarantee when actual cost approaches
zero. Finer time windows or model grouping reduce the dollars in a pool, but do not solve the
identifiability problem. An all-zero weight denominator must leave the pool unallocated.

If finance requires an allocation, keep `observedCostUsd`, `allocatedWriteCostUsd`, allocation
method/version and source window separate. Allocate within matching model/deployment/rate cohorts,
preserve the fleet total, and never describe allocated dollars as measured per-user usage. Do not
write this allocation into `mtd:*` or `over:*`.

### Q2 — The dollar cap and TPM limit protect different things

Correct dollar accounting would close the *monthly cost* gap, but it would not protect minute-scale
capacity or tightly bound overspend. Cache-blind, estimated TPM is an approximate fairness control.
The existing diagnostic processor observes about 90 seconds of delay before Redis updates; the
30-second APIM verdict cache adds delay on top. In-flight requests and concurrency add exposure,
and missing write charges can prevent a block altogether. The previous `$0.50` bound obtained from
`40,000 TPM × 30s × $25/MTok` is therefore invalid.

Keep the token policy, but add per-user request-rate and concurrent-stream limits if capacity
protection is required. Choose limits from measured workloads; request count alone has no dollar
bound unless request size, allowed models, output tokens and retries are bounded too. Prefer a
distributed concurrency/admission control in the streaming meter if several replicas serve users.

With a verified maximum cost `Cmax` per admitted request, admission rate `r` requests/second,
at most `k` concurrent requests, and accounting-plus-cache delay `T`, a conservative delayed-control
exposure estimate is `(r × T + k) × Cmax`, subject to the limiter's burst allowance. Without those
bounds, there is no defensible maximum overspend. A strict ceiling needs atomic pre-request budget
reservation and settlement against measured usage, including cancellation; a post-request flag,
even with exact counts, is still a soft cap. Dependency failures must have an explicit admission
policy if a strict ceiling is required; the current fail-open policy cannot promise one.

### Q3 — Do not divide individual caps by 2.6

The sample's `$6.03 / $15.79 ≈ 38%` describes the **Event Hub processor**, including cache reads.
It must not be applied to the workbook, which omits reads as well. The Opus-only observed components
sum to `$6.012034`; writes add `$9.74811125`, giving `$15.76014525` before rounding.

Dividing a nominal cap `B` by the fleet ratio `R = full_cost / observed_cost` makes that cap consume
approximately `B` real dollars only for a user whose own ratio is `R`. Different cache behavior
breaks that premise: an uncached user could be suspended early while a write-heavy user still
overspends. Recomputing `R` monthly reduces staleness; it does not remove this attribution bias.

Leave the contractual dollar caps unchanged. For forecasting, publish a rolling, cohort-specific
coverage ratio with its sample window, data delay and unallocated residual; use it for team reserves
and capacity planning. Label any fleet safety threshold as an aggregate control. Do not retroactively
inflate individual counters or silently change limits in response to another user's workload.

### Q4 — Attribute requests asking for 1h TTL before attributing their cost

The metric establishes that 1h writes occurred, not which client caused them or whether the longer
TTL was wasteful. Add request-side telemetry at the authenticated boundary: APIM correlation ID,
server-derived `oid`/tier, deployment/model, timestamp, client version/User-Agent, explicit 5m and
1h `cache_control` breakpoint counts, and any supported top-level cache setting. If using APIM,
parse the request with `preserveContent: true`; verify request-size and parse-latency limits and
byte-equivalent backend requests. This does not require reading or buffering the SSE response.
Implement as an opt-in diagnostic change, with a named schema and recorded sampling coverage.

Log only this allowlist of metadata, not prompts, message text, tokens or entire bodies. Overwrite
any client-supplied attribution headers. User-Agent is a client hint, not an authorization identity.
Report "requests asking for 1h", not "1h write tokens": declarations may hit an existing cache.
Missing/implicit TTLs must be classified using the applicable API semantics, not silently assigned
to 1h. Compare these requests with the deployment/time-window metrics to identify likely workloads;
only response usage can establish the actual per-request write counts.

Do not globally rewrite TTLs yet. A 1h write costs an extra `0.75 × base` per token up front versus
5m, but avoiding a later 5m rewrite saves `(1.25 − 0.1) × base` at that reuse. One avoided rewrite
can already repay the premium. Measure idle gaps and reuse before recommending a client setting.

### Q5 — A streaming meter is warranted for individual cost enforcement

Insert a small reverse proxy between APIM and Foundry, keeping APIM as the authentication and
policy boundary. The proxy becomes the backend caller and uses its own managed identity for
Foundry. Authenticate APIM to it, restrict ingress, and trust `oid` only from that authenticated
hop; do not make a public proxy that accepts caller-supplied identity headers.

This provides a point where caller identity and the original Anthropic usage object coexist.
It is a new service on the request path, so require streaming, failure and accounting acceptance
tests before adoption. A mature proxy is also an option, but verify this exact Foundry/Anthropic
TTL usage shape, identity model and cancellation behavior before selecting one.

The parser and accounting contract must include:

1. **Bounded forwarding.** Read a chunk, inspect with a bounded incremental UTF-8/SSE decoder,
   then await downstream forwarding of the original bytes. No `tee()`, whole-response buffer or
   unbounded background queue. Handle arbitrary chunk boundaries, CRLF/LF and multiline `data:`.
   Bound both line and frame size. Oversized/malformed frames mark metering incomplete and trigger
   an observable failure policy; they must never silently become complete zero-cost records.
   Ensure compression is negotiated or decoded correctly for inspection.
2. **One cumulative state.** Merge `message_start.message.usage` and `message_delta.usage` by
   field. Set cumulative values, never add events. A missing field or a zero placeholder must not
   erase an earlier positive count; conflicting decreases need a diagnostic. Accept usage that
   appears only on delta. Price uncached input, cache reads, 5m writes, 1h writes and output once.
   Never subtract reads from `input_tokens`, and never add the cache-creation total on top of its
   TTL subtotals. A known write total without a TTL split is incomplete for exact pricing; it can
   be bounded between 1.25× and 2×, not automatically assigned to 5m.
3. **Honest termination.** Finalize once on normal `message_stop`, upstream error, timeout or
   downstream disconnect. Cancel upstream work when the client disconnects. Persist last observed
   counts with `complete`, `interrupted` or `usage_missing` status. Output generated after the last
   reported usage is unknown; a proxy cannot reconstruct it exactly. A fully missing usage object
   is unknown cost, not zero. Retain it for aggregate reconciliation.
4. **Durable accounting.** Give every upstream attempt a unique ID plus APIM correlation and
   Anthropic message IDs. Record retries separately if they can consume billable work. Use a
   durable idempotent ledger/outbox and derive Redis counters from it with atomic replay protection.
   The existing processor sets `done:{cid}` before updating Redis and Cosmos and swallows event
   failures: a crash between these steps can lose accounting. Replacing its input alone does not
   solve that failure mode. Unknown models/rates require an alert and unresolved ledger status.
5. **One billing source.** Shadow the meter first, comparing matched request IDs and all five
   aggregate token components. At cutover, select exactly one canonical source per request; do not
   sum APIM and proxy usage. APIM remains useful for gateway health. Retain source, pricing version,
   event timestamp and usage completeness in the ledger. Use request occurrence time for monthly
   attribution, so delayed events across a month boundary are not charged to the wrong month.

Acceptance cases: streamed/non-streamed calls; no cache, read, 5m write, 1h write and mixed TTLs;
usage arriving only on delta; repeated cumulative events and zero placeholders; every byte split
including UTF-8 and CRLF boundaries; oversized frames; missing usage; early disconnects; timeouts;
retries; duplicate delivery; sink failure and process restart. Verify time-to-first-byte, sustained
streaming, bounded memory under slow consumers, and agreement with settled Foundry aggregates.
Daily metric reconciliation remains necessary even after the meter is deployed.

## 9. Immediate corrections in this repository

- `15-load-pricing.py` now holds explicit read, 5m-write and 1h-write rates, and publishes all five
  categories to Redis. `PRICING_CL` stays input/output-only because its existing consumers have no
  cache counts. Loading write rates does **not** make the existing processor bill writes.
- The processor omits empty-ID, empty-model, zero-usage probes (retaining anomalous usage without
  a message ID so known charges survive) and marks missing write counts as `null` in
  new ledger rows, with cost coverage/source and pricing status. Existing counters still contain
  observed input/output/read cost only; no multiplier or inferred write allocation is applied.
- The workbook, Grafana and hourly rollup filter empty-ID LLM rows. Their join starts from gateway
  logs and retains rejected requests for health reporting, preventing the inference filter from
  hiding budget, admin or throttle rejections. Successful non-inference probes are excluded from
  usage averages; raw gateway activity remains available.
- Stream panels label the unreliable APIM flag. New rollups use `LlmStreamFlagTrueRequests` instead
  of `StreamedRequests` and add `InferenceRequests`; historical rows retain their legacy schema.
  Any external query using the old field needs migration. The supplied history panels use total
  requests/tokens and do not consume that field. Old request totals still include probes and must
  not be compared with new totals without annotating the rollout boundary.
- Guide text now distinguishes exact reported token counts from complete billing, corrects TTL
  prices, and removes the unsupported overspend bound. Workbook budget percentages are explicitly
  distinct from Redis enforcement counters.

These are local changes. No Azure resources, prices, policies, counters or dashboards have been
updated remotely, and no historical rows have been rewritten.

Local validation: eight regression tests pass (`python -m unittest discover -s tests -v` with the
processor dependencies and `requests` installed); the three changed Bicep files compile; both
dashboard JSON files parse and all 39 usage queries retain the inference filter and rejection join.
The pricing test reproduces the Opus sample total and the $3.28242375 TTL-pricing difference.
KQL checks are structural only; the revised queries and rollup schema have not been tested live.

## 10. Rollout sequence

1. Review and deploy the local pricing/reporting corrections through the usual release process.
   Record the rollup schema/counter boundary and validate the destination table's schema migration.
   Verify the raw `promptCachedTokens` field against wire
   usage when validating the revised pipeline; do not reopen the already resolved streaming-token
   estimator investigation.
2. Reconcile **settled** Foundry totals daily by resource, deployment, model/version and rate cohort
   against the matching ledger interval. Use `Total` aggregation and avoid summing an all-dimension
   series together with its split series. Preserve model dimensions through the Metrics API if
   diagnostic export flattens them. Account for direct traffic, delivery lag, price/discount scope
   and incomplete requests. Keep the shared write pool and other residuals separate.
3. Add the bounded request-side TTL telemetry and investigate the 1h workloads. Keep nominal caps
   unchanged; make the current partial-coverage limit visible to operators.
4. Implement and shadow the streaming meter against the acceptance cases above, including durable
   settlement and month attribution. Choose the operational failure policy and acceptable exposure.
5. Cut over once the five token categories reconcile and single-source accounting is verified.
   Add reservations if a strict cap is required. Rollback must select APIM partial accounting
   explicitly, never double bill or present fallback coverage as complete.
