# Per-developer dollar budgets on the Claude gateway

Three developer tiers, a personal monthly dollar budget each, enforced at an Azure API Management
gateway fronting Claude on Microsoft Foundry — at roughly 100,000 developers.

This document is the design. It extends [Part 5](index.md) (the APIM gateway) and
[Part 6](index.md) (the usage workbook) of the main guide. Architecture diagram:
[`images/tiered-quotas-architecture.drawio`](images/tiered-quotas-architecture.drawio).

Every constraint below is quoted from Microsoft documentation and linked in
[References](#references). Several are non-obvious and at least three contradict the design you
would write from first principles. Verify against your own deployment before building on any of it.

---

## The problem

The gateway policy today gives every developer the same flat allowance
([`infra/03-apim-claude-policy.xml`](infra/03-apim-claude-policy.xml)):

```xml
<llm-token-limit counter-key="@(...callerOid...)"
    tokens-per-minute="20000" token-quota="2000000" token-quota-period="Monthly" ... />
```

The reporting side hardcodes the matching number. The workbook's `pp-quota` tile is titled
*"Month-to-date against the 2,000,000-token quota (edit Quota to match your policy)"* and contains
`| extend Quota = 2000000`.

We want three tiers with per-developer dollar budgets — **Lite $100, Basic $500, Pro $1000** — and a
hard 403 at exhaustion.

The wrinkle: APIM has no cost-limit policy. `llm-token-limit` counts tokens, and
[only some of them](#references): *"The policy currently counts prompt and completion tokens only."*
Dollars need a second mechanism.

### Requirements taken as given

| | |
|---|---|
| Tier source | Entra **app roles** |
| Budget granularity | **Per developer**, tier sets the size |
| Model access | Per-team allowlist enforced by APIM in team-governance `enforce` mode; tier does not determine model access |
| Exhaustion | **Hard 403** until the period resets |
| Clients | **Claude Desktop must keep working** — no client-side change |
| Enforcement lag | **Near-real-time is sufficient** (seconds, not zero) |
| Ownership | A platform team operates the supporting services |

### What 100,000 developers rules out

Scale is the binding constraint, and it kills most of the obvious machinery:

| Mechanism | Why not |
|---|---|
| APIM named value as a blocklist | `value` caps at **4096 characters** ≈ 110 object IDs |
| Per-user Azure Monitor alert dimension | 6,000 alerts/evaluation stateless, 300 stateful; docs warn against *"GUIDs or other high-cardinality"* split dimensions, and each time series bills separately |
| `llm-emit-token-metric` per-user dimension | 100 unique values per dimension, then *"the corresponding metric data is silently discarded"* |
| APIM products + per-developer subscriptions | 100K subscriptions and 100K static keys — and Desktop's *Custom inference headers* is documented *"routing and tenant headers only… No credentials"* |
| Per-user Logic App invocation | O(users) |

### Why not APIM products

Worth recording, because it is the obvious design and the reference
[FinOps framework lab](https://github.com/Azure-Samples/AI-Gateway/tree/main/labs/finops-framework)
uses it.

- **Products cannot be selected from a claim.** APIM resolves the subscription and product at
  request-authorization time, before the policy pipeline runs. Setting `Ocp-Apim-Subscription-Key`
  in an inbound policy is too late.
- **Three keyless tier products is impossible.** *"An API can be associated with at most one open
  product."* Tiering by product therefore requires subscription keys on the wire.
- **Per-developer budgets remove the benefit.** Per-developer counters would mean one subscription
  per person — 100K secrets to mint, distribute, rotate and revoke — to obtain a counter we already
  get free from the `oid` claim.
- **`costQuota` is not an APIM feature.** In that lab it is a field in a Python dict, uploaded to a
  Log Analytics table. Products have no notion of cost.

---

## Design

Three layers. Only one of them adds anything to the request path, and that one fails open.

| Layer | Enforces | Latency | Request-path cost |
|---|---|---|---|
| **1. Tiered token limits** (APIM policy) | TPM → 429, monthly tokens → 403 | synchronous | none — gateway counter |
| **2. Budget flag** (Redis, cached callout) | monthly $ budget → 403 | ~30 s | one cached boolean, fails open |
| **3. Entra `Claude.Suspended` role** | manual admin suspension → 403 | next token | none — a claim already parsed |

Layer 1 is the synchronous hard stop, and the backstop when layer 2 is unavailable. Layer 2 is the
dollar budget. Layer 3 is the human lever — deliberate suspension, visible and reversible in the
Entra portal and captured in the audit log — and costs nothing, because the policy already parses
the `roles` array to determine tier.

### Relationship to the reference AI-Gateway architecture

This adopts the async half of that design — Event Hub, reconciliation Functions, Redis counters,
Cosmos ledger — and deliberately drops three components.

**No cost reservations or holds.** Reservations exist to make enforcement lag zero. Near-real-time
is acceptable here, so they buy nothing and cost a great deal: an orphaned-hold TTL and sweeper for
clients that disconnect mid-stream, and gross over-reservation, because Claude callers routinely set
`max_tokens` to tens of thousands while emitting hundreds. A developer would hit their ceiling long
before spending the money.

**No usage event published from outbound policy.** Use an **Event Hub diagnostic destination**
instead. This is the most important departure, and the reason is specific to these clients: the
gateway runs `buffer-response="false"` because SSE requires it, and both Claude Code and Claude
Desktop stream every request. An outbound policy fires on response *start*, before the stream
completes, so it cannot observe final token counts. APIM's diagnostic pipeline writes
`GatewayLlmLogs` after the response finishes and fans out to Event Hub alongside Log Analytics —
same near-real-time delivery, better numbers, and zero change to the request path.

**No custom dashboard.** The repo already ships a 29-tile workbook and a 20-panel Grafana dashboard
against Log Analytics. Cosmos is the durable chargeback ledger and the rebuild source if Redis is
ever lost — not a second reporting stack.

### Tier table

| Tier | App role | $/month | TPM | Token quota (backstop) |
|---|---|---|---|---|
| Pro | `Claude.Tier.Pro` | 1000 | 40000 | 350,000,000 |
| Basic | `Claude.Tier.Basic` | 500 | 20000 | 175,000,000 |
| Lite | `Claude.Tier.Lite` (default) | 100 | 4000 | 35,000,000 |

Two deliberate choices:

**Token quota = budget ÷ *cheapest* model rate** (Haiku, $1 in / $5 out per MTok), not a blend. Sized on an
average blend it would bind *before* the dollar cap for anyone using cheap models — punishing
exactly the behaviour you want. Set this way it only fires on pathological volume, or when layer 2
is down and failing open. That second case is its real job.

**TPM proportional to budget — 40 per dollar.** Keep this as an approximate fairness and backend
protection control. It does not bound overspend: streamed token counts used by the throttle are
estimated and cache-blind, diagnostics take about 90 seconds to reach Redis, the APIM verdict can
remain cached for another 30 seconds, and requests may still be in flight. The former $0.50 bound
from TPM × cache TTL omitted those terms. See [the enforcement analysis](CACHE-TOKEN-ANALYSIS.md#q2--the-dollar-cap-and-tpm-limit-protect-different-things)
for admission limits and budget reservations needed to establish a defensible bound.

---

## Layer 1 — Tiered token limits

**File:** [`infra/03-apim-claude-policy.xml`](infra/03-apim-claude-policy.xml)

### a. Four app roles

Three tiers plus `Claude.Suspended`, on the existing app registration, assigned via four Entra
security groups. Keep `Claude.User` as the gate in `validate-azure-ad-token` (lines 56-60): tier
roles grant budget, not access. Set **User assignment required** on the app registration.

App roles rather than groups, for the reason the policy already documents at lines 38-42: the
`groups` claim is capped at 200 object IDs, past which Entra omits it entirely and emits
`_claim_names`/`_claim_sources`, failing closed for legitimate users. App roles have no overage
limit.

Two Entra facts that bite at this size:

- Group-based app role assignment **requires Entra ID P1 or P2**.
- **Nested groups are not supported.** *"Assigning groups to an app is supported, but any groups
  nested within the directly assigned group won't have access."* If tiers are meant to follow an
  existing nested org hierarchy, flatten them into direct-membership or dynamic groups. A group
  itself has no member cap — 100,000 members in one group is fine.

### b. Parse the claims once

After `callerOid` is set (after line 72):

```xml
<set-variable name="callerRoles" value="@{
    var jwt = (Jwt)context.Variables["jwt"];
    string[] roles;
    if (!jwt.Claims.TryGetValue("roles", out roles) || roles == null) { return new string[0]; }
    return roles;
}" />
<set-variable name="callerTier" value="@{
    var roles = (string[])context.Variables["callerRoles"];
    if (roles.Contains("Claude.Tier.Pro"))   { return "pro"; }
    if (roles.Contains("Claude.Tier.Basic")) { return "basic"; }
    return "lite";
}" />
```

Three things the obvious code gets wrong:

- `Jwt.Claims` is `IReadOnlyDictionary<string, string[]>`. Use `TryGetValue`; indexing throws when
  the claim is absent.
- **Do not** reuse the `GetValueOrDefault("oid", "unknown")` idiom from line 72 here. That overload
  *"returns comma-separated claim values"* — for a multi-valued `roles` claim you get
  `"Claude.User,Claude.Tier.Pro"`, and `.Contains()` on that string is a substring test that would
  also match `Claude.Tier.ProPlus`. `roles.Contains()` on the `string[]` is LINQ: exact element
  match.
- Precedence is explicit, so a user holding two tier roles deterministically gets the higher one.
  Falling through to `lite` fails safe — a token with no tier role gets the cheapest tier rather
  than no limit at all.

### c. Stamp the tier onto the wire

Beside `x-caller-oid`, in all three places identity is already stamped: request headers (after line
98), `<outbound>` (line 202) and `<on-error>` (line 211). Without the `<on-error>` copy, throttled
and rejected requests carry no tier — and at this size *"which tier is hitting its cap"* is the
whole reporting question. Add `'x-caller-tier'` to both diagnostic header lists in
[`infra/04-apim-gateway.bicep:168-199`](infra/04-apim-gateway.bicep).

### d. Three token limits behind a `<choose>`

```xml
<choose>
  <when condition="@((string)context.Variables[&quot;callerTier&quot;] == &quot;pro&quot;)">
    <llm-token-limit counter-key="@(&quot;pro:&quot; + (string)context.Variables[&quot;callerOid&quot;])"
        tokens-per-minute="40000" token-quota="350000000" token-quota-period="Monthly"
        estimate-prompt-tokens="false"
        tokens-consumed-header-name="x-tokens-consumed"
        remaining-tokens-header-name="x-tokens-remaining"
        remaining-quota-tokens-header-name="x-quota-remaining" />
  </when>
  <when condition="...basic...">  <!-- 20000 / 175000000 --> </when>
  <otherwise>                     <!-- lite: 4000 / 35000000 --> </otherwise>
</choose>
```

- `tokens-per-minute` does **not** accept policy expressions. Only `counter-key`, `token-quota` and
  `token-quota-period` do. So the three number sets cannot collapse into one parameterised element.
- The counter-key is **tier-prefixed**, because the v2 tiers use a token-bucket algorithm and *"all
  instances of rate limit policies across scopes using the same counter key must use the same
  renewal period and call limit values, otherwise policy instances will behave unpredictably."*
  Consequence to document: changing someone's tier mints a fresh counter and a fresh monthly token
  allowance. Their **dollar** budget is unaffected — that lives in Redis, keyed on oid alone — which
  is another reason dollars are the real control.
- `llm-token-limit` *"can be used multiple times per policy definition"*, is inbound-section, and
  lists *"Anthropic Messages API (currently supported in API Management v2 tiers)"* as supported.

### e. Reduce the metric to a tier dimension

At 100K object IDs the per-user dimension on `llm-emit-token-metric` (line 156) exceeds the
100-unique-value cap and the data is silently discarded. Tier has three values. The README already
records that this policy produced no metric namespace at all in the live test — treat it as
best-effort, not the reporting path.

### f. Numbers as named values

`tokens-per-minute="{{tier-pro-tpm}}"` works: named value substitution is textual and happens before
the attribute is interpreted, and it is the only dynamic route for that attribute given expressions
are barred. Declare them from a `tiersConfig` array in
[`infra/04-apim-gateway.bicep:52-80`](infra/04-apim-gateway.bicep) beside the three existing
named values. Standard v2 allows 10,000 named values, so nine is nothing.

The docs never state numeric attributes specifically, so confirm one deploys before converting all
nine. Fallback is literals, or the lab's Bicep string generation:
`join(map(tiersConfig, t => '<when ...>'), '')` with `replace()` on a placeholder.

---

## Layer 2 — The budget flag

### a. The check, in inbound policy

Placed after the claims parse and **before** the token limits, so a rejected request never consumes
quota and the 403 is attributable:

```xml
<!-- manual suspension: free, the roles array is already parsed -->
<choose>
  <when condition="@(((string[])context.Variables[&quot;callerRoles&quot;]).Contains(&quot;Claude.Suspended&quot;))">
    <return-response>
      <set-status code="403" reason="Suspended" />
      <set-header name="x-claude-denied-by" exists-action="override"><value>admin</value></set-header>
      <set-body>{"type":"error","error":{"type":"permission_error","message":"Your Claude access has been suspended. Contact the platform team."}}</set-body>
    </return-response>
  </when>
</choose>

<!-- budget: one cached boolean, ~30s staleness, fails open -->
<cache-lookup-value key="@(&quot;bud:&quot; + (string)context.Variables[&quot;callerOid&quot;])"
                    variable-name="overBudget" caching-type="prefer-external" />
<choose>
  <when condition="@(!context.Variables.ContainsKey(&quot;overBudget&quot;))">
    <send-request mode="new" response-variable-name="budResp" timeout="2" ignore-error="true">
      <set-url>@("https://<budget-api>/v1/budget/" + (string)context.Variables["callerOid"])</set-url>
      <set-method>GET</set-method>
      <authentication-managed-identity resource="{{budget-api-audience}}" />
    </send-request>
    <set-variable name="overBudget" value="@{
        var r = context.Variables.GetValueOrDefault<IResponse>("budResp");
        if (r == null || r.StatusCode != 200) { return "unknown"; }
        return (string)r.Body.As<JObject>()["state"];
    }" />
    <cache-store-value key="@(&quot;bud:&quot; + (string)context.Variables[&quot;callerOid&quot;])"
                       value="@((string)context.Variables[&quot;overBudget&quot;])" duration="30" />
  </when>
</choose>
<choose>
  <when condition="@((string)context.Variables[&quot;overBudget&quot;] == &quot;over&quot;)">
    <return-response>
      <set-status code="403" reason="Budget exceeded" />
      <set-header name="x-claude-denied-by" exists-action="override"><value>budget</value></set-header>
      <set-body>{"type":"error","error":{"type":"permission_error","message":"Monthly Claude budget exhausted for your tier. Resets on the 1st."}}</set-body>
    </return-response>
  </when>
</choose>
```

Load-bearing details:

- **It fails open, deliberately.** `ignore-error="true"`, a two-second timeout, and `"unknown"`
  treated as allowed. A budget-service or Redis outage must not take 100,000 developers offline.
  Layer 1 is still enforcing throughout, which is precisely why the token-quota backstop exists.
- **The cache is fail-open by design too:** *"if cache-related operations fail to connect to the
  cache… the API call… doesn't raise an error, and the cache operation completes successfully. In
  the case of a read operation, a null value is returned to the calling policy expression. Your
  policy code should be designed to ensure that there's a fallback mechanism."* The `ContainsKey`
  guard is that fallback.
- The 30-second TTL bounds both staleness and callout volume. At 100K active developers, steady-state
  load on the budget API is roughly `active_users ÷ 30` requests per second — not one per request.
- `cache-lookup-value` *"can only be used once in a policy section"* and is not supported inside a
  policy fragment. This is the one use.
- `x-claude-denied-by` makes the two 403s distinguishable in logs without parsing bodies.

### b. The accounting pipeline

**Source: an Event Hub diagnostic destination, not policy.** Add Event Hub alongside the existing
Log Analytics destination on the APIM diagnostic setting in
[`infra/04-apim-gateway.bicep`](infra/04-apim-gateway.bicep) — categories `GatewayLlmLogs` and
`GatewayLogs`, which already carry `x-caller-oid` and `x-caller-tier` via the header lists. Log
Analytics keeps receiving everything, so the workbook, Grafana and the hourly summary rule are
untouched.

**Usage processor** (Function, Event Hub trigger):

1. Join `GatewayLlmLogs` to `GatewayLogs` on `CorrelationId` to recover oid and tier.
2. Normalise the model — the `replace_regex(ModelName, @"-\d{8}$", "")` equivalent. Key on
   **`ModelName`**, not `DeploymentName`: the lab joins pricing on the latter, but this repo's
   queries already use `ModelName`, and `DeploymentName` population on the Anthropic path is
   unverified.
3. Price it from a pricing map cached in Redis.
4. `INCRBYFLOAT mtd:{yyyyMM}:{oid}` and `INCRBYFLOAT mtd:{yyyyMM}:tier:{tier}` — atomic, race-free,
   unbounded cardinality, which is the entire reason Redis is here.
5. If the new total crosses the tier's `CostQuota`, `SET over:{oid} 1` with an expiry at month end.
   Month rollover needs no reset job: the counter key is month-scoped and the flag expires.
6. Upsert the request into the Cosmos usage ledger, **idempotent on `CorrelationId`** — Event Hub
   delivery is at-least-once.

**Budget API:** a thin read of `over:{oid}` returning `{"state":"over"|"ok"}`. Keep it read-only and
boringly available; it is the only new thing in the request path.

**Pricing loader.** From the finops lab, and it fixes an existing weakness — the price list is
currently a hardcoded `datatable` copy-pasted into ~20 workbook tiles and every Grafana panel:

```
https://prices.azure.com/api/retail/prices?currencyCode='USD'
  &$filter=serviceName eq 'Foundry Models' and unitOfMeasure eq '1K' and armRegionName eq '<region>'
```

Do **not** assume the Claude meter SKU names — query the endpoint and read them off, the way the
lab's pricing cell prints the table before using it. Write to **both** Redis (for the Function) and
`PRICING_CL` via a Direct data collection rule (for the workbook and Grafana). One loader, two
sinks, stated explicitly rather than discovered later.

**`ClaudeTiers()` saved KQL function** returning `Tier, Tpm, TokenQuota, CostQuota` — one source of
truth for the workbook, Grafana and the summary rule. The Function reads the same values from config.

### c. Reporting

- [`infra/10-claude-usage-summary-rule.bicep:102`](infra/10-claude-usage-summary-rule.bicep) —
  add `Tier` to the `by` clause, sourced from `BackendRequestHeaders["x-caller-tier"]` with the same
  `ResponseHeaders` fallback used for `Oid` at lines 76-80.
- [`infra/08-claude-usage-workbook.json`](infra/08-claude-usage-workbook.json) — replace every
  `let rates = datatable(...)` with a join to
  `PRICING_CL | summarize arg_max(TimeGenerated, *) by Model`. Rewrite `pp-quota`: drop
  `| extend Quota = 2000000`, join `ClaudeTiers()` on `Tier`, lead with **$ spent against
  `CostQuota`** and keep tokens secondary. Add a `Tier` parameter beside `Client`, a per-tier spend
  tile, a currently-over-budget count, and a tile splitting 403s by `x-claude-denied-by`.
- [`infra/12-claude-usage-grafana-dashboard.json`](infra/12-claude-usage-grafana-dashboard.json)
  — same pricing join, plus a `tier` template variable.
- The `ids` join (`arg_max(TimeGenerated, RawUpn) by Oid`, repeated in ~20 tiles) scans every row to
  resolve oid → email. At this size move it onto `ClaudeUsageHourly_CL`, or drop it and resolve oids
  in Entra at report time — which also removes the personal-data obligation the policy comments flag
  at lines 90-92.

---

## Capacity, cost and accuracy

First-order risks, not footnotes.

- **Multi-region is unavailable on the v2 tiers**, and token counters are per-gateway regardless:
  *"This policy tracks token usage independently at each gateway where it is applied… It doesn't
  aggregate token counts across the entire instance."* One region, one instance. Basic v2 and
  Standard v2 scale to **10 units**, Premium v2 to 30. Redis and Cosmos have no such limit, so layer
  2 is the part of this design that survives a future move to multiple gateways — layer 1 would
  silently multiply.
- **There is no published inbound HTTP concurrency limit for v2** — only WebSockets (5,000 per unit,
  60,000 per instance). Both Claude clients hold long-lived SSE streams, which are HTTP, so that
  figure does not formally apply and no equivalent is documented. And APIM does not shed load
  gracefully: *"when an instance reaches its capacity, it won't throttle to prevent overload.
  Instead, it will act like an overloaded web server: increased latency, dropped connections, and
  time-out errors."* **Load-test concurrent SSE streams per unit before committing to a tier.**
- **`counter-key` cardinality at 100,000 distinct values is undocumented** — no stated limit in
  either direction. The docs' own examples key on caller IP and JWT subject, so the pattern is
  sanctioned; the ceiling is not published. Load-test it; do not assume.
- **Redis must be highly available.** It is not in the request path directly, but the budget API
  reads it, and a cold or lost Redis means every developer's counter restarts at zero. Rebuild from
  the Cosmos ledger rather than from Log Analytics — that is the ledger's second job.
- **Log Analytics ingestion** stays at 100% sampling because cost accuracy requires it; you cannot
  sample and still bill correctly. At this size that is a large line item. Keep the hourly summary
  rule so history stays cheap, and consider a Basic or Auxiliary plan for `GatewayLogs` while
  holding the LLM log on Analytics.

### How Claude on Foundry actually bills

Worth stating, because it explains a finding that otherwise looks like a dead end. Claude in
Microsoft Foundry bills through the **Azure Marketplace in Claude Consumption Units**: Anthropic
rates usage in USD at the standard per-model rates, applies any negotiated discount, converts at
**$0.01 per CCU** (100 CCU = $1.00), and reports CCU quantity to the Marketplace hourly. Your Azure
bill shows a single CCU line item.

Two consequences. First, this is why Claude has no meters in the Azure retail prices API — the
rating happens on Anthropic's side and only the CCU total reaches Azure. Second, the Anthropic list
price *is* the basis of the Azure invoice, so a maintained price list is a legitimate source rather
than a guess — provided you adjust for your discount and for a **US Data Zone Standard** deployment,
which carries a 1.1x multiplier on every token category including cache reads and writes.

**Take the rates from the pricing table, never from the model name.** $15/$75 per MTok is Opus 4.1
and Opus 4, both retired; **Opus 5 is $5/$25**. Sonnet 5 is **$2/$10**, not the $3/$15 that Sonnet
4.5 and 4.6 use — the introductory price became permanent and the increase scheduled for
2026-09-01 was cancelled. Getting this wrong is not a rounding error: loading Opus 5 at the retired
rate overstated a live ledger by **2.86x**, and because it inflates spend it would suspend
developers at roughly a third of their real budget.

### Accuracy limits, stated plainly

- **The table and Event Hub have different coverage.** `ApiManagementGatewayLlmLog` has uncached
  input and output only. The raw Event Hub payload also carries cache reads as `promptCachedTokens`,
  which the processor includes. Neither destination reports cache writes. Anthropic's `input_tokens`
  already excludes reads and writes; do not subtract cached tokens from it.
- **Cache writes are a large missing cost.** Five-minute writes bill at 1.25× base input and one-hour
  writes at 2×; reads use the explicit per-model rate (0.1× for the current models). In the measured
  seven-day Opus 5 sample, writes were 62% of spend, with 1h writes alone at 55%. The Event Hub
  processor captured about 38% of cost across models. Workbook costs omit reads too and therefore
  differ from Redis counters. Neither should be presented as a complete per-user bill.
- **Foundry has exact aggregate cache metrics**, including the TTL split, but no user dimension.
  Reconcile by deployment/model/time window and keep missing write cost as a separate shared pool.
  Do not use read-share allocations or a fleet multiplier to suspend individual users; neither has
  a useful per-user accuracy guarantee. A streaming meter is the recommended route to per-user
  write attribution. The design and acceptance cases are in [CACHE-TOKEN-ANALYSIS.md](CACHE-TOKEN-ANALYSIS.md).
- **Streaming estimates apply to the throttle.** Matched wire/log tests found exact uncached input
  and output counts in `GatewayLlmLogs`, including streams. `llm-token-limit` uses estimates for
  streamed calls and remains cache-blind. It cannot compensate for the budget pipeline's missing
  writes.
- **`IsStreamCompletion` is unreliable.** A real streamed Claude Code request logged `False`.
  Panels show only the diagnostic flag, not a measured streaming ratio. New hourly rollups call
  the field `LlmStreamFlagTrueRequests`; historical `StreamedRequests` values have the same caveat.
- **Filter empty `RequestId` on inference logs.** Successful connectivity probes otherwise skew
  request averages. Retain gateway rejection rows separately so 401/403/429 health data survives.
- **Dollar enforcement is delayed and currently partial.** Even complete post-request accounting
  allows concurrent requests and propagation delay to overshoot. A strict cap needs bounded
  admission and atomic reservation/settlement; fail-open behavior cannot guarantee a ceiling.

### Team governance extension

The deployed design can add one team and one team-profile identity per caller from Entra app-role
claims. In `observe`, missing or ambiguous team identity is logged while individual controls
continue; in `enforce`, it returns an identity-attributed 403. APIM applies both individual and
profile-selected team token policies and asks one v2 budget endpoint for user/team cost state.
Redis holds current enforcement state; expanded Cosmos rows preserve the team/profile/tier seen
when the request occurred and are the only supported source for rebuilding attributed counters.
Foundry aggregate metrics cannot supply caller identity and must not reconstruct teams.

Group reconciliation is direct-membership and additive-only. Every governed group receives
`Claude.User`, one default `Claude.Tier.*`, one `Claude.Team.*`, and one
`Claude.TeamProfile.*` assignment. Membership transfer and removal require separate approval,
and role changes require a fresh token. Promotion and rollback evidence is defined in
[the team governance live checklist](docs/team-governance-live-validation.md).

---

## Verify before building

**Layer 1 is verified against the live BasicV2 gateway `AI-Gateway-8177`, 2026-09-04.** Struck
items were proven there; the rest still stand.

1. ~~A named value in a numeric attribute (`tokens-per-minute`) deploys and resolves.~~ **It does.**
   `tokens-per-minute="{{tier-lite-tpm}}"` reported `x-tokens-remaining: 3978` against a 4000 limit;
   the Pro branch reported `39986` against 40000. `token-quota` resolved too — the same developer saw
   35,000,000 as Lite and 350,000,000 as Pro, which also proves the tier-prefixed counter keys are
   genuinely separate buckets.
2. ~~`jwt.Claims` parsing against a real token from a user holding several roles.~~ **Works.** A token
   carrying both `Claude.User` and `Claude.Tier.Pro` selected `pro`; a token with only `Claude.User`
   fell through to `lite`. `ContainsKey` plus `System.Array.IndexOf` sidesteps the comma-joined-string
   trap entirely.
3. ~~That `return-response` rejections still carry identity.~~ **They do**, because the headers are
   repeated inline. A `Claude.Suspended` token returned 403 with `x-claude-denied-by: admin`,
   `x-caller-tier: pro` and `x-caller-oid` all present — the headers `outbound` would have set are
   never applied on that path.
4. ~~That the budget check fails open.~~ **Confirmed.** Pointed at an unreachable host, every request
   still returned 200 and latency was unchanged at 1.8–2.2 s.
5. That an APIM diagnostic setting can fan `GatewayLlmLogs` out to Event Hub **and** Log Analytics
   simultaneously, and what the end-to-end delivery latency actually is. This is the load-bearing
   assumption of the whole accounting path — prove it first.
6. `counter-key` behaviour at high cardinality: load-test toward 100,000 distinct keys.
7. Concurrent SSE streams per v2 unit, and which tier and unit count this actually needs.
8. Whether to wire an **external** Redis cache to APIM. The internal cache is per-region and
   volatile; external gives control over eviction, and you are running Redis anyway.
9. Whether `DeploymentName` is populated on the Anthropic path. `IsStreamCompletion` is already
   proven unreliable; do not use it to classify actual streams.
10. The Claude meter SKU names in the retail prices API for your region.
11. Entra ID P1/P2 present, and the intended tier groups not nested. The roles themselves work when
    assigned directly to a user, which is how they were tested — group-based assignment is the
    untested half.

Two things the live run made concrete. **`x-caller-tier` only reaches Log Analytics once the API
diagnostic lists it** — requests made before that change logged `Tier` as empty, which is exactly what
a half-finished rollout looks like in the workbook. And **role changes apply on the next token in both
directions**: assigning `Claude.Suspended` did not stop the token already in hand, and removing it did
not restore access until a fresh one was minted. The Azure CLI's token cache made that vivid, serving
the same account as `lite` on one cached token and `pro` on another at the same moment. Budget
enforcement is the fast path precisely because this one is not.

## Testing

1. One test account per tier; decode each token and confirm the tier role is present.
2. Per tier: burst past TPM → **429** with `Retry-After`. Confirm `x-caller-tier` is on the 429 —
   that is what proves the `<on-error>` stamp works.
3. Set Lite's `token-quota` tiny, exhaust it, expect **403** naming the reset, then confirm Pro is
   unaffected. That is the real proof the counter-keys are separate.
4. Drive traffic and watch `mtd:{yyyyMM}:{oid}` move in Redis within seconds of the request.
5. Set a $0.01 `CostQuota`; confirm `over:{oid}` is set and requests 403 within one cache TTL, with
   `x-claude-denied-by: budget`.
6. **Fail-open test — the important one.** Stop the budget API, then Redis, and confirm requests
   still succeed rather than 100,000 developers getting 403. Confirm layer 1 still enforces during
   that window.
7. Kill the Function mid-stream and confirm no request is double-counted on replay.
8. Add someone to `Claude.Suspended`; confirm the **existing** token still works and the **next**
   one 403s with `x-claude-denied-by: admin`. Demonstrate that asymmetry rather than discovering it
   in production.
9. Reconcile Redis month-to-date, the Cosmos ledger and the workbook's `ov-cost` tile against each
   other. Three independent paths to the same number is the point; if they disagree, the design is
   not finished.
10. Confirm Claude Desktop still works end to end — nothing here touches the client.

---

## References

Policy and gateway:

- [`llm-token-limit`](https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy)
  — attribute table (which attributes accept expressions), token counting and estimation, streaming
  behaviour, per-gateway counters
- [`llm-emit-token-metric`](https://learn.microsoft.com/en-us/azure/api-management/llm-emit-token-metric-policy)
  — dimension caps and silent discard
- [`cache-lookup-value`](https://learn.microsoft.com/en-us/azure/api-management/cache-lookup-value-policy)
  and [caching in APIM](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-cache)
  — tier support, `caching-type`, fail-open behaviour
- [`send-request`](https://learn.microsoft.com/en-us/azure/api-management/send-request-policy)
- [Policy expressions](https://learn.microsoft.com/en-us/azure/api-management/api-management-policy-expressions)
  — the `Jwt` type and `Claims.GetValueOrDefault` semantics
- [Named values](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-properties)
  and [Named value REST API](https://learn.microsoft.com/en-us/rest/api/apimanagement/named-value/create-or-update)
  — substitution behaviour, 4096-character limit
- [Products](https://learn.microsoft.com/en-us/azure/api-management/api-management-howto-add-products)
  — "at most one open product" per API
- [Flexible throttling](https://learn.microsoft.com/en-us/azure/api-management/api-management-sample-flexible-throttling)
  and [service limits](https://learn.microsoft.com/en-us/azure/api-management/service-limits)
- [v2 tiers overview](https://learn.microsoft.com/en-us/azure/api-management/v2-service-tiers-overview)
  and [capacity](https://learn.microsoft.com/en-us/azure/api-management/api-management-capacity)

Monitoring and identity:

- [`ApiManagementGatewayLlmLog` table reference](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/tables/apimanagementgatewayllmlog)
- [Log alert rules](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule)
  and [Azure Monitor service limits](https://learn.microsoft.com/en-us/azure/azure-monitor/fundamentals/service-limits)
  — dimension caps and the high-cardinality warning
- [Logs query API](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/api/overview)
- [Assign users and groups to an app](https://learn.microsoft.com/en-us/entra/identity/enterprise-apps/assign-user-or-group-access-portal)
  — P1/P2 requirement, no nested groups
- [Directory service limits](https://learn.microsoft.com/en-us/entra/identity/users/directory-service-limits-restrictions)

Reference implementation:

- [Azure-Samples/AI-Gateway — FinOps framework lab](https://github.com/Azure-Samples/AI-Gateway/tree/main/labs/finops-framework)
- [Azure retail prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
