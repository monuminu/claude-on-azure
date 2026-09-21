// Team governance: APIM named values, a saved KQL function for reporting, a dedicated
// workbook, and optional alerts. This module owns ONE thing — the control-plane facts a
// policy and a set of reports need to reason about teams — and deliberately does not
// touch APIM itself, Redis, Cosmos, the two Function Apps, or any Entra object. Those
// stay owned by 04-apim-gateway.bicep, 16-budget-platform.bicep and
// admin/configure-claude-teams.sh/.ps1 respectively. See infra/README.md for the
// ownership split this module was designed around.
//
// STATUS: DEPLOYED 2026-09-17. The resources and dependent APIM policy compiled and
// deployed successfully against the live gateway. Authenticated team-attribution
// telemetry still requires a caller token carrying one team and one profile app role.
//
// DEPLOYMENT ORDER MATTERS. 03-apim-claude-policy.xml references
// {{team-governance-mode}} and friends unconditionally. Named value substitution is
// resolved at APIM policy deployment time, not at request time, so deploying
// 04-apim-gateway.bicep's updated policy BEFORE this module exists fails the
// deployment outright with an undefined named value. Deploy this module first — even
// with teamGovernanceMode 'off' and empty profiles/teams — every time. Both
// admin/claude-gateway-setup.sh and .ps1 enforce this ordering; do not reorder it
// manually.
//
//   az deployment group create -g <rg> -f infra/22-team-governance.bicep \
//      -p apimName=<existing-apim> logAnalyticsWorkspaceId=<workspace-resource-id> \
//         logAnalyticsWorkspaceName=<workspace-name> teamGovernanceMode=off
//
// WHY A SINGLE JSON NAMED VALUE FOR TEAM/PROFILE LOOKUP, AND SEPARATE NAMED VALUES FOR
// THE NUMBERS. llm-token-limit's tokens-per-minute attribute does not accept a policy
// expression — it must be a literal or a named value, resolved by textual substitution
// before the expression compiler ever runs (see 03-apim-claude-policy.xml and
// 04-apim-gateway.bicep, which hit the identical constraint for per-tier limits). A
// team's PROFILE (and therefore its tpm/tokenQuota/costQuota) cannot be looked up
// dynamically at that attribute, so this module emits one named value per profile name,
// exactly like the existing tier-*-tpm / tier-*-token-quota pattern. Team-to-profile and
// role-to-id MAPPING, by contrast, is read inside a policy EXPRESSION (counter-key,
// token-quota and the budget cache key all accept expressions), so that lookup is a
// single parsed JSON blob instead of one named value per team.
//
// KNOWN LIMITATION, DOCUMENTED RATHER THAN HIDDEN: the policy's per-minute team token
// branch is written for the profile names shipped in admin/setup.example.json ('power',
// 'regular') plus a conservative fallback branch for anything else. Adding a
// differently-named profile still gets correct dollar and monthly-token enforcement
// (both are expression-driven), but needs a new <when> branch in
// 03-apim-claude-policy.xml before its tokens-per-minute ceiling is anything other than
// the fallback. This mirrors the tier convention (exactly pro/basic/lite, hardcoded)
// rather than inventing a new limitation.

@description('Name of the EXISTING APIM instance created by 04-apim-gateway.bicep. This module reads its resource ID to scope named values; it does not modify the service resource itself.')
param apimName string

@description('Resource ID of the Log Analytics workspace already receiving GatewayLlmLogs/GatewayLogs and the structured usage-processor events. Same workspace as 04, 09, 10 and 14.')
param logAnalyticsWorkspaceId string

@description('Name (not resource ID) of that same Log Analytics workspace. Needed because the saved-search resource type is nested under the workspace by name, not by resource ID.')
param logAnalyticsWorkspaceName string

@description('Azure region for the workbook resource. Usually the workspace region.')
param workbookLocation string = resourceGroup().location

