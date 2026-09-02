// Log Analytics summary rule: hourly Claude usage rollup, for history beyond raw retention.
//
// WHY: a PerGB2018 workspace retains 30 days by default, and raising retention on the raw
// request tables is billed per row. This rolls each hour of gateway traffic into a handful
// of rows - one per user, per model, per client - which is roughly 0.01% of source volume
// and cheap to keep for a year. That is what makes month-over-month reporting possible.
//
//   az deployment group create -g <rg> -f 10-claude-usage-summary-rule.bicep \
//      -p workspaceName=<log analytics workspace name>
//
// PREREQUISITE: the gateway policy must already stamp x-caller-oid / x-caller-upn and the
// API diagnostic must log them (03-apim-claude-policy.xml, 04-apim-gateway.bicep).
// Without those the aggregate is real but every row says "anonymous".
//
// RETENTION IS A SEPARATE STEP, and the obvious command for it fails.
// The destination table is created by the first bin, not by this deployment, so its
// retention cannot be set here. It then defaults to workspace retention - 30 days -
// which defeats the entire point of aggregating.
//
// Do NOT use `az monitor log-analytics workspace table update`: it sends a full PUT
// including the schema, and the summary-rule columns (_BinSize, _BinStartTime,
// _RuleName, _RuleLastModifiedTime) fail its own validation with
// "MSG 1008: Column name _BinSize contains invalid characters".
//
// PATCH only the retention properties instead:
//
//   az rest --method patch --headers "Content-Type=application/json" \
//     --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>\
// /providers/Microsoft.OperationalInsights/workspaces/<ws>/tables/ClaudeUsageHourly_CL\
// ?api-version=2022-10-01" \
//     --body '{"properties":{"retentionInDays":30,"totalRetentionInDays":400}}'
//
// That yields 30 days interactive + 370 days archive. Archive is far cheaper per GB,
// and these rows are tiny, so a year of history costs very little.

@description('Name of the Log Analytics workspace holding GatewayLlmLogs and GatewayLogs.')
param workspaceName string

@description('Aggregation interval in minutes. Allowed: 20, 30, 60, 120, 180, 360, 720, 1440.')
@allowed([ 20, 30, 60, 120, 180, 360, 720, 1440 ])
param binSize int = 60

@description('Destination custom log table. Must end with _CL.')
param destinationTable string = 'ClaudeUsageHourly_CL'

resource workspace 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
}

// NOTE ON THE QUERY, because three rules here are easy to violate:
//   1. NO time filter. The bin defines the range; adding a filter intersects with it and
//      you silently aggregate only the overlap.
//   2. NO TimeGenerated in the output. Reserved column names get an _Original suffix
//      appended. The bin timestamp arrives automatically as _BinStartTime.
//   3. NO pivot / bag_unpack / user-defined functions - unsupported in summary rules.
//      The output must be long, not wide.
// Also note percentile() over an int column returns an int, so coalescing it against a
// 0.0 literal fails with SEM0525 "case: return types are not compatible". Hence todouble().

resource summaryRule 'Microsoft.OperationalInsights/workspaces/summaryLogs@2025-07-01' = {
  parent: workspace
  name: 'claude-usage-hourly'
  properties: {
    ruleType: 'User'
    displayName: 'Claude usage - hourly rollup'
    description: 'Per-user, per-model, per-client Claude usage through the API Management gateway.'
    ruleDefinition: {
      binSize: binSize
      // BCP073: Bicep's type definition marks destinationTable read-only. The ARM API
      // requires it on create - verified by deployment. Another type-lag artefact.
      #disable-next-line BCP073
      destinationTable: destinationTable
      query: '''
let gwBase = ApiManagementGatewayLogs
    | where Url has "/anthropic"
    | extend OidReq  = tostring(BackendRequestHeaders["x-caller-oid"]),
             OidResp = tostring(ResponseHeaders["x-caller-oid"]),
             RawUpn  = tostring(BackendRequestHeaders["x-caller-upn"]),
             UA      = tostring(RequestHeaders["User-Agent"])
    | extend Oid = iff(isempty(OidReq), OidResp, OidReq)
    | extend Client = case(UA has "claude-cli", "Claude Code",
                           UA has "Electron" and UA has "Claude/", "Claude Desktop",
                           UA startswith "Bun/", "Claude Desktop",
                           isempty(UA), "Unknown",
                           "Other");
let ids = gwBase | where isnotempty(RawUpn) | summarize arg_max(TimeGenerated, RawUpn) by Oid | project Oid, KnownUpn = RawUpn;
let gw = gwBase
    | join kind=leftouter ids on Oid
    | extend User = case(isnotempty(RawUpn), RawUpn, isnotempty(KnownUpn), KnownUpn, isnotempty(Oid), Oid, "anonymous")
    | project CorrelationId, ResponseCode, BackendTime, User, Oid, Client;
ApiManagementGatewayLlmLog
| extend Model = iff(isempty(ModelName), "none", replace_regex(ModelName, @"-\d{8}$", ""))
| join kind=inner (gw) on CorrelationId
| summarize Requests         = count(),
            Prompt           = sum(PromptTokens),
            Completion       = sum(CompletionTokens),
            Tokens           = sum(TotalTokens),
            Throttled        = countif(ResponseCode in (429, 403)),
            Errors           = countif(ResponseCode >= 400 and ResponseCode !in (429, 403)),
            StreamedRequests = countif(IsStreamCompletion == 1),
            BackendMsP95Raw  = percentile(BackendTime, 95)
  by Oid, User, Client, Model
| extend BackendMsP95 = toint(coalesce(todouble(BackendMsP95Raw), 0.0))
| project-away BackendMsP95Raw
'''
    }
  }
}

output ruleId string = summaryRule.id
output destinationTable string = destinationTable
