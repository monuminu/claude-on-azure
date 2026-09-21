def guid: type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
def positive: type == "number" and . > 0 and floor == .;
def uniqueBy(f): (map(f) | length) == (map(f) | unique | length);
def supportedModels: ["claude-sonnet-5", "claude-haiku-4-5", "claude-opus-5"];
(. + {foundryResourceGroup: (.foundryResourceGroup // .resourceGroup)}) as $config |
$config |
if ([.subscriptionId, .tenantId, .gatewayAudience] | all(.[]; guid)) and
  ((.pricingPublisherPrincipalId // "") == "" or (.pricingPublisherPrincipalId | guid)) and
  ((.budgetApiAudience == "") or (.budgetApiAudience | guid)) and
  ([.resourceGroup, .foundryResourceGroup, .apimName, .foundryAccountName, .publisherEmail, .publisherName, .apimLocation,
    .budgetLocation, .cosmosLocation, .workspaceLocation, .workbookLocation, .pythonExecutable,
    .onboardingOutput] | all(.[]; type == "string" and length > 0 and (test("[<>\r\n]") | not))) and
  ([.models.opus, .models.sonnet, .models.haiku] | all(.[]; type == "string" and (test("[<>\r\n]") | not))) and
  (.namePrefix | test("^[a-z0-9]{3,11}$")) and
  (.workspaceResourceId | test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.OperationalInsights/workspaces/[^/]+$"; "i")) and
  ((.workspaceResourceId | split("/")[2] | ascii_downcase) == (.subscriptionId | ascii_downcase)) and
  (.apimLocation == .budgetLocation) and (.gatewayAudience != .budgetApiAudience) and
  (.tokenResource | test("^(api://|https://)[A-Za-z0-9./:_-]+$")) and
  ((.pricingPublisherPrincipalType // "") == "" or .pricingPublisherPrincipalType == "User" or .pricingPublisherPrincipalType == "ServicePrincipal") and
  (.redisSku == "Standard" or .redisSku == "Premium") and (.redisCapacity | positive) and
  (.storageGovernanceTags | type == "object") and
  (.tiersConfig | type == "array" and length == 3 and (map(.name) | sort == ["basic", "lite", "pro"]) and
    all(.[]; (.tpm | positive) and (.tokenQuota | positive) and (.costQuota | positive))) and
  (.retentionTimeoutSeconds | positive) and (.reconcileHours | positive and . <= 2232) and
  ([.options.registerProviders, .options.checkEp1Quota, .options.pricesReviewed, .options.workbook,
    .options.summaryRule, .options.grafana, .options.reconcile, .options.smokeTest] | all(.[]; type == "boolean")) and
  (if .options.grafana then (.grafanaName | type == "string" and length > 0) and
    (.grafanaLocation | type == "string" and length > 0) and (.grafanaAdminPrincipalId | guid) else true end) and
  (if .teamGovernance == null then true else
    (.teamGovernance.mode as $mode | ($mode == "off" or $mode == "observe" or $mode == "enforce")) and
    ((.teamGovernance.actionGroupIds // []) | type == "array" and uniqueBy(.) and
      all(.[]; type == "string" and test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Insights/actionGroups/[^/]+$"; "i"))) and
    (.teamGovernance.profiles | type == "array" and length > 0 and
      uniqueBy(.name) and uniqueBy(.roleValue) and
      all(.[]; (.name | type == "string" and test("^[a-z0-9-]{2,30}$")) and
        (.roleValue | type == "string" and test("^Claude\\.TeamProfile\\.[A-Za-z0-9]+$")) and
        (.tpm | positive) and (.tokenQuota | positive) and (.costQuota | positive))) and
    (.teamGovernance.teams | type == "array" and length > 0 and
      uniqueBy(.id) and uniqueBy(.groupDisplayName) and uniqueBy(.teamRoleValue) and
      ([.[] | .members[]?] as $allMembers | ($allMembers | length) == ($allMembers | unique | length)) and
      all(.[]; (.id | type == "string" and test("^[a-z0-9-]{3,50}$")) and
        (.displayName | type == "string" and length > 0 and (test("[<>\r\n]") | not)) and
        (.groupDisplayName | type == "string" and length > 0 and (test("[<>\r\n]") | not)) and
        (.teamRoleValue | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{2,119}$")) and
        (.profile as $p | ($config.teamGovernance.profiles | map(.name) | index($p)) != null) and
        (.defaultUserTier as $t | ($config.tiersConfig | map(.name) | index($t)) != null) and
        ((.allowedModels == null) or (.allowedModels | type == "array" and length > 0 and uniqueBy(.) and
          all(.[]; type == "string" and . as $model | (supportedModels | index($model)) != null))) and
        (.members | type == "array" and length > 0 and
          all(.[]; type == "string" and length > 0 and test("^[^<>\r\n]+@[^<>\r\n]+$")))))
  end)
then $config else error("Invalid admin config. Replace placeholders, use GUIDs/full workspace ID in the same subscription, matching APIM/budget regions, and exactly pro/basic/lite tiers. teamGovernance, if present, requires mode off/observe/enforce, unique optional Azure Monitor action-group resource IDs, unique profile/team identifiers, valid profile/tier references, non-overlapping direct members, and a non-empty unique allowedModels subset when specified. See admin/README.md.") end