@description('Governance enforcement mode. off: the policy skips all team behaviour and every team/profile header reads "disabled". observe: team identity is resolved and stamped, denials are NOT enforced, and ambiguous/missing identity is logged for reconciliation. enforce: zero or multiple team/profile roles produce an attributable 403, and both the team dollar budget and the team token ceiling are enforced. Promote off -> observe -> enforce deliberately; never straight to enforce. See TIERED-QUOTAS.md.')
@allowed([ 'off', 'observe', 'enforce' ])
param teamGovernanceMode string = 'off'

@description('Team budget profiles. roleValue is the Entra app role value assigned alongside a team role (see admin/configure-claude-teams.sh) — a caller must carry exactly one profile role for a request to resolve as "ok". Must match admin/setup.example.json teamGovernance.profiles exactly, and stay in sync with what 16-budget-platform.bicep serializes into CLAUDE_TEAM_GOVERNANCE for the two Functions.')
param profiles array = [
  { name: 'power',   roleValue: 'Claude.TeamProfile.Power',   tpm: 500000, tokenQuota: 700000000, costQuota: 2500 }
  { name: 'regular', roleValue: 'Claude.TeamProfile.Regular', tpm: 100000, tokenQuota: 175000000, costQuota: 1000 }
]

@description('Teams. teamRoleValue is the Entra app role value that identifies membership; profile must name one entry in the profiles array; defaultUserTier must name one of the pro/basic/lite tiers from 04/14/16. members is accepted for parity with admin/setup.example.json but is NOT used by this module — it exists purely so the whole teamGovernance config object can be passed here unmodified.')
param teams array = [
  {
    id: 'fdpo-team-1'
    displayName: 'FDPO Team 1'
    groupDisplayName: 'Claude Team - FDPO Team 1'
    teamRoleValue: 'Claude.Team.FDPO1'
    profile: 'power'
    defaultUserTier: 'pro'
    allowedModels: [ 'claude-sonnet-5', 'claude-haiku-4-5', 'claude-opus-5' ]
    members: []
  }
  {
    id: 'fdpo-team-2'
    displayName: 'FDPO Team 2'
    groupDisplayName: 'Claude Team - FDPO Team 2'
    teamRoleValue: 'Claude.Team.FDPO2'
    profile: 'regular'
    defaultUserTier: 'basic'
    allowedModels: [ 'claude-sonnet-5', 'claude-haiku-4-5' ]
    members: []
  }
]

@description('Resource IDs of existing Azure Monitor action groups. Empty (the default) deploys the workbook and named values but NO alert rules — the workbook still works standalone, alerts are additive. Creating action groups is out of scope for this module; point at ones your team already owns.')
param actionGroupIds array = []

@description('Tags applied to the workbook and alert rules, for the same governance-automation reasons documented in 16-budget-platform.bicep.')
param tags object = {}

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

// ---------------------------------------------------------------------------
// Named values the policy reads directly.
// ---------------------------------------------------------------------------

resource modeNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'team-governance-mode'
  properties: {
    displayName: 'team-governance-mode'
    value: teamGovernanceMode
    secret: false
  }
}

// One base64-encoded JSON blob rather than one named value per team/profile mapping.
// Encoding prevents raw JSON quotes from breaking the APIM C# expression after named
// value substitution. Role-value ->
// {id, profile, profileRoleValue, defaultUserTier, allowedModels} lookups happen inside a policy
// EXPRESSION (JObject.Parse), which — unlike tokens-per-minute — is allowed to be
// dynamic. Keeping this as a single named value also means adding or renaming a team
// never touches 03-apim-claude-policy.xml.
var supportedModels = [ 'claude-sonnet-5', 'claude-haiku-4-5', 'claude-opus-5' ]

var teamRows = [for t in teams: {
  teamRoleValue: t.teamRoleValue
  id: t.id
  profile: t.profile
  profileRoleValue: first(filter(profiles, p => p.name == t.profile)).roleValue
  defaultUserTier: t.defaultUserTier
  allowedModels: t.?allowedModels ?? supportedModels
}]

