// Tier definitions and the pricing table that turns tokens into dollars.
//
// STATUS: DEPLOYED AND VERIFIED 2026-09-04. ClaudeTiers() returns the three tiers and
// joins correctly from the workbook; PRICING_CL holds four rows and the end-to-end cost
// query produces real dollar figures per developer per tier.
//
// One fix was needed: a Direct-kind DCR is capped at 30 characters, which ordinary DCRs
// are not. See the comment on the resource below.
//
//   az deployment group create -g <rg> -f infra/14-claude-tiers.bicep \
//      -p workspaceName=<log analytics workspace>
//
// Two things live here, and they are the single source of truth for everything
// downstream — the workbook, the Grafana dashboard, the summary rule and the usage
// processor all read one of them rather than carrying their own copy:
//
//   ClaudeTiers()  a saved KQL function returning the three tiers and their limits.
//                  Three rows that change a few times a year do not justify a second
//                  ingestion pipeline; a function is callable from every query surface.
//   PRICING_CL     model prices, loaded by 15-load-pricing.py. This replaces the
//                  hardcoded `let rates = datatable(...)` block that was copy-pasted
//                  into roughly twenty workbook tiles and every Grafana panel — one
//                  place to be wrong instead of twenty.
//                  NOT sourced from the Azure retail prices API, despite that being the
//                  finops lab's approach: Claude has no meters there at all. It is
//                  Marketplace-billed, and Marketplace pricing is not exposed. The
//                  loader carries a maintained list instead; see its header.
//   ClaudeCostRollup_CL
//                  aggregate cost per model per bin, written by 20-cost-reconciler.py
//                  from the Foundry account's Azure Monitor metrics. It is the only
//                  surface here that includes CACHE WRITES — 62% of measured spend, and
//                  reported by no APIM log, payload or metric. Aggregate only: those
//                  metrics carry no caller dimension, so it cannot be joined to a user.

@description('Name of the Log Analytics workspace holding GatewayLlmLogs and GatewayLogs.')
param workspaceName string

param location string = resourceGroup().location

@description('Must match the tiersConfig passed to 04-apim-gateway.bicep. costQuota is the monthly dollar budget per developer and is enforced by the usage processor, not by APIM.')
param tiersConfig array = [
  { name: 'pro',   tpm: 40000, tokenQuota: 350000000, costQuota: 1000 }
  { name: 'basic', tpm: 20000, tokenQuota: 175000000, costQuota: 500 }
  { name: 'lite',  tpm: 4000,  tokenQuota: 35000000,  costQuota: 100 }
]

@description('Principal that uploads rows to PRICING_CL. Defaults to whoever runs the deployment, which is right for a hand-run loader; point it at the loader job identity once it is automated.')
param pricingPublisherPrincipalId string = deployer().objectId

@description('Principal type for the above. Change to ServicePrincipal when the loader runs unattended.')
param pricingPublisherPrincipalType string = 'User'

var resourceSuffix = uniqueString(subscription().id, resourceGroup().id)

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
}

// ---------------------------------------------------------------------------
// ClaudeTiers()
// ---------------------------------------------------------------------------
// CostQuota is a long, not a real: whole dollars keep the datatable literals honest.
// KQL datatable values must be constants, so emitting "1000" into a real column is the
// kind of thing that works until someone sets a budget of 99.50. If you need cents,
// change the column type to real here AND make sure every costQuota in tiersConfig is
// written with a decimal point.
var tierRows = join(map(tiersConfig, t => '    "${t.name}", ${t.tpm}, ${t.tokenQuota}, ${t.costQuota}'), ',\n')

resource tiersFunction 'Microsoft.OperationalInsights/workspaces/savedSearches@2020-08-01' = {
  parent: workspace
  name: 'claude-tiers'
  properties: {
    category: 'Claude'
    displayName: 'Claude tier limits'
    functionAlias: 'ClaudeTiers'
    version: 2
    query: 'datatable(Tier:string, Tpm:long, TokenQuota:long, CostQuota:long)\n[\n${tierRows}\n]'
  }
}

// ---------------------------------------------------------------------------
// PRICING_CL
// ---------------------------------------------------------------------------
// NO CACHE PRICE COLUMNS, and the reason is worse than "the log lumps them together".
// ApiManagementGatewayLlmLog does not report cached tokens AT ALL — not in their own
// column, and not folded into PromptTokens. VERIFIED: two identical calls carrying a
// 1,894-token cached system prompt. Anthropic returned cache_creation_input_tokens=1894
// then cache_read_input_tokens=1894; the log recorded PromptTokens=15 for both.
//
// So there is nothing here for a cache rate to multiply. Cache writes bill at 1.25x
// input for 5m TTL and 2x for 1h TTL; reads at 0.1x for these models. Neither is visible — which means
// cost computed from this table UNDER-reports, and under-reports most for the callers
// who are most expensive to serve. Adding cache prices would imply an accuracy the
// inputs cannot support. See the accuracy section of TIERED-QUOTAS.md.
resource pricingTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'PRICING_CL'
  properties: {
    totalRetentionInDays: 730
    plan: 'Analytics'
    retentionInDays: 730
    schema: {
      name: 'PRICING_CL'
      description: 'Claude model prices per 1K tokens. Maintained list - Claude is absent from the Azure retail prices API.'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'Model', type: 'string' }
        { name: 'InputTokensPrice', type: 'real' }
        { name: 'OutputTokensPrice', type: 'real' }
      ]
    }
  }
}

// ClaudeCostRollup_CL
// ---------------------------------------------------------------------------
// The other half of the cost picture, and the half PRICING_CL cannot express.
//
// PRICING_CL above holds rates for tokens the gateway can SEE. This table holds priced
// TOKEN COUNTS for the ones it cannot — cache writes — sourced from the Foundry account's
// own Azure Monitor metrics (ephemeral5mInputTokens / ephemeral1hInputTokens /
// cacheReadInputTokens) by 20-cost-reconciler.py. On measured traffic those writes were
// 62% of Claude spend, so this is not a rounding correction.
//
// NO CALLER COLUMN, deliberately. Those metrics carry ModelName but no oid, because the
// user's token never reaches Foundry — APIM swaps it for managed identity at the backend
// hop. This table is exact in aggregate and silent about who spent it. Joining it to a
// developer would be inventing attribution the source does not have.
//
// BinStart is carried separately from TimeGenerated because Logs Ingestion is append-only:
// re-running a window appends rather than replaces. Readers must collapse duplicates with
// `summarize arg_max(TimeGenerated, *) by BinStart, Model` or a re-run silently doubles
// the cost.
resource costRollupTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: 'ClaudeCostRollup_CL'
  properties: {
    totalRetentionInDays: 730
    plan: 'Analytics'
    retentionInDays: 730
    schema: {
      name: 'ClaudeCostRollup_CL'
      description: 'Aggregate Claude cost per model per bin, priced from Foundry metrics. Includes cache writes, which no APIM surface reports. No per-user attribution.'
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'BinStart', type: 'datetime' }
        { name: 'Model', type: 'string' }
        { name: 'ResourceName', type: 'string' }
        { name: 'InputTokens', type: 'long' }
        { name: 'OutputTokens', type: 'long' }
        { name: 'CacheReadTokens', type: 'long' }
        { name: 'CacheWrite5mTokens', type: 'long' }
        { name: 'CacheWrite1hTokens', type: 'long' }
        { name: 'InputCost', type: 'real' }
        { name: 'OutputCost', type: 'real' }
        { name: 'CacheReadCost', type: 'real' }
        { name: 'CacheWrite5mCost', type: 'real' }
        { name: 'CacheWrite1hCost', type: 'real' }
        { name: 'TrueCostUsd', type: 'real' }
        { name: 'VisibleCostUsd', type: 'real' }
      ]
    }
  }
}

// kind: 'Direct' is what makes this reachable from the Logs Ingestion API without a
// data collection endpoint of its own.
//
// NAME LENGTH MATTERS HERE and nowhere else. A Direct DCR is capped at 30 characters and
// restricted to letters, numbers and '-' — ordinary DCRs are not. `dcr-claude-pricing-`
// plus a 13-character uniqueString is 32, and the deployment fails with a BadArgument
// that names the rule rather than the length. Keep the prefix at 17 characters or fewer.
//
// Both streams share one DCR: same endpoint, same immutable id, same publisher role
// assignment below. The name says "price" for history; it carries the cost rollup too.
resource pricingDcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-claudeprice-${resourceSuffix}'
  location: location
  kind: 'Direct'
  properties: {
    streamDeclarations: {
      'Custom-Json-PRICING_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'Model', type: 'string' }
          { name: 'InputTokensPrice', type: 'real' }
          { name: 'OutputTokensPrice', type: 'real' }
        ]
      }
      'Custom-Json-CLAUDECOSTROLLUP_CL': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'BinStart', type: 'datetime' }
          { name: 'Model', type: 'string' }
          { name: 'ResourceName', type: 'string' }
          { name: 'InputTokens', type: 'long' }
          { name: 'OutputTokens', type: 'long' }
          { name: 'CacheReadTokens', type: 'long' }
          { name: 'CacheWrite5mTokens', type: 'long' }
          { name: 'CacheWrite1hTokens', type: 'long' }
          { name: 'InputCost', type: 'real' }
          { name: 'OutputCost', type: 'real' }
          { name: 'CacheReadCost', type: 'real' }
          { name: 'CacheWrite5mCost', type: 'real' }
          { name: 'CacheWrite1hCost', type: 'real' }
          { name: 'TrueCostUsd', type: 'real' }
          { name: 'VisibleCostUsd', type: 'real' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspace.id
          name: workspaceName
        }
      ]
    }
    dataFlows: [
      {
        streams: [ 'Custom-Json-PRICING_CL' ]
        destinations: [ workspaceName ]
        transformKql: 'source'
        outputStream: 'Custom-PRICING_CL'
      }
      {
        streams: [ 'Custom-Json-CLAUDECOSTROLLUP_CL' ]
        destinations: [ workspaceName ]
        transformKql: 'source'
        outputStream: 'Custom-ClaudeCostRollup_CL'
      }
    ]
  }
  dependsOn: [ pricingTable, costRollupTable ]
}

// Monitoring Metrics Publisher. Counter-intuitive name for a logs role, but it is the
// one the Logs Ingestion API checks on a DCR.
var monitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'

resource pricingDcrRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: pricingDcr
  name: guid(pricingDcr.id, pricingPublisherPrincipalId, monitoringMetricsPublisher)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisher)
    principalId: pricingPublisherPrincipalId
    principalType: pricingPublisherPrincipalType
  }
}

output pricingDcrEndpoint string = pricingDcr.properties.endpoints.logsIngestion
output pricingDcrImmutableId string = pricingDcr.properties.immutableId
output pricingDcrStream string = pricingDcr.properties.dataFlows[0].streams[0]
output costRollupStream string = pricingDcr.properties.dataFlows[1].streams[0]
output tiersFunctionAlias string = 'ClaudeTiers'
