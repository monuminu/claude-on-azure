def guid: type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
def positive: type == "number" and . > 0 and floor == .;
. as $config |
if ([.subscriptionId, .tenantId, .gatewayAudience, .budgetApiAudience, .pricingPublisherPrincipalId] | all(.[]; guid)) and
  ([.resourceGroup, .apimName, .foundryAccountName, .publisherEmail, .publisherName, .apimLocation,
    .budgetLocation, .cosmosLocation, .workspaceLocation, .workbookLocation, .pythonExecutable,
    .onboardingOutput] | all(.[]; type == "string" and length > 0 and (test("[<>\r\n]") | not))) and
  ([.models.opus, .models.sonnet, .models.haiku] | all(.[]; type == "string" and (test("[<>\r\n]") | not))) and
  (.namePrefix | test("^[a-z0-9]{3,11}$")) and
  (.workspaceResourceId | test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.OperationalInsights/workspaces/[^/]+$"; "i")) and
  ((.workspaceResourceId | split("/")[2] | ascii_downcase) == (.subscriptionId | ascii_downcase)) and
  (.apimLocation == .budgetLocation) and (.gatewayAudience != .budgetApiAudience) and
  (.tokenResource | test("^(api://|https://)[A-Za-z0-9./:_-]+$")) and
  (.pricingPublisherPrincipalType == "User" or .pricingPublisherPrincipalType == "ServicePrincipal") and
  (.redisSku == "Standard" or .redisSku == "Premium") and (.redisCapacity | positive) and
  (.storageGovernanceTags | type == "object") and
  (.tiersConfig | type == "array" and length == 3 and (map(.name) | sort == ["basic", "lite", "pro"]) and
    all(.[]; (.tpm | positive) and (.tokenQuota | positive) and (.costQuota | positive))) and
  (.retentionTimeoutSeconds | positive) and (.reconcileHours | positive and . <= 2232) and
  ([.options.registerProviders, .options.checkEp1Quota, .options.pricesReviewed, .options.workbook,
    .options.summaryRule, .options.grafana, .options.reconcile, .options.smokeTest] | all(.[]; type == "boolean")) and
  (if .options.grafana then (.grafanaName | type == "string" and length > 0) and
    (.grafanaLocation | type == "string" and length > 0) and (.grafanaAdminPrincipalId | guid) else true end)
then $config else error("Invalid admin config. Replace placeholders, use GUIDs/full workspace ID in the same subscription, matching APIM/budget regions, and exactly pro/basic/lite tiers. See admin/README.md.") end