var teamsJson = '{${join(map(teamRows, r => '"${r.teamRoleValue}":{"id":"${r.id}","profile":"${r.profile}","profileRoleValue":"${r.profileRoleValue}","defaultUserTier":"${r.defaultUserTier}","allowedModels":${string(r.allowedModels)}}'), ',')}}'

var profileRows = [for p in profiles: {
  roleValue: p.roleValue
  name: p.name
  tpm: p.tpm
  tokenQuota: p.tokenQuota
  costQuota: p.costQuota
}]

var profilesJson = '{${join(map(profileRows, r => '"${r.roleValue}":{"name":"${r.name}","tpm":${r.tpm},"tokenQuota":${r.tokenQuota},"costQuota":${r.costQuota}}'), ',')}}'

resource teamsJsonNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'team-governance-teams-json'
  properties: {
    displayName: 'team-governance-teams-json'
    value: base64(teamsJson)
    secret: false
  }
}

resource profilesJsonNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'team-governance-profiles-json'
  properties: {
    displayName: 'team-governance-profiles-json'
    value: base64(profilesJson)
    secret: false
  }
}

// Per-profile numeric limits, as named values — the ONE thing that must be a literal
// because tokens-per-minute does not accept an expression. See the module header.
resource profileTpmNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [for p in profiles: {
  parent: apim
  name: 'team-profile-${p.name}-tpm'
  properties: {
    displayName: 'team-profile-${p.name}-tpm'
    value: string(p.tpm)
    secret: false
  }
}]

resource profileQuotaNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [for p in profiles: {
  parent: apim
  name: 'team-profile-${p.name}-token-quota'
  properties: {
    displayName: 'team-profile-${p.name}-token-quota'
    value: string(p.tokenQuota)
    secret: false
  }
}]

resource profileCostQuotaNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = [for p in profiles: {
  parent: apim
  name: 'team-profile-${p.name}-cost-quota'
  properties: {
    displayName: 'team-profile-${p.name}-cost-quota'
    value: string(p.costQuota)
    secret: false
  }
}]

// Conservative fallback for a profile name the policy's hardcoded branches do not
// recognise yet. Sized at the minimum of the configured profiles so an unrecognised
// profile is UNDER-limited rather than over-limited while someone notices and patches
// the policy — a silent no-op ceiling would be the wrong direction to fail in.
var fallbackTpm = empty(profiles) ? 4000 : min(map(profiles, p => p.tpm))
var fallbackTokenQuota = empty(profiles) ? 35000000 : min(map(profiles, p => p.tokenQuota))

resource profileDefaultTpmNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'team-profile-default-tpm'
  properties: {
    displayName: 'team-profile-default-tpm'
    value: string(fallbackTpm)
    secret: false
  }
}

resource profileDefaultQuotaNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'team-profile-default-token-quota'
  properties: {
    displayName: 'team-profile-default-token-quota'
    value: string(fallbackTokenQuota)
    secret: false
  }
}

// ---------------------------------------------------------------------------
// ClaudeTeams() — a saved KQL function, for REPORTS ONLY. The workbook and any ad hoc
// query join to this for team display names, profiles and quotas. Nothing in the
// enforcement path reads it: APIM cannot query Log Analytics from the request path, and
// the policy/processor both get their numbers from named values / CLAUDE_TEAM_GOVERNANCE
// instead. Keeping two copies of the same numbers (here and in the named values / app
// setting) is unavoidable given that split, and is the same shape as ClaudeTiers() in
// 14-claude-tiers.bicep versus the tier-*-tpm named values in 04.
// ---------------------------------------------------------------------------

var teamFunctionRows = [for t in teams: {
  id: t.id
  displayName: t.displayName
  profile: t.profile
  defaultUserTier: t.defaultUserTier
  tpm: first(filter(profiles, p => p.name == t.profile)).tpm
  tokenQuota: first(filter(profiles, p => p.name == t.profile)).tokenQuota
  costQuota: first(filter(profiles, p => p.name == t.profile)).costQuota
}]

