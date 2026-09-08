# infra — deployable templates

The Bicep and the assets it deploys, split out of [the guide](../index.md) so you can
run it without reading 1,100 lines of prose first. The guide explains *why* each of
these is shaped the way it is; this directory is the *what*.

Everything here is deployed with `az deployment group create` from the **repository
root** — the paths below assume that, and two templates embed a sibling file by
relative path, so keep this directory intact.

## Contents

| File | What it is |
|---|---|
| `03-apim-claude-policy.xml` | The APIM inbound policy: Entra validation, tier derivation, budget check, MI backend auth. Embedded into `04` at deploy time. |
| `04-apim-gateway.bicep` | APIM v2 + system-assigned identity + the Anthropic API + tier named values + the Cognitive Services User role assignment + diagnostics. |
| `08-claude-usage-workbook.json` | The 4-page, 29-tile admin workbook. Embedded into `09`. |
| `09-workbook.bicep` | Deploys that workbook against your workspace. |
| `10-claude-usage-summary-rule.bicep` | Hourly rollup, so reporting survives past raw 30-day retention. |
| `11-grafana.bicep` | Azure Managed Grafana + RBAC. **Billable, and it recurs.** |
| `11a-grafana-workspace-rbac.bicep` | Cross-resource-group role assignment module, used by `11`. |
| `12-claude-usage-grafana-dashboard.json` | The 20-panel Grafana dashboard. |
| `13-import-grafana-dashboard.sh` | Imports it — Azure Managed Grafana has no ARM path for dashboards. |
| `14-claude-tiers.bicep` | `ClaudeTiers()` KQL function, the `PRICING_CL` table, and its DCR. |
| `16-budget-platform.bicep` | Event Hub, Redis, Cosmos, and the two Function Apps. |
| `21-reconciler-metrics-rbac.bicep` | Monitoring Reader for the cost reconciler, on the Foundry account. |

The Python and shell that run *against* this platform live in
[`../snippets/`](../snippets/) — the usage processor, the budget API, the pricing
loader, the cost reconciler, and the smoke tests.

## Deployment status — read this before you trust anything

These templates were not all deployed from scratch. Each file's own header is the
authoritative record; this is the summary.

| Template | Status |
|---|---|
| `16-budget-platform.bicep` | **Deployed and verified end to end, 2026-09-04.** Gateway traffic reaches Redis as month-to-date dollars within ~90s; the Cosmos ledger fills; the policy returns 403 on an over-budget developer. |
| `14-claude-tiers.bicep` | **Deployed and verified 2026-09-04.** |
| `09-workbook.bicep` | **Deployed and verified 2026-09-02** against a live workspace; all 22 queries run against real data. |
| `04-apim-gateway.bicep` | **Compiles; the policy it deploys is verified.** But the policy was proven by applying it with `az rest` to an APIM that already existed — *this template's own resource composition has never been deployed from scratch.* |
| `10`, `11`, `11a`, `21` | Compile. Not deployed from scratch. |

Cloud APIs move. Verify against your own subscription.

## Prerequisites

1. **A Foundry resource with a Claude deployment.** Note the account name; `04` builds
   its backend URL as `https://<account>.services.ai.azure.com/anthropic`.
2. **A Log Analytics workspace.** Nearly every template takes its resource ID.
3. **An Entra app registration** for the gateway, with a `Claude.User` app role that
   your users are assigned.
4. **The `aud` value your clients will actually present.** This is the one that
   catches people: if the app has `requestedAccessTokenVersion: 2`, the `aud` claim is
   the **bare application ID**, *not* the `api://<guid>` identifier URI. Decode a real
   token and read it rather than guessing — every request 401s if this is wrong, and
   nothing in the error says why.
5. **An APIM v2 SKU.** `BasicV2`, `StandardV2`, or `PremiumV2` — the `llm-*` policies
   only understand the Anthropic Messages schema on v2. `az apim create --sku-name`
   cannot create these at all, which is the reason this is Bicep and not CLI.

## Deploy order

The gateway and the budget platform reference each other, so **`04` is deployed
twice**. That is expected, not a mistake.

### 1. The gateway

Leave `budgetApiBaseUrl` at its `https://budget-api.invalid` default on this first
pass. The policy's budget lookup fails, `ignore-error` swallows it, and every request
is treated as within budget — which is what you want before the budget platform
exists.

```bash
az deployment group create -g <rg> -f infra/04-apim-gateway.bicep \
   -p apimName=<name> foundryAccountName=<foundry> \
      publisherEmail=you@contoso.com gatewayAudience=<app-id> \
      logAnalyticsWorkspaceId=<workspace resource id>
```

APIM v2 provisioning takes a while. Role assignments then take up to five more minutes
to propagate — if your first call 403s, wait before you start debugging.

At this point the gateway works. Smoke-test it with
[`../snippets/05-gateway-smoke-test.sh`](../snippets/05-gateway-smoke-test.sh) before
building anything on top.

### 2. Tiers and pricing

```bash
az deployment group create -g <rg> -f infra/14-claude-tiers.bicep \
   -p workspaceName=<log analytics workspace>
```

Then load prices into `PRICING_CL` with
[`../snippets/15-load-pricing.py`](../snippets/15-load-pricing.py), using the
`logsIngestion` endpoint this deployment outputs. Claude prices are absent from the
Azure retail API — it is Marketplace-billed — so the loader carries a maintained list.
**Update it to match your agreement.** Prices are stored per 1K tokens, not per 1M.

### 3. The budget platform

```bash
az deployment group create -g <rg> -f infra/16-budget-platform.bicep \
   -p namePrefix=claudebudget logAnalyticsWorkspaceId=<workspace resource id>
```

Then deploy the two Function Apps from [`../snippets/`](../snippets/):
`17-usage-processor/` and `18-budget-api/`.

### 4. The gateway again

Take three outputs from step 3 and re-deploy `04` with them:

```bash
az deployment group create -g <rg> -f infra/04-apim-gateway.bicep \
   -p apimName=<name> foundryAccountName=<foundry> \
      publisherEmail=you@contoso.com gatewayAudience=<app-id> \
      logAnalyticsWorkspaceId=<workspace resource id> \
      eventHubAuthorizationRuleId=<from 16> \
      eventHubName=<from 16> \
      budgetApiBaseUrl=<from 16> \
      budgetApiAudience=<the budget API app registration ID>
```

Verify per-tier limits and the three rejection reasons with
[`../snippets/19-tier-smoke-test.sh`](../snippets/19-tier-smoke-test.sh).

### 5. Reporting (optional)

```bash
# The Azure Monitor workbook
az deployment group create -g <rg> -f infra/09-workbook.bicep \
   -p logAnalyticsWorkspaceId=<workspace resource id>

# Hourly rollup, for history past 30-day retention
az deployment group create -g <rg> -f infra/10-claude-usage-summary-rule.bicep \
   -p workspaceName=<log analytics workspace name>
```

`10` has a second step its header spells out in full: the destination table is created
by the first bin, not by the deployment, so **its retention must be PATCHed
afterwards** — and `az monitor log-analytics workspace table update` fails on it,
because it sends the whole schema and the summary-rule columns fail its own validation.
Use `az rest --method patch`. Skipping this leaves the rollup at 30 days, which defeats
the point of building it.

### 6. Grafana (optional, **billable**)

~$25/month for the node plus $6/user/month, and it recurs. The `Essential` SKU appears
in the retail price list but ARM rejects it in every region and api-version tried;
budget for `Standard`.

```bash
az provider register --namespace Microsoft.Dashboard   # not registered by default
az deployment group create -g <rg> -f infra/11-grafana.bicep \
   -p grafanaName=<name> logAnalyticsWorkspaceId=<workspace resource id> \
      adminPrincipalId=$(az ad signed-in-user show --query id -o tsv)

./infra/13-import-grafana-dashboard.sh <grafana-name> <resource-group> <workspace-resource-id>
```

The dashboard is a separate import because Azure Managed Grafana exposes no ARM path
for dashboards.

### 7. Cache-write reconciliation (optional)

`21-reconciler-metrics-rbac.bicep` is a **module**, not a standalone deployment — the
Foundry account is usually in a different resource group, and Bicep rejects a
cross-resource-group role assignment with `BCP139`. Its header has the `module` block
to paste. It grants Monitoring Reader so
[`../snippets/20-cost-reconciler.py`](../snippets/20-cost-reconciler.py) can read the
cache-token metrics — the only place on Azure where cache **writes** are reported at
all.

## `tiersConfig` is declared three times

`04`, `14`, and `16` each take a `tiersConfig` array, and **they must match**. A
mismatch is silent: the policy throttles on one set of numbers while the processor
budgets against another.

```bicep
[
  { name: 'pro',   tpm: 40000, tokenQuota: 350000000, costQuota: 1000 }
  { name: 'basic', tpm: 20000, tokenQuota: 175000000, costQuota: 500 }
  { name: 'lite',  tpm: 4000,  tokenQuota: 35000000,  costQuota: 100 }
]
```

`tpm` and `tokenQuota` become APIM named values the policy reads. `costQuota` is **not
used by APIM at all** — it is the dollar budget the usage processor enforces, and it
lives here only so all three numbers for a tier are declared in one place.
[`../TIERED-QUOTAS.md`](../TIERED-QUOTAS.md) explains how the token quota is sized:
budget divided by the *cheapest* model rate, so it does not bind before the dollar cap.

## Known gap: cost coverage is incomplete

The budget platform meters uncached input, output, and cache reads. **Cache writes are
missing**, and in a measured seven-day sample they were 62% of Opus 5 spend. The
workbook omits reads as well. Treat these as partial-cost limits, not complete dollar
ceilings. [`../CACHE-TOKEN-ANALYSIS.md`](../CACHE-TOKEN-ANALYSIS.md) has the evidence
and the remediation design.

## Building without deploying

```bash
for f in infra/*.bicep; do az bicep build --file "$f" --stdout > /dev/null \
  && echo "OK  $f" || echo "FAIL $f"; done
```

Expect one suppressed `BCP037` in `04` — the `largeLanguageModel` diagnostic property
is accepted by the ARM API but missing from the Bicep type definition. Keep the
suppression; dropping the property turns off LLM logging entirely.
