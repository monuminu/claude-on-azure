#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH=''
STAGE='all'
DRY_RUN=false
YES=false
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=''
SUBSCRIPTION_ID=''
TENANT_ID=''
RESOURCE_GROUP=''
WORKSPACE_ID=''
WORKSPACE_GROUP=''
WORKSPACE_NAME=''
APIM_NAME=''
FOUNDRY_NAME=''
PYTHON=''
OUTPUT=''
TEMP=''
RESOURCES=''
APIM=''
APIM_CLIENT_ID=''
DESKTOP_CLIENT_ID=''
BUDGET=''
TIERS=''
APPS=''
PROCESSOR_NAME=''
BUDGET_NAME=''
REDIS_NAME=''
ACCOUNT=''
APP=''
MODELS=''
FAMILY=''
MODEL=''
QUOTA=''
IDENTITY=''
PROVIDER=''
PARAMS=()

usage() {
  printf '%s\n' 'Usage: claude-gateway-setup.sh --config FILE [--stage all|preflight|reporting|retention|export] [--dry-run] [--yes]' 'Deployment parameters are declared in admin/setup.example.json. Dry run is offline, not ARM what-if.'
}
value() { jq -er "$1" <<< "$CONFIG"; }
enabled() { [[ $(jq -r ".options.$1" <<< "$CONFIG") == true ]]; }
azure() { az "$@" --subscription "$SUBSCRIPTION_ID" --only-show-errors; }
deploy() {
  local name=$1 group=$2 file=$3 result=''
  shift 3
  printf 'Deploying %s in %s\n' "$name" "$group" >&2
  jq -n --args '$ARGS.positional | map(index("=") as $pos | .[:$pos] as $key | {key: $key, value: {value: (.[($pos+1):] | if (["tiersConfig", "storageGovernanceTags", "redisCapacity", "enableReconciler"] | index($key)) != null then fromjson else . end)}}) | from_entries' "$@" > "$TEMP/$name.parameters.json"
  result=$(azure deployment group create --name "$name" --resource-group "$group" --template-file "$ROOT/$file" --parameters "@$TEMP/$name.parameters.json" -o json)
  jq -e 'if .properties.provisioningState == "Succeeded" then .properties.outputs else error("Deployment did not succeed") end' <<< "$result"
}
gateway_params() {
  PARAMS=("apimName=$APIM_NAME" "apimLocation=$(value .apimLocation)" "foundryAccountName=$FOUNDRY_NAME"
    "publisherEmail=$(value .publisherEmail)" "publisherName=$(value .publisherName)" "entraTenantId=$TENANT_ID"
    "gatewayAudience=$(value .gatewayAudience)" "logAnalyticsWorkspaceId=$WORKSPACE_ID" "tiersConfig=$(jq -c .tiersConfig <<< "$CONFIG")")
}
configure_desktop_client() {
  local name="Claude Desktop - $APIM_NAME" apps='' app='' count=0 scope_id='' permissions='' service_principals='' api_patch=''
  DESKTOP_CLIENT_ID=$(jq -r '.clientConfiguration.clientId // empty' <<< "$CONFIG")
  if [[ -n "$DESKTOP_CLIENT_ID" ]]; then
    app=$(azure ad app show --id "$DESKTOP_CLIENT_ID" -o json)
  else
    apps=$(azure ad app list --display-name "$name" -o json)
    count=$(jq 'length' <<< "$apps")
    [[ "$count" -le 1 ]] || { echo "Multiple Entra applications are named '$name'; set clientConfiguration.clientId explicitly." >&2; exit 1; }
    if [[ "$count" -eq 1 ]]; then
      app=$(jq -c '.[0]' <<< "$apps")
    else
      app=$(azure ad app create --display-name "$name" --sign-in-audience AzureADMyOrg --is-fallback-public-client true \
        --public-client-redirect-uris 'http://127.0.0.1/callback' 'http://localhost' -o json)
    fi
    DESKTOP_CLIENT_ID=$(jq -er .appId <<< "$app")
    CONFIG=$(jq --arg client "$DESKTOP_CLIENT_ID" '.clientConfiguration.clientId = $client' <<< "$CONFIG")
  fi
  jq -e '.signInAudience == "AzureADMyOrg" and .isFallbackPublicClient == true and
    (.publicClient.redirectUris | index("http://localhost") != null) and
    (.publicClient.redirectUris | index("http://127.0.0.1/callback") != null)' <<< "$app" >/dev/null || {
      echo 'Desktop client must be a single-tenant public client with http://localhost and http://127.0.0.1/callback redirects.' >&2
      exit 1
    }
  scope_id=$(jq -er '[.api.oauth2PermissionScopes[] | select(.value == "access_as_user" and .isEnabled)] |
    if length == 1 then .[0].id else error("Gateway API must expose one enabled access_as_user scope") end' <<< "$APP")
  permissions=$(jq -c --arg api "$(value .gatewayAudience)" '.requiredResourceAccess // [] | map(select(.resourceAppId == $api)) | .[0].resourceAccess // []' <<< "$app")
  if ! jq -e --arg scope "$scope_id" 'any(.[]; .id == $scope and .type == "Scope")' <<< "$permissions" >/dev/null; then
    azure ad app permission add --id "$DESKTOP_CLIENT_ID" --api "$(value .gatewayAudience)" --api-permissions "$scope_id=Scope" -o none
  fi
  service_principals=$(azure ad sp list --filter "appId eq '$DESKTOP_CLIENT_ID'" -o json)
  if [[ $(jq 'length' <<< "$service_principals") -eq 0 ]]; then azure ad sp create --id "$DESKTOP_CLIENT_ID" -o none; fi
  api_patch=$(jq -c --arg client "$DESKTOP_CLIENT_ID" --arg scope "$scope_id" '.api.preAuthorizedApplications =
    (((.api.preAuthorizedApplications // []) | map(select(.appId != $client))) + [{appId: $client, delegatedPermissionIds: [$scope]}]) |
    {api: .api}' <<< "$APP")
  azure rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$(jq -er .id <<< "$APP")" \
    --headers Content-Type=application/json --body "$api_patch" -o none
  printf 'Claude Desktop public client: %s\n' "$DESKTOP_CLIENT_ID"
}
export_config() {
  local args=() family='' model='' client='' scopes='' settings=''
  for family in opus sonnet haiku; do
    model=$(jq -r --arg family "$family" '.models[$family]' <<< "$CONFIG")
    [[ -z "$model" ]] || args+=("--$family-model" "$model")
  done
  client=$(jq -r '.clientConfiguration.clientId // empty' <<< "$CONFIG")
  scopes=$(jq -r '.clientConfiguration.scopes // empty' <<< "$CONFIG")
  settings=$(jq -r '.clientConfiguration.settingsFile // empty' <<< "$CONFIG")
  [[ -z "$client" ]] || args+=(--client-id "$client")
  [[ -z "$scopes" ]] || args+=(--scopes "$scopes")
  if [[ -n "$settings" ]]; then
    [[ "$settings" == /* ]] || settings="$ROOT/$settings"
    args+=(--client-settings "$settings")
  fi
  bash "$ROOT/admin/export-claude-client-configuration.sh" --subscription-id "$SUBSCRIPTION_ID" --tenant-id "$TENANT_ID" \
    --resource-group "$RESOURCE_GROUP" --token-resource "$(value .tokenResource)" ${args[@]+"${args[@]}"} --output "$OUTPUT" --force
}
retention() {
  azure resource wait --exists --ids "$WORKSPACE_ID/tables/ClaudeUsageHourly_CL" --api-version 2022-10-01 --interval 60 --timeout "$(value .retentionTimeoutSeconds)"
  printf '%s\n' '{"properties":{"retentionInDays":30,"totalRetentionInDays":400}}' > "$TEMP/retention.json"
  azure rest --method patch --url "https://management.azure.com$WORKSPACE_ID/tables/ClaudeUsageHourly_CL?api-version=2022-10-01" --body "@$TEMP/retention.json" -o none
}
reporting() {
  if enabled workbook; then
    deploy 09-workbook "$RESOURCE_GROUP" infra/09-workbook.bicep "logAnalyticsWorkspaceId=$WORKSPACE_ID" "workbookLocation=$(value .workbookLocation)" >/dev/null
  fi
  if enabled summaryRule; then
    deploy 10-claude-usage-summary-rule "$WORKSPACE_GROUP" infra/10-claude-usage-summary-rule.bicep "workspaceName=$WORKSPACE_NAME" >/dev/null
    retention
  fi
  if enabled grafana; then
    deploy 11-grafana "$RESOURCE_GROUP" infra/11-grafana.bicep "grafanaName=$(value .grafanaName)" "location=$(value .grafanaLocation)" \
      "logAnalyticsWorkspaceId=$WORKSPACE_ID" "adminPrincipalId=$(value .grafanaAdminPrincipalId)" >/dev/null
    azure extension add --name amg --upgrade -o none
    jq --arg workspace "$WORKSPACE_ID" 'walk(if type == "string" then gsub("WORKSPACE_RESOURCE_ID_PLACEHOLDER"; $workspace) else . end)' \
      "$ROOT/infra/12-claude-usage-grafana-dashboard.json" > "$TEMP/dashboard.json"
    azure grafana dashboard create --name "$(value .grafanaName)" --resource-group "$RESOURCE_GROUP" --definition "@$TEMP/dashboard.json" --overwrite true -o none
  fi
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --config|--stage)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      case "$1" in --config) CONFIG_PATH=$2 ;; --stage) STAGE=$2 ;; esac
      shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;; --yes) YES=true; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -n "$CONFIG_PATH" ]] || { usage >&2; exit 2; }
case "$STAGE" in all|preflight|reporting|retention|export) ;; *) usage >&2; exit 2 ;; esac
CONFIG=$(jq -ef "$ROOT/admin/validate-config.jq" "$CONFIG_PATH")
SUBSCRIPTION_ID=$(value .subscriptionId)
TENANT_ID=$(value .tenantId)
RESOURCE_GROUP=$(value .resourceGroup)
WORKSPACE_ID=$(value .workspaceResourceId)
WORKSPACE_GROUP=$(jq -r '.workspaceResourceId | split("/")[4]' <<< "$CONFIG")
WORKSPACE_NAME=${WORKSPACE_ID##*/}
APIM_NAME=$(value .apimName)
FOUNDRY_NAME=$(value .foundryAccountName)
PYTHON=$(value .pythonExecutable)
OUTPUT=$(value .onboardingOutput)
[[ "$OUTPUT" == /* ]] || OUTPUT="$ROOT/$OUTPUT"
printf 'Stage=%s; subscription=%s; resource group=%s; APIM=%s (%s); budget=%s; Cosmos=%s\n' "$STAGE" "$SUBSCRIPTION_ID" "$RESOURCE_GROUP" "$APIM_NAME" "$(value .apimLocation)" "$(value .budgetLocation)" "$(value .cosmosLocation)"
echo 'Order: preflight -> bootstrap APIM only if absent -> tiers/DCR -> authenticated budget platform -> pricing permissions + both price stores -> publish Functions -> final APIM -> onboarding export -> optional smoke/reporting/reconciliation.'
printf 'Options: %s\n' "$(jq -c .options <<< "$CONFIG")"
echo 'StandardV2 APIM, EP1, Redis, Cosmos, Event Hub and optional Grafana incur charges. Budget accounting is asynchronous, fail-open and excludes cache writes.'
if [[ "$DRY_RUN" == true ]]; then echo 'DRY RUN: configuration validated. No writes, installs, logins, Azure calls or inference.'; exit 0; fi
command -v az >/dev/null || { echo 'Install Azure CLI.' >&2; exit 1; }
ACCOUNT=$(azure account show -o json)
[[ $(jq -r .tenantId <<< "$ACCOUNT") == "$TENANT_ID" ]] || { echo 'Wrong Azure tenant; log in to the configured tenant.' >&2; exit 1; }
if [[ "$STAGE" != preflight && "$YES" != true ]]; then echo 'Review --dry-run, then pass --yes to authorize the selected changes.' >&2; exit 2; fi
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
if [[ "$STAGE" == export ]]; then
  APP=$(azure ad app show --id "$(value .gatewayAudience)" -o json)
  configure_desktop_client
  export_config
  exit 0
fi
if [[ "$STAGE" == retention ]]; then retention; exit 0; fi
if [[ "$STAGE" == reporting ]]; then reporting; exit 0; fi
command -v func >/dev/null || { echo 'Install Azure Functions Core Tools v4.' >&2; exit 1; }
command -v "$PYTHON" >/dev/null || { echo 'Set pythonExecutable to a Python environment with the loader dependencies.' >&2; exit 1; }
"$PYTHON" -c 'import azure.identity, azure.monitor.ingestion, requests, redis'
IDENTITY=$("$PYTHON" -c 'import base64,json; from azure.identity import DefaultAzureCredential; token=DefaultAzureCredential().get_token("https://management.azure.com/.default").token.split(".")[1]; claims=json.loads(base64.urlsafe_b64decode(token+"="*(-len(token)%4))); print(json.dumps({"oid":claims["oid"],"tid":claims["tid"]}))')
[[ $(jq -r .oid <<< "$IDENTITY") == "$(value .pricingPublisherPrincipalId)" && $(jq -r .tid <<< "$IDENTITY") == "$TENANT_ID" ]] || { echo 'Python credential identity does not match pricingPublisherPrincipalId/tenantId.' >&2; exit 1; }
azure group show --name "$RESOURCE_GROUP" -o none
azure cognitiveservices account show --name "$FOUNDRY_NAME" --resource-group "$RESOURCE_GROUP" -o none
[[ $(azure resource show --ids "$WORKSPACE_ID" --query location -o tsv) == "$(value .workspaceLocation)" ]] || { echo 'workspaceLocation does not match the existing workspace.' >&2; exit 1; }
MODELS=$(azure cognitiveservices account deployment list --name "$FOUNDRY_NAME" --resource-group "$RESOURCE_GROUP" -o json)
for FAMILY in opus sonnet haiku; do
  MODEL=$(jq -r --arg family "$FAMILY" '.models[$family]' <<< "$CONFIG")
  if [[ -z "$MODEL" ]]; then
    MODEL=$(jq -er --arg family "$FAMILY" '[.[] | select((.properties.model.name // .name) | ascii_downcase | contains($family)) | .name] | if length == 1 then .[0] else error("Set models." + $family + ": no unique deployment") end' <<< "$MODELS")
    CONFIG=$(jq --arg family "$FAMILY" --arg model "$MODEL" '.models[$family] = $model' <<< "$CONFIG")
  fi
done
jq -e --argjson config "$CONFIG" 'map(.name) as $names | [$config.models[]] | all(.[]; . as $model | $names | index($model) != null)' <<< "$MODELS" >/dev/null || { echo 'A configured model is not deployed in Foundry.' >&2; exit 1; }
APP=$(azure ad app show --id "$(value .gatewayAudience)" -o json)
jq -e --arg resource "$(value .tokenResource)" '.api.requestedAccessTokenVersion == 2 and (.identifierUris | index($resource) != null) and any(.appRoles[]; .value == "Claude.User" and .isEnabled)' <<< "$APP" >/dev/null || { echo 'Gateway app needs v2 tokens, the configured identifier URI and an enabled Claude.User role.' >&2; exit 1; }
if [[ "$STAGE" != preflight ]]; then configure_desktop_client; fi
azure ad sp show --id "$(value .budgetApiAudience)" -o none
RESOURCES=$(azure resource list --resource-group "$RESOURCE_GROUP" -o json)
jq -e --arg apim "$APIM_NAME" --arg prefix "$(value .namePrefix)-" --arg location "$(value .apimLocation)" \
  'all(.[]; if (.type == "Microsoft.ApiManagement/service" and .name == $apim) or
    ((.name | startswith($prefix)) and (.type == "Microsoft.EventHub/namespaces" or .type == "Microsoft.Web/serverfarms" or .type == "Microsoft.Cache/redis"))
    then .location == $location else true end)' <<< "$RESOURCES" >/dev/null || { echo 'Existing resources are in another region. Relocation requires a separate, approved migration; nothing will be deleted.' >&2; exit 1; }
APIM=$(jq -c --arg name "$APIM_NAME" '[.[] | select(.type == "Microsoft.ApiManagement/service" and .name == $name)][0] // empty' <<< "$RESOURCES")
if enabled checkEp1Quota; then
  azure extension show --name quota -o none
  QUOTA=$(azure quota show --resource-name EP1 --scope "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Web/locations/$(value .budgetLocation)" -o json)
  [[ $(jq -er .properties.limit.value <<< "$QUOTA") -ge 2 ]] || { echo 'EP1 limit must support at least two always-ready instances. Request quota or select another region; no quota changes are automatic.' >&2; exit 1; }
  azure quota usage show --resource-name EP1 --scope "/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Web/locations/$(value .budgetLocation)" -o json
  echo 'Quota limit/usage are advisory; they do not guarantee free regional capacity or Cosmos availability.'
fi
for PROVIDER in "$ROOT"/infra/*.bicep "$ROOT/admin/pricing-access.bicep"; do az bicep build --file "$PROVIDER" --stdout >/dev/null; done
if [[ "$STAGE" == preflight ]]; then echo 'Preflight passed; no resource changes made.'; exit 0; fi
enabled pricesReviewed || { echo 'Review PRICES in snippets/15-load-pricing.py against your agreement, then set options.pricesReviewed=true.' >&2; exit 1; }
if enabled registerProviders; then
  for PROVIDER in Microsoft.ApiManagement Microsoft.Insights Microsoft.OperationalInsights Microsoft.EventHub Microsoft.Cache Microsoft.DocumentDB Microsoft.Storage Microsoft.Web Microsoft.Dashboard; do
    azure provider register --namespace "$PROVIDER" --wait -o none
  done
fi
if [[ -z "$APIM" ]]; then
  gateway_params
  deploy 04-apim-gateway "$RESOURCE_GROUP" infra/04-apim-gateway.bicep "${PARAMS[@]}" >/dev/null
fi
APIM=$(azure apim show --name "$APIM_NAME" --resource-group "$RESOURCE_GROUP" -o json)
APIM_CLIENT_ID=$(azure ad sp show --id "$(jq -er .identity.principalId <<< "$APIM")" --query appId -o tsv)
[[ -n "$APIM_CLIENT_ID" ]] || { echo 'APIM managed identity client ID not available yet; rerun after propagation.' >&2; exit 1; }
TIERS=$(deploy 14-claude-tiers "$WORKSPACE_GROUP" infra/14-claude-tiers.bicep "workspaceName=$WORKSPACE_NAME" "location=$(value .workspaceLocation)" \
  "tiersConfig=$(jq -c .tiersConfig <<< "$CONFIG")" "pricingPublisherPrincipalId=$(value .pricingPublisherPrincipalId)" "pricingPublisherPrincipalType=$(value .pricingPublisherPrincipalType)")
BUDGET=$(deploy 16-budget-platform "$RESOURCE_GROUP" infra/16-budget-platform.bicep "namePrefix=$(value .namePrefix)" "location=$(value .budgetLocation)" \
  "cosmosLocation=$(value .cosmosLocation)" "logAnalyticsWorkspaceId=$WORKSPACE_ID" "tiersConfig=$(jq -c .tiersConfig <<< "$CONFIG")" \
  "budgetApiAudience=$(value .budgetApiAudience)" "apimIdentityClientId=$APIM_CLIENT_ID" "redisSku=$(value .redisSku)" "redisCapacity=$(value .redisCapacity)" \
  "storageGovernanceTags=$(jq -c .storageGovernanceTags <<< "$CONFIG")")
REDIS_NAME=$(jq -er '.redisHost.value | split(".")[0]' <<< "$BUDGET")
deploy pricing-access "$RESOURCE_GROUP" admin/pricing-access.bicep "redisName=$REDIS_NAME" "pricingPublisherPrincipalId=$(value .pricingPublisherPrincipalId)" \
  "pricingPublisherPrincipalType=$(value .pricingPublisherPrincipalType)" "foundryAccountName=$FOUNDRY_NAME" "enableReconciler=$(jq -r .options.reconcile <<< "$CONFIG")" >/dev/null
"$PYTHON" "$ROOT/snippets/15-load-pricing.py" --dcr-endpoint "$(jq -er .pricingDcrEndpoint.value <<< "$TIERS")" \
  --dcr-immutable-id "$(jq -er .pricingDcrImmutableId.value <<< "$TIERS")" --redis-host "$(jq -er .redisHost.value <<< "$BUDGET")"
APPS=$(azure functionapp list --resource-group "$RESOURCE_GROUP" -o json)
PROCESSOR_NAME=$(jq -er --arg oid "$(jq -er .processorPrincipalId.value <<< "$BUDGET")" '[.[] | select(.identity.principalId == $oid)] | if length == 1 then .[0].name else error("Cannot uniquely resolve processor app") end' <<< "$APPS")
BUDGET_NAME=$(jq -er --arg oid "$(jq -er .budgetApiPrincipalId.value <<< "$BUDGET")" '[.[] | select(.identity.principalId == $oid)] | if length == 1 then .[0].name else error("Cannot uniquely resolve budget app") end' <<< "$APPS")
(cd "$ROOT/snippets/18-budget-api" && func azure functionapp publish "$BUDGET_NAME" --subscription "$SUBSCRIPTION_ID" --python --build remote)
(cd "$ROOT/snippets/17-usage-processor" && func azure functionapp publish "$PROCESSOR_NAME" --subscription "$SUBSCRIPTION_ID" --python --build remote)
gateway_params
deploy 04-apim-gateway "$RESOURCE_GROUP" infra/04-apim-gateway.bicep "${PARAMS[@]}" "eventHubAuthorizationRuleId=$(jq -er .eventHubAuthorizationRuleId.value <<< "$BUDGET")" \
  "eventHubName=$(jq -er .eventHubName.value <<< "$BUDGET")" "budgetApiBaseUrl=$(jq -er .budgetApiBaseUrl.value <<< "$BUDGET")" "budgetApiAudience=$(value .budgetApiAudience)" >/dev/null
export_config
if enabled smokeTest; then bash "$ROOT/developer/setup-claude-workstation.sh" --config "$OUTPUT" --test-only; fi
reporting
if enabled reconcile; then
  "$PYTHON" "$ROOT/snippets/20-cost-reconciler.py" --resource-id "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.CognitiveServices/accounts/$FOUNDRY_NAME" \
    --hours "$(value .reconcileHours)" --dcr-endpoint "$(jq -er .pricingDcrEndpoint.value <<< "$TIERS")" --dcr-immutable-id "$(jq -er .pricingDcrImmutableId.value <<< "$TIERS")"
fi
echo 'Selected steps completed. Runtime budget enforcement still requires traffic, telemetry delivery and per-tier verification; deployment success alone is not proof.'