var teamFunctionBody = empty(teams)
  ? 'datatable(TeamId:string, TeamDisplayName:string, Profile:string, DefaultUserTier:string, Tpm:long, TokenQuota:long, CostQuota:long) []'
  : 'datatable(TeamId:string, TeamDisplayName:string, Profile:string, DefaultUserTier:string, Tpm:long, TokenQuota:long, CostQuota:long)\n[\n${join(map(teamFunctionRows, r => '  "${r.id}", "${r.displayName}", "${r.profile}", "${r.defaultUserTier}", ${r.tpm}, ${r.tokenQuota}, ${r.costQuota}'), ',\n')}\n]'

resource claudeTeamsFunction 'Microsoft.OperationalInsights/workspaces/savedSearches@2023-09-01' = {
  parent: workspace
  name: 'ClaudeTeams'
  properties: {
    category: 'Claude'
    displayName: 'ClaudeTeams()'
    query: teamFunctionBody
    functionAlias: 'ClaudeTeams'
    functionParameters: ''
    version: 2
    tags: [
      { name: 'Preview', value: 'False' }
    ]
  }
}

// ---------------------------------------------------------------------------
// Workbook
// ---------------------------------------------------------------------------

var teamWorkbookJson = replace(
  loadTextContent('./23-team-governance-workbook.json'),
  '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/PLACEHOLDER/providers/Microsoft.OperationalInsights/workspaces/PLACEHOLDER',
  logAnalyticsWorkspaceId
)

resource teamGovernanceWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, logAnalyticsWorkspaceId, 'claude-team-governance-workbook')
  location: workbookLocation
  kind: 'shared'
  tags: tags
  properties: {
    displayName: 'Claude team governance'
    category: 'workbook'
    version: 'Notebook/1.0'
    sourceId: logAnalyticsWorkspaceId
    serializedData: teamWorkbookJson
  }
}

// ---------------------------------------------------------------------------
// Optional alerts. Created only when actionGroupIds is non-empty; the workbook and
// named values above are fully usable without them. All five read from the SAME
// workspace that already receives GatewayLlmLogs/GatewayLogs — the workspace-based
// Application Insights resource in 16-budget-platform.bicep writes AppTraces /
// AppExceptions into it, which is where the two Functions' structured events land.
// Stable API version (2021-08-01, LogAlert v2), not preview.
// ---------------------------------------------------------------------------

var alertsEnabled = !empty(actionGroupIds)

resource alertBudgetFailOpen 'Microsoft.Insights/scheduledQueryRules@2021-08-01' = if (alertsEnabled) {
  name: guid(resourceGroup().id, logAnalyticsWorkspaceId, 'claude-team-alert-fail-open')
  location: workbookLocation
  tags: tags
  properties: {
    displayName: 'Claude budget API fail-open exceptions'
    description: 'The budget API could not reach Redis and returned "within budget" by design (fail-open). Sustained occurrences mean budgets are silently unenforced. See snippets/18-budget-api/function_app.py.'
    severity: 2
    enabled: true
    scopes: [ workspace.id ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: 'AppExceptions\n| where OperationName has "budget" or Message has "redis unavailable"\n| where Message has "redis unavailable, allowing request"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 5
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: actionGroupIds
    }
  }
}

