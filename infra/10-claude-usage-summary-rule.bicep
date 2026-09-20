// Log Analytics summary rule: hourly Claude usage rollup, for history beyond raw retention.
//
// WHY: a PerGB2018 workspace retains 30 days by default, and raising retention on the raw
// request tables is billed per row. This rolls each hour of gateway traffic into a handful
// of rows - one per user, per model, per client - which is roughly 0.01% of source volume
// and cheap to keep for a year. That is what makes month-over-month reporting possible.
//
//   az deployment group create -g <rg> -f infra/10-claude-usage-summary-rule.bicep \
//      -p workspaceName=<log analytics workspace name>
//
// PREREQUISITE: the gateway policy must already stamp x-caller-oid / x-caller-upn /
// x-caller-tier and the API diagnostic must log them (03-apim-claude-policy.xml,
// 04-apim-gateway.bicep). Without those the aggregate is real but every row says
// "anonymous", and without the tier header every row says "unknown".
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
//      The output must be long, not wide. That is also why ClaudeTiers() is NOT called
//      here: join the tier limits on at query time, not at rollup time.
// Also note percentile() over an int column returns an int, so coalescing it against a
// 0.0 literal fails with SEM0525 "case: return types are not compatible". Hence todouble().
//
// Tier is grouped BY, and DeniedBudget / DeniedAdmin are counted separately from
// Throttled. Those three numbers answer different questions - "this tier is under-sized",
// "this developer has spent their money", and "an admin stopped this person" are not the
// same operational event, and collapsing them into one Throttled column loses exactly the
// distinction you need at 3am.
// LLM rows without RequestId are probes, not inference. Start the final join from
// GatewayLogs so filtering those LLM rows does not erase 401/403/429 health events.
// LlmStreamFlagTrueRequests records only the unreliable APIM flag. The legacy
// StreamedRequests column must not be interpreted as a count of actual SSE requests.

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
             TierReq = tostring(BackendRequestHeaders["x-caller-tier"]),
             TierResp= tostring(ResponseHeaders["x-caller-tier"]),
             TeamReq = tostring(BackendRequestHeaders["x-caller-team-id"]),
             TeamResp= tostring(ResponseHeaders["x-caller-team-id"]),
             ProfileReq = tostring(BackendRequestHeaders["x-caller-team-profile"]),
             ProfileResp= tostring(ResponseHeaders["x-caller-team-profile"]),
             TeamStateReq = tostring(BackendRequestHeaders["x-team-governance-state"]),
             TeamStateResp= tostring(ResponseHeaders["x-team-governance-state"]),
             DeniedBy= tostring(ResponseHeaders["x-claude-denied-by"]),
             RawUpn  = tostring(BackendRequestHeaders["x-caller-upn"]),
             UA      = tostring(RequestHeaders["User-Agent"])
    | extend Oid = iff(isempty(OidReq), OidResp, OidReq)
    | extend Tier = coalesce(iff(isempty(TierReq), TierResp, TierReq), "unknown")
    | extend TeamId = iff(isempty(TeamReq), TeamResp, TeamReq),
         TeamProfile = iff(isempty(ProfileReq), ProfileResp, ProfileReq),
         TeamState = iff(isempty(TeamStateReq), TeamStateResp, TeamStateReq)
    | extend Client = case(UA has "claude-cli", "Claude Code",
                           UA has "Electron" and UA has "Claude/", "Claude Desktop",
                           UA startswith "Bun/", "Claude Desktop",
                           isempty(UA), "Unknown",
                           "Other");
let ids = gwBase | where isnotempty(RawUpn) | summarize arg_max(TimeGenerated, RawUpn) by Oid | project Oid, KnownUpn = RawUpn;
let gw = gwBase
    | join kind=leftouter ids on Oid
    | extend User = case(isnotempty(RawUpn), RawUpn, isnotempty(KnownUpn), KnownUpn, isnotempty(Oid), Oid, "anonymous")
    | project CorrelationId, ResponseCode, BackendTime, User, Oid, Tier, TeamId, TeamProfile, TeamState, Client, DeniedBy;
let llm = ApiManagementGatewayLlmLog
    | where isnotempty(RequestId);
gw
| join kind=leftouter (llm) on CorrelationId
| where isnotempty(RequestId) or ResponseCode >= 400
| extend Model = iff(isempty(ModelName), "none", replace_regex(ModelName, @"-\d{8}$", ""))
| summarize Requests         = count(),
            InferenceRequests = countif(isnotempty(RequestId)),
            Prompt           = sum(PromptTokens),
            Completion       = sum(CompletionTokens),
            Tokens           = sum(TotalTokens),
            Throttled        = countif(ResponseCode in (429, 403)),
            DeniedBudget     = countif(DeniedBy in ("budget", "user-budget", "team-budget")),
            DeniedAdmin      = countif(DeniedBy == "admin"),
            Errors           = countif(ResponseCode >= 400 and ResponseCode !in (429, 403)),
            LlmStreamFlagTrueRequests = countif(IsStreamCompletion == 1),
            BackendMsP95Raw  = percentile(BackendTime, 95)
  by Oid, User, Client, Model, Tier, TeamId, TeamProfile, TeamState
| extend BackendMsP95 = toint(coalesce(todouble(BackendMsP95Raw), 0.0))
| project-away BackendMsP95Raw
'''
    }
  }
}

output ruleId string = summaryRule.id
output destinationTable string = destinationTable