resource alertAmbiguousIdentity 'Microsoft.Insights/scheduledQueryRules@2021-08-01' = if (alertsEnabled) {
  name: guid(resourceGroup().id, logAnalyticsWorkspaceId, 'claude-team-alert-ambiguous-identity')
  location: workbookLocation
  tags: tags
  properties: {
    displayName: 'Claude ambiguous or missing team identity'
    description: 'The usage processor observed a caller with zero or multiple team/profile roles while team governance is enabled. In enforce mode these are already denied at the gateway; in observe mode they are the population to reconcile before promoting.'
    severity: 3
    enabled: true
    scopes: [ workspace.id ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    criteria: {
      allOf: [
        {
          query: 'AppTraces\n| where Message startswith "TEAM_GOVERNANCE_EVENT"\n| extend Evt = parse_json(substring(Message, strlen("TEAM_GOVERNANCE_EVENT ")))\n| where tostring(Evt.type) == "ambiguous_identity"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 10
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: actionGroupIds
    }
  }
}

resource alertProcessorLag 'Microsoft.Insights/scheduledQueryRules@2021-08-01' = if (alertsEnabled) {
  name: guid(resourceGroup().id, logAnalyticsWorkspaceId, 'claude-team-alert-processor-lag')
  location: workbookLocation
  tags: tags
  properties: {
    displayName: 'Claude usage processor lag'
    description: 'Average delay between an Event Hub record being enqueued and the usage processor handling it. Sustained lag means Redis/Cosmos counters (and therefore budget enforcement) are stale.'
    severity: 3
    enabled: true
    scopes: [ workspace.id ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT30M'
    criteria: {
      allOf: [
        {
          query: 'AppTraces\n| where Message startswith "TEAM_GOVERNANCE_EVENT"\n| extend Evt = parse_json(substring(Message, strlen("TEAM_GOVERNANCE_EVENT ")))\n| where tostring(Evt.type) == "processor_lag"\n| extend LagSeconds = todouble(Evt.lagSeconds)\n| summarize AvgLagSeconds = avg(LagSeconds)'
          timeAggregation: 'Average'
          operator: 'GreaterThan'
          threshold: 60
          failingPeriods: {
            numberOfEvaluationPeriods: 2
            minFailingPeriodsToAlert: 2
          }
        }
      ]
    }
    actions: {
      actionGroups: actionGroupIds
    }
  }
}

resource alertMissingPrices 'Microsoft.Insights/scheduledQueryRules@2021-08-01' = if (alertsEnabled) {
  name: guid(resourceGroup().id, logAnalyticsWorkspaceId, 'claude-team-alert-missing-prices')
  location: workbookLocation
  tags: tags
  properties: {
    displayName: 'Claude usage processor missing prices'
    description: 'The usage processor priced a request at $0 because no rate was loaded for its model. Budgets and reports are under-counting for that model until 15-load-pricing.py is rerun. See CACHE-TOKEN-ANALYSIS.md.'
    severity: 2
    enabled: true
    scopes: [ workspace.id ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    criteria: {
      allOf: [
        {
          query: 'AppTraces\n| where Message has "no price for model"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 5
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: actionGroupIds
    }
  }
}

resource alertUtilizationThresholds 'Microsoft.Insights/scheduledQueryRules@2021-08-01' = if (alertsEnabled) {
  name: guid(resourceGroup().id, logAnalyticsWorkspaceId, 'claude-team-alert-utilization')
  location: workbookLocation
  tags: tags
  properties: {
    displayName: 'Claude user/team budget utilization crossing'
    description: 'The usage processor emitted a 70/85/95/100 percent monthly-budget threshold-crossing event, deduplicated per scope/month/threshold in Redis so this does not need a high-cardinality Azure Monitor metric. See snippets/17-usage-processor/function_app.py.'
    severity: 3
    enabled: true
    scopes: [ workspace.id ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: 'AppTraces\n| where Message startswith "TEAM_GOVERNANCE_EVENT"\n| extend Evt = parse_json(substring(Message, strlen("TEAM_GOVERNANCE_EVENT ")))\n| where tostring(Evt.type) == "threshold_crossed"\n| extend Threshold = toint(Evt.threshold)\n| where Threshold >= 95'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: actionGroupIds
    }
  }
}

output teamGovernanceModeNamedValue string = modeNv.name
output teamsJsonNamedValue string = teamsJsonNv.name
output profilesJsonNamedValue string = profilesJsonNv.name
output workbookId string = teamGovernanceWorkbook.id
output claudeTeamsFunctionName string = claudeTeamsFunction.name
output alertsCreated bool = alertsEnabled
