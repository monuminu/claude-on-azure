#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH=''
CONFIG_GENERATED=false
STAGE='all'
DRY_RUN=false
YES=false
DEBUG=false
LOG_FILE=''
INTERACTIVE='auto'
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG=''
SUBSCRIPTION_ID=''
TENANT_ID=''
RESOURCE_GROUP=''
FOUNDRY_RESOURCE_GROUP=''
WORKSPACE_ID=''
WORKSPACE_GROUP=''
WORKSPACE_NAME=''
APIM_NAME=''
FOUNDRY_NAME=''
PYTHON=''
OUTPUT=''
TEMP=''
TEMP_CONFIG=''
EFFECTIVE_CONFIG_PATH=''
RESOURCES=''
APIM=''
APIM_CLIENT_ID=''
DESKTOP_CLIENT_ID=''
BUDGET=''
GOVERNANCE=''
TIERS=''
APPS=''
PROCESSOR_NAME=''
BUDGET_NAME=''
REDIS_NAME=''
ACCOUNT=''
APP=''
CURRENT_STEP='startup'
MODELS=''
FAMILY=''
MODEL=''
QUOTA=''
IDENTITY=''
PRICING_OID=''
PRICING_TYPE=''
PRICING_PRINCIPAL_TYPE=''
PROVIDER=''
PARAMS=()

timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { printf '[%s] %s\n' "$(timestamp)" "$*" >&2; }
debug() { if [[ "$DEBUG" == true ]]; then log "DEBUG: $*"; fi; }
on_error() {
  local status=$? line=$1 command=$2
  set +e
  log "ERROR: exit $status at line $line during $CURRENT_STEP"
  debug "Failed command: $command"
  exit "$status"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
usage() {
  printf '%s\n' 'Usage: claude-gateway-setup.sh [--config FILE] [--stage all|preflight|reporting|retention|export] [--interactive|--non-interactive] [--dry-run] [--yes] [--debug] [--log-file FILE]' 'Interactive mode is the default in a terminal and can create admin/setup.local.json. Non-interactive mode requires --config. Deployment defaults are declared in admin/setup.example.json. Dry run is offline, not ARM what-if. --debug streams timestamped progress and Azure CLI verbose diagnostics. --log-file tees output to a file.'
}
value() { jq -er "$1" <<< "$CONFIG"; }
enabled() { [[ $(jq -r ".options.$1" <<< "$CONFIG") == true ]]; }
azure() {
  local operation="${1:-} ${2:-} ${3:-}"
  CURRENT_STEP="Azure CLI: az $operation"
  debug "$CURRENT_STEP"
  if [[ "$DEBUG" == true ]]; then az "$@" --verbose; else az "$@" --only-show-errors; fi
}
prompt_value() {
  local label=$1 default=${2:-} answer=''
  printf '%s%s: ' "$label" "${default:+ [$default]}" >&2
  IFS= read -r answer || { echo 'Input ended; rerun with --non-interactive or provide all answers.' >&2; return 1; }
  answer=${answer:-$default}
  [[ -n "$answer" ]] || { printf '%s is required.\n' "$label" >&2; return 1; }
  printf '%s' "$answer"
}
prompt_matching() {
  local label=$1 default=$2 pattern=$3 error=$4 answer=''
  while true; do
    if ! answer=$(prompt_value "$label" "$default"); then
      return 1
    fi
    if [[ "$answer" =~ $pattern ]]; then
      printf '%s' "$answer"
      return
    fi
    printf '%s\n' "$error" >&2
  done
}
prompt_choice() {
  local label=$1 default=$2 choices=$3 answer=''
  answer=$(prompt_value "$label ($choices)" "$default")
  [[ "/$choices/" == *"/$answer/"* ]] || { printf 'Choose one of: %s.\n' "${choices//\//, }" >&2; return 1; }
  printf '%s' "$answer"
}
prompt_models() {
  local answer selection model models='[]'
  printf '%s\n' 'Available models: 1=claude-sonnet-5, 2=claude-haiku-4-5, 3=claude-opus-5' >&2
  answer=$(prompt_value 'Allowed models (comma-separated numbers)' '1,2,3')
  IFS=',' read -ra selections <<< "$answer"
  for selection in "${selections[@]}"; do
    selection=${selection//[[:space:]]/}
    case "$selection" in
      1) model='claude-sonnet-5' ;;
      2) model='claude-haiku-4-5' ;;
      3) model='claude-opus-5' ;;
      *) echo 'Choose one or more model numbers from: 1, 2, 3.' >&2; return 1 ;;
    esac
    models=$(jq -c --arg model "$model" 'if index($model) then . else . + [$model] end' <<< "$models")
  done
  [[ $(jq 'length' <<< "$models") -gt 0 ]] || { echo 'Choose at least one model.' >&2; return 1; }
  printf '%s' "$models"
}
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }
configure_interactively() {
  local subscription_id tenant_id publisher_name resource_group foundry_resource_group apim_name apim_location workspace_location workbook_location publisher_email gateway_display_name workspace_id foundry_name name_prefix
  local add_teams team_name emails profile tier role team_id group_display members allowed_models team=''
  if [[ "$CONFIG_GENERATED" == true ]]; then
    subscription_id=$(prompt_value 'Subscription ID' "$(jq -r '.subscriptionId // empty | select(test("^[0-9a-fA-F-]{36}$"))' <<< "$CONFIG")")
    tenant_id=$(prompt_value 'Tenant ID' "$(jq -r '.tenantId // empty | select(test("^[0-9a-fA-F-]{36}$"))' <<< "$CONFIG")")
    publisher_name=$(prompt_value 'Publisher name' "$(jq -r '.publisherName // "Platform Engineering"' <<< "$CONFIG")")
    CONFIG=$(jq -c --arg subscription "$subscription_id" --arg tenant "$tenant_id" --arg publisher "$publisher_name" '
      .subscriptionId = $subscription | .tenantId = $tenant |
      .publisherName = $publisher | .budgetApiAudience = ""' <<< "$CONFIG")
  fi
  # pricingPublisherPrincipalId/Type are auto-detected during preflight from the
  # active Python DefaultAzureCredential; leave unset unless pinning a specific value.
  subscription_id=${subscription_id:-$(jq -r '.subscriptionId' <<< "$CONFIG")}
  resource_group=$(prompt_value 'Resource group name' "$(jq -r '.resourceGroup // empty' <<< "$CONFIG")")
  foundry_resource_group=$(prompt_value 'Foundry resource group name' "$(jq -r '.foundryResourceGroup // .resourceGroup // empty' <<< "$CONFIG")")
  apim_name=$(prompt_value 'APIM name' "$(jq -r '.apimName // empty' <<< "$CONFIG")")
  apim_location=$(prompt_value 'APIM location' 'centralus')
  workspace_location=$(prompt_value 'Workspace location' 'centralus')
  workbook_location=$(prompt_value 'Workbook location' 'centralus')
  publisher_email=$(prompt_value 'Publisher email' "$(jq -r '.publisherEmail // empty' <<< "$CONFIG")")
  gateway_display_name=$(prompt_value 'Enter a name for the gateway service principal' "$(jq -r --arg default "Claude Gateway - $apim_name" '.gatewayDisplayName // $default' <<< "$CONFIG")")
  workspace_id=$(prompt_matching 'Log Analytics workspace resource ID' "$(jq -r '.workspaceResourceId // empty' <<< "$CONFIG")" \
    "^/subscriptions/${subscription_id}/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$" \
    "Enter the full Log Analytics workspace resource ID from subscription ${subscription_id}.")
  foundry_name=$(prompt_value 'Foundry resource name' "$(jq -r '.foundryAccountName // empty' <<< "$CONFIG")")
  name_prefix=$(prompt_matching 'Resource name prefix' "$(jq -r '.namePrefix // empty' <<< "$CONFIG")" \
    '^[a-z0-9]{3,11}$' 'Use 3-11 lowercase letters or digits.')
  CONFIG=$(jq -c --arg rg "$resource_group" --arg foundryRg "$foundry_resource_group" --arg apim "$apim_name" --arg location "$apim_location" \
    --arg workspaceLocation "$workspace_location" --arg workbookLocation "$workbook_location" --arg email "$publisher_email" \
    --arg gatewayName "$gateway_display_name" --arg workspace "$workspace_id" --arg foundry "$foundry_name" --arg prefix "$name_prefix" '
      .resourceGroup = $rg | .foundryResourceGroup = $foundryRg | .apimName = $apim | .apimLocation = $location | .budgetLocation = $location |
      .cosmosLocation = $location | .workspaceLocation = $workspaceLocation | .workbookLocation = $workbookLocation |
      .publisherEmail = $email | .gatewayDisplayName = $gatewayName | .budgetApiAudience = "" |
      .workspaceResourceId = $workspace |
      .foundryAccountName = $foundry | .namePrefix = $prefix' <<< "$CONFIG")

  add_teams=$(prompt_choice 'Configure team governance now?' 'yes' 'yes/no')
  if [[ "$add_teams" == yes ]]; then
    CONFIG=$(jq -c '.teamGovernance = ((.teamGovernance // {}) + {mode: ((.teamGovernance.mode // "observe") | if . == "off" then "observe" else . end), actionGroupIds: (.teamGovernance.actionGroupIds // []), profiles: .teamGovernance.profiles, teams: []})' <<< "$CONFIG")
    while true; do
      team_name=$(prompt_value 'Team name')
      emails=$(prompt_value 'Team member email IDs (comma separated)')
      profile=$(prompt_choice 'Team profile' 'regular' 'regular/power')
      tier=$(prompt_choice 'Default user tier' 'basic' 'pro/basic/lite')
      team_id=$(slug "$team_name")
      [[ ${#team_id} -ge 3 ]] || { echo 'Team name must produce an identifier of at least three letters or digits.' >&2; return 1; }
      role=$(prompt_value 'Team role' "${team_id}.${profile}")
      allowed_models=$(prompt_models)
      group_display="Claude Team - $team_name"
      members=$(jq -cn --arg emails "$emails" '$emails | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')
      team=$(jq -cn --arg id "$team_id" --arg display "$team_name" --arg group "$group_display" --arg role "$role" \
        --arg profile "$profile" --arg tier "$tier" --argjson allowedModels "$allowed_models" --argjson members "$members" \
        '{id:$id, displayName:$display, groupDisplayName:$group, teamRoleValue:$role, profile:$profile, defaultUserTier:$tier, allowedModels:$allowedModels, members:$members}')
      CONFIG=$(jq -c --argjson team "$team" '.teamGovernance.teams += [$team]' <<< "$CONFIG")
      [[ $(prompt_choice 'Add another team?' 'no' 'yes/no') == yes ]] || break
    done
  elif [[ "$CONFIG_GENERATED" == true ]]; then
    CONFIG=$(jq -c 'del(.teamGovernance)' <<< "$CONFIG")
  fi
}
ensure_gateway_app() {
  local name apps app count client_id object_id resource scope_id role_id api_patch service_principals
  name=$(jq -er '.gatewayDisplayName' <<< "$CONFIG")
  apps=$(azure ad app list --display-name "$name" -o json)
  count=$(jq 'length' <<< "$apps")
  [[ "$count" -le 1 ]] || { printf 'Multiple Entra applications are named "%s"; choose a unique gateway service principal name.\n' "$name" >&2; return 1; }
  if [[ "$count" -eq 1 ]]; then
    app=$(jq -c '.[0]' <<< "$apps")
  else
    app=$(azure ad app create --display-name "$name" --sign-in-audience AzureADMyOrg -o json)
  fi
  client_id=$(jq -er .appId <<< "$app")
  object_id=$(jq -er .id <<< "$app")
  resource="api://$client_id"
  app=$(azure ad app show --id "$client_id" -o json)
  scope_id=$(jq -r '[.api.oauth2PermissionScopes[]? | select(.value == "access_as_user")][0].id // empty' <<< "$app")
  role_id=$(jq -r '[.appRoles[]? | select(.value == "Claude.User")][0].id // empty' <<< "$app")
  scope_id=${scope_id:-$(uuidgen | tr '[:upper:]' '[:lower:]')}
  role_id=${role_id:-$(uuidgen | tr '[:upper:]' '[:lower:]')}
  api_patch=$(jq -c --arg resource "$resource" --arg scope "$scope_id" --arg role "$role_id" '
    .identifierUris = ((.identifierUris // []) + [$resource] | unique) |
    .api = ((.api // {}) + {requestedAccessTokenVersion: 2}) |
    .api.oauth2PermissionScopes = ((.api.oauth2PermissionScopes // []) |
      if any(.[]; .value == "access_as_user") then map(if .value == "access_as_user" then . + {isEnabled:true} else . end) else . + [{id:$scope, value:"access_as_user", type:"User", isEnabled:true, adminConsentDisplayName:"Access Claude Gateway", adminConsentDescription:"Access the Claude gateway as the signed-in user", userConsentDisplayName:"Access Claude Gateway", userConsentDescription:"Access the Claude gateway as you"}] end) |
    .appRoles = ((.appRoles // []) |
      if any(.[]; .value == "Claude.User") then map(if .value == "Claude.User" then . + {isEnabled:true, allowedMemberTypes:((.allowedMemberTypes // []) + ["User"] | unique)} else . end) else . + [{id:$role, value:"Claude.User", displayName:"Claude User", description:"Access to the Claude gateway", isEnabled:true, allowedMemberTypes:["User"]}] end) |
    {identifierUris, api, appRoles}' <<< "$app")
  azure rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$object_id" \
    --headers Content-Type=application/json --body "$api_patch" -o none
  service_principals=$(azure ad sp list --filter "appId eq '$client_id'" -o json)
  if [[ $(jq 'length' <<< "$service_principals") -eq 0 ]]; then azure ad sp create --id "$client_id" -o none; fi
  CONFIG=$(jq --arg audience "$client_id" --arg resource "$resource" '.gatewayAudience = $audience | .tokenResource = $resource' <<< "$CONFIG")
  printf 'Gateway application and service principal: %s (%s)\n' "$name" "$client_id" >&2
}
ensure_budget_api_app() {
  local name="Claude Budget API - $(value .namePrefix)" apps='' app='' count=0 client_id='' service_principals=''
  client_id=$(jq -r '.budgetApiAudience // empty' <<< "$CONFIG")
  if [[ -n "$client_id" ]]; then
    azure ad sp show --id "$client_id" -o none
    printf '%s' "$client_id"
    return
  fi
  apps=$(azure ad app list --display-name "$name" -o json)
  count=$(jq 'length' <<< "$apps")
  [[ "$count" -le 1 ]] || { printf 'Multiple Entra applications are named "%s"; set budgetApiAudience explicitly.\n' "$name" >&2; return 1; }
  if [[ "$count" -eq 1 ]]; then
    app=$(jq -c '.[0]' <<< "$apps")
  else
    app=$(azure ad app create --display-name "$name" --sign-in-audience AzureADMyOrg -o json)
  fi
  client_id=$(jq -er .appId <<< "$app")
  service_principals=$(azure ad sp list --filter "appId eq '$client_id'" -o json)
  if [[ $(jq 'length' <<< "$service_principals") -eq 0 ]]; then azure ad sp create --id "$client_id" -o none; fi
  CONFIG=$(jq --arg audience "$client_id" '.budgetApiAudience = $audience' <<< "$CONFIG")
  printf 'Budget API application: %s\n' "$client_id" >&2
  printf '%s' "$client_id"
}
deploy() {
  local name=$1 group=$2 file=$3 result=''
  shift 3
  printf 'Deploying %s in %s\n' "$name" "$group" >&2
  jq -n --args '$ARGS.positional | map(index("=") as $pos | .[:$pos] as $key | {key: $key, value: {value: (.[($pos+1):] | if (["tiersConfig", "teamGovernanceConfig", "profiles", "teams", "actionGroupIds", "storageGovernanceTags", "redisCapacity", "enableReconciler", "deployPolicy"] | index($key)) != null then fromjson else . end)}}) | from_entries' "$@" > "$TEMP/$name.parameters.json"
  result=$(azure deployment group create --name "$name" --resource-group "$group" --template-file "$ROOT/$file" --parameters "@$TEMP/$name.parameters.json" -o json)
  jq -e 'if .properties.provisioningState == "Succeeded" then (.properties.outputs // {}) else error("Deployment did not succeed") end' <<< "$result"
}
gateway_params() {
  PARAMS=("apimName=$APIM_NAME" "apimLocation=$(value .apimLocation)" "foundryAccountName=$FOUNDRY_NAME"
    "foundryResourceGroup=$FOUNDRY_RESOURCE_GROUP"
    "publisherEmail=$(value .publisherEmail)" "publisherName=$(value .publisherName)" "entraTenantId=$TENANT_ID"
    "gatewayAudience=$(value .gatewayAudience)" "logAnalyticsWorkspaceId=$WORKSPACE_ID" "tiersConfig=$(jq -c .tiersConfig <<< "$CONFIG")")
}
team_governance_config() {
  jq -c '.teamGovernance // {mode:"off", profiles:[], teams:[]}' <<< "$CONFIG"
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
    bash "$ROOT/infra/13-import-grafana-dashboard.sh" "$(value .grafanaName)" "$RESOURCE_GROUP" "$WORKSPACE_ID"
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
    --debug) DEBUG=true; shift ;;
    --log-file)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      LOG_FILE=$2
      shift 2 ;;
    --interactive) INTERACTIVE=true; shift ;; --non-interactive) INTERACTIVE=false; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
if [[ -n "$LOG_FILE" ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Streaming setup output to $LOG_FILE"
fi
debug 'Debug logging enabled (Azure CLI verbose mode; raw shell tracing is disabled).'
case "$STAGE" in all|preflight|reporting|retention|export) ;; *) usage >&2; exit 2 ;; esac
if [[ "$INTERACTIVE" == auto ]]; then
  if [[ -t 0 ]]; then INTERACTIVE=true; else INTERACTIVE=false; fi
fi
if [[ -z "$CONFIG_PATH" ]]; then
  [[ "$INTERACTIVE" == true ]] || { echo 'Non-interactive mode requires --config FILE.' >&2; usage >&2; exit 2; }
  CONFIG_PATH="$ROOT/admin/setup.local.json"
  CONFIG_GENERATED=true
fi
if [[ -s "$CONFIG_PATH" ]]; then
  CONFIG=$(jq -ec . "$CONFIG_PATH")
elif [[ "$CONFIG_GENERATED" == true ]]; then
  CONFIG=$(jq -ec . "$ROOT/admin/setup.example.json")
else
  printf 'Config file is empty or missing: %s\n' "$CONFIG_PATH" >&2
  exit 2
fi
if [[ "$INTERACTIVE" == true ]]; then configure_interactively; fi
if [[ "$INTERACTIVE" == true && ! $(jq -r '.gatewayAudience // empty' <<< "$CONFIG") =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
  jq --arg audience '00000000-0000-4000-8000-000000000001' \
    '.gatewayAudience = $audience | .tokenResource = ("api://" + $audience)' <<< "$CONFIG" |
    jq -e -f "$ROOT/admin/validate-config.jq" >/dev/null
else
  CONFIG=$(jq -e -f "$ROOT/admin/validate-config.jq" <<< "$CONFIG")
fi
if [[ "$CONFIG_GENERATED" == true ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    printf 'DRY RUN: generated configuration was validated but not written. Rerun without --dry-run to save %s.\n' "$CONFIG_PATH"
  fi
fi
SUBSCRIPTION_ID=$(value .subscriptionId)
TENANT_ID=$(value .tenantId)
RESOURCE_GROUP=$(value .resourceGroup)
FOUNDRY_RESOURCE_GROUP=$(jq -r '.foundryResourceGroup // .resourceGroup' <<< "$CONFIG")
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
ACCOUNT=$(azure account show --subscription "$SUBSCRIPTION_ID" -o json)
[[ $(jq -r .tenantId <<< "$ACCOUNT") == "$TENANT_ID" ]] || { echo 'Wrong Azure tenant; log in to the configured tenant.' >&2; exit 1; }
azure account set --subscription "$SUBSCRIPTION_ID"
if [[ "$STAGE" != preflight && "$YES" != true ]]; then echo 'Review --dry-run, then pass --yes to authorize the selected changes.' >&2; exit 2; fi
if [[ "$INTERACTIVE" == true ]]; then
  ensure_gateway_app
  CONFIG=$(jq -e -f "$ROOT/admin/validate-config.jq" <<< "$CONFIG")
  if [[ "$CONFIG_GENERATED" == true ]]; then
    umask 077
    TEMP_CONFIG=$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")
    jq . <<< "$CONFIG" > "$TEMP_CONFIG" || { rm -f "$TEMP_CONFIG"; exit 1; }
    mv "$TEMP_CONFIG" "$CONFIG_PATH"
    printf 'Saved interactive configuration to %s.\n' "$CONFIG_PATH"
  fi
fi
TEMP=$(mktemp -d)
trap 'rm -rf "$TEMP"' EXIT
EFFECTIVE_CONFIG_PATH="$TEMP/effective-config.json"
printf '%s\n' "$CONFIG" > "$EFFECTIVE_CONFIG_PATH"
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
[[ $(jq -r .tid <<< "$IDENTITY") == "$TENANT_ID" ]] || { echo 'Python credential resolved to a different tenant than tenantId.' >&2; exit 1; }
PRICING_OID=$(jq -r .oid <<< "$IDENTITY")
if [[ -z "$(jq -r '.pricingPublisherPrincipalId // empty' <<< "$CONFIG")" ]]; then
  PRICING_TYPE=$(azure rest --method GET --url "https://graph.microsoft.com/v1.0/directoryObjects/$PRICING_OID" --query '"@odata.type"' -o tsv)
  case "$PRICING_TYPE" in
    '#microsoft.graph.user') PRICING_PRINCIPAL_TYPE='User' ;;
    '#microsoft.graph.servicePrincipal') PRICING_PRINCIPAL_TYPE='ServicePrincipal' ;;
    *) printf 'Unable to determine pricing publisher principal type for %s (got %s).\n' "$PRICING_OID" "$PRICING_TYPE" >&2; exit 1 ;;
  esac
  CONFIG=$(jq --arg id "$PRICING_OID" --arg type "$PRICING_PRINCIPAL_TYPE" '.pricingPublisherPrincipalId = $id | .pricingPublisherPrincipalType = $type' <<< "$CONFIG")
  printf 'Pricing publisher principal auto-detected from the active Python credential: %s (%s)\n' "$PRICING_OID" "$PRICING_PRINCIPAL_TYPE"
else
  [[ "$PRICING_OID" == "$(value .pricingPublisherPrincipalId)" ]] || { echo 'Python credential identity does not match the configured pricingPublisherPrincipalId.' >&2; exit 1; }
fi
azure group show --name "$RESOURCE_GROUP" -o none
azure group show --name "$FOUNDRY_RESOURCE_GROUP" -o none
azure cognitiveservices account show --name "$FOUNDRY_NAME" --resource-group "$FOUNDRY_RESOURCE_GROUP" -o none
[[ $(azure resource show --ids "$WORKSPACE_ID" --query location -o tsv) == "$(value .workspaceLocation)" ]] || { echo 'workspaceLocation does not match the existing workspace.' >&2; exit 1; }
MODELS=$(azure cognitiveservices account deployment list --name "$FOUNDRY_NAME" --resource-group "$FOUNDRY_RESOURCE_GROUP" -o json)
for FAMILY in opus sonnet haiku; do
  MODEL=$(jq -r --arg family "$FAMILY" '.models[$family]' <<< "$CONFIG")
  if [[ -z "$MODEL" ]]; then
    MODEL=$(jq -er --arg family "$FAMILY" '[.[] | select((.properties.model.name // .name) | ascii_downcase | contains($family)) | .name] | if length == 1 then .[0] else error("Set models." + $family + ": no unique deployment") end' <<< "$MODELS")
    CONFIG=$(jq --arg family "$FAMILY" --arg model "$MODEL" '.models[$family] = $model' <<< "$CONFIG")
  fi
done
jq -e --argjson config "$CONFIG" 'map(.name) as $names | [$config.models[]] | all(.[]; . as $model | $names | index($model) != null)' <<< "$MODELS" >/dev/null || { echo 'A configured model is not deployed in Foundry.' >&2; exit 1; }
APP=$(azure ad app show --id "$(value .gatewayAudience)" -o json)
CURRENT_STEP='gateway Entra application validation'
APP_VALID=true
if ! jq -e '.api.requestedAccessTokenVersion == 2' <<< "$APP" >/dev/null; then
  echo 'Gateway app must set api.requestedAccessTokenVersion to 2.' >&2
  APP_VALID=false
fi
if ! jq -e --arg resource "$(value .tokenResource)" '.identifierUris | index($resource) != null' <<< "$APP" >/dev/null; then
  echo "Gateway app identifierUris must include $(value .tokenResource)." >&2
  APP_VALID=false
fi
if ! jq -e 'any(.appRoles[]; .value == "Claude.User" and .isEnabled)' <<< "$APP" >/dev/null; then
  echo 'Gateway app must define an enabled Claude.User app role.' >&2
  APP_VALID=false
fi
[[ "$APP_VALID" == true ]] || exit 1
jq -e --arg resource "$(value .tokenResource)" '.api.requestedAccessTokenVersion == 2 and (.identifierUris | index($resource) != null) and any(.appRoles[]; .value == "Claude.User" and .isEnabled)' <<< "$APP" >/dev/null || { echo 'Gateway app needs v2 tokens, the configured identifier URI and an enabled Claude.User role.' >&2; exit 1; }
if [[ "$STAGE" != preflight ]]; then configure_desktop_client; fi
if [[ -n $(jq -r '.budgetApiAudience // empty' <<< "$CONFIG") ]]; then azure ad sp show --id "$(value .budgetApiAudience)" -o none; fi
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
if [[ "$STAGE" == preflight ]]; then echo 'Preflight passed; the gateway identity was ensured in interactive mode, and no Azure resource deployments were made.'; exit 0; fi
enabled pricesReviewed || { echo 'Review PRICES in snippets/15-load-pricing.py against your agreement, then set options.pricesReviewed=true.' >&2; exit 1; }
if enabled registerProviders; then
  for PROVIDER in Microsoft.ApiManagement Microsoft.Insights Microsoft.OperationalInsights Microsoft.EventHub Microsoft.Cache Microsoft.DocumentDB Microsoft.Storage Microsoft.Web Microsoft.Dashboard; do
    azure provider register --namespace "$PROVIDER" --wait -o none
  done
fi
if [[ -z "$APIM" ]]; then
  gateway_params
  deploy 04-apim-gateway "$RESOURCE_GROUP" infra/04-apim-gateway.bicep "${PARAMS[@]}" "deployPolicy=false" >/dev/null
fi
APIM=$(azure apim show --name "$APIM_NAME" --resource-group "$RESOURCE_GROUP" -o json)
APIM_CLIENT_ID=$(azure ad sp show --id "$(jq -er .identity.principalId <<< "$APIM")" --query appId -o tsv)
[[ -n "$APIM_CLIENT_ID" ]] || { echo 'APIM managed identity client ID not available yet; rerun after propagation.' >&2; exit 1; }
TIERS=$(deploy 14-claude-tiers "$WORKSPACE_GROUP" infra/14-claude-tiers.bicep "workspaceName=$WORKSPACE_NAME" "location=$(value .workspaceLocation)" \
  "tiersConfig=$(jq -c .tiersConfig <<< "$CONFIG")" "pricingPublisherPrincipalId=$(value .pricingPublisherPrincipalId)" "pricingPublisherPrincipalType=$(value .pricingPublisherPrincipalType)")
BUDGET=$(deploy 16-budget-platform "$RESOURCE_GROUP" infra/16-budget-platform.bicep "namePrefix=$(value .namePrefix)" "location=$(value .budgetLocation)" \
  "cosmosLocation=$(value .cosmosLocation)" "logAnalyticsWorkspaceId=$WORKSPACE_ID" "tiersConfig=$(jq -c .tiersConfig <<< "$CONFIG")" \
  "teamGovernanceConfig=$(team_governance_config)" \
  "budgetApiAudience=$(value .budgetApiAudience)" "apimIdentityClientId=$APIM_CLIENT_ID" "redisSku=$(value .redisSku)" "redisCapacity=$(value .redisCapacity)" \
  "storageGovernanceTags=$(jq -c .storageGovernanceTags <<< "$CONFIG")")
BUDGET_API_AUDIENCE=$(ensure_budget_api_app)
CONFIG=$(jq --arg audience "$BUDGET_API_AUDIENCE" '.budgetApiAudience = $audience' <<< "$CONFIG")
if [[ -z $(jq -r '.budgetApiAudience // empty' "$EFFECTIVE_CONFIG_PATH") ]]; then
  BUDGET=$(deploy 16-budget-platform "$RESOURCE_GROUP" infra/16-budget-platform.bicep "namePrefix=$(value .namePrefix)" "location=$(value .budgetLocation)" \
    "cosmosLocation=$(value .cosmosLocation)" "logAnalyticsWorkspaceId=$WORKSPACE_ID" "tiersConfig=$(jq -c .tiersConfig <<< "$CONFIG")" \
    "teamGovernanceConfig=$(team_governance_config)" "budgetApiAudience=$BUDGET_API_AUDIENCE" "apimIdentityClientId=$APIM_CLIENT_ID" \
    "redisSku=$(value .redisSku)" "redisCapacity=$(value .redisCapacity)" "storageGovernanceTags=$(jq -c .storageGovernanceTags <<< "$CONFIG")")
fi
printf '%s\n' "$CONFIG" > "$EFFECTIVE_CONFIG_PATH"
REDIS_NAME=$(jq -er '.redisHost.value | split(".")[0]' <<< "$BUDGET")
deploy pricing-access "$RESOURCE_GROUP" admin/pricing-access.bicep "redisName=$REDIS_NAME" "pricingPublisherPrincipalId=$(value .pricingPublisherPrincipalId)" \
  "pricingPublisherPrincipalType=$(value .pricingPublisherPrincipalType)" "foundryAccountName=$FOUNDRY_NAME" "foundryResourceGroup=$FOUNDRY_RESOURCE_GROUP" "enableReconciler=$(jq -r .options.reconcile <<< "$CONFIG")" \
  "cosmosAccountName=$(jq -er .cosmosAccountName.value <<< "$BUDGET")" >/dev/null
"$PYTHON" "$ROOT/snippets/15-load-pricing.py" --dcr-endpoint "$(jq -er .pricingDcrEndpoint.value <<< "$TIERS")" \
  --dcr-immutable-id "$(jq -er .pricingDcrImmutableId.value <<< "$TIERS")" --redis-host "$(jq -er .redisHost.value <<< "$BUDGET")"
APPS=$(azure functionapp list --resource-group "$RESOURCE_GROUP" -o json)
PROCESSOR_NAME=$(jq -er --arg oid "$(jq -er .processorPrincipalId.value <<< "$BUDGET")" '[.[] | select(.identity.principalId == $oid)] | if length == 1 then .[0].name else error("Cannot uniquely resolve processor app") end' <<< "$APPS")
BUDGET_NAME=$(jq -er --arg oid "$(jq -er .budgetApiPrincipalId.value <<< "$BUDGET")" '[.[] | select(.identity.principalId == $oid)] | if length == 1 then .[0].name else error("Cannot uniquely resolve budget app") end' <<< "$APPS")
(cd "$ROOT/snippets/18-budget-api" && func azure functionapp publish "$BUDGET_NAME" --subscription "$SUBSCRIPTION_ID" --python --build remote)
(cd "$ROOT/snippets/17-usage-processor" && func azure functionapp publish "$PROCESSOR_NAME" --subscription "$SUBSCRIPTION_ID" --python --build remote)
if [[ $(jq -r '.teamGovernance.mode // "off"' <<< "$CONFIG") != off ]]; then
  bash "$ROOT/admin/setup-teams-governance-claude-gateway.sh" --config "$EFFECTIVE_CONFIG_PATH" --yes --skip-infrastructure
fi
GOVERNANCE_ARGS=("apimName=$APIM_NAME" "logAnalyticsWorkspaceId=$WORKSPACE_ID" "logAnalyticsWorkspaceName=$WORKSPACE_NAME" "workbookLocation=$(value .workbookLocation)" "teamGovernanceMode=$(jq -r '.teamGovernance.mode // "off"' <<< "$CONFIG")")
if jq -e '.teamGovernance != null' <<< "$CONFIG" >/dev/null; then
  GOVERNANCE_ARGS+=("profiles=$(jq -c .teamGovernance.profiles <<< "$CONFIG")" "teams=$(jq -c .teamGovernance.teams <<< "$CONFIG")")
  GOVERNANCE_ARGS+=("actionGroupIds=$(jq -c '.teamGovernance.actionGroupIds // []' <<< "$CONFIG")")
fi
GOVERNANCE=$(deploy 22-team-governance "$RESOURCE_GROUP" infra/22-team-governance.bicep "${GOVERNANCE_ARGS[@]}")
jq -e '.teamGovernanceModeNamedValue.value == "team-governance-mode" and
  .teamsJsonNamedValue.value == "team-governance-teams-json" and
  .profilesJsonNamedValue.value == "team-governance-profiles-json" and
  (.workbookId.value | length > 0) and .claudeTeamsFunctionName.value == "ClaudeTeams" and
  (.alertsCreated.value | type == "boolean")' <<< "$GOVERNANCE" >/dev/null || { echo 'Team governance deployment outputs are incomplete; final APIM policy was not deployed.' >&2; exit 1; }
gateway_params
deploy 04-apim-gateway "$RESOURCE_GROUP" infra/04-apim-gateway.bicep "${PARAMS[@]}" "eventHubAuthorizationRuleId=$(jq -er .eventHubAuthorizationRuleId.value <<< "$BUDGET")" \
  "eventHubName=$(jq -er .eventHubName.value <<< "$BUDGET")" "budgetApiBaseUrl=$(jq -er .budgetApiBaseUrl.value <<< "$BUDGET")" "budgetApiAudience=$BUDGET_API_AUDIENCE" "deployPolicy=true" >/dev/null
export_config
if enabled smokeTest; then bash "$ROOT/developer/setup-claude-workstation.sh" --config "$OUTPUT" --test-only; fi
reporting
if enabled reconcile; then
  "$PYTHON" "$ROOT/snippets/20-cost-reconciler.py" --resource-id "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$FOUNDRY_RESOURCE_GROUP/providers/Microsoft.CognitiveServices/accounts/$FOUNDRY_NAME" \
    --hours "$(value .reconcileHours)" --dcr-endpoint "$(jq -er .pricingDcrEndpoint.value <<< "$TIERS")" --dcr-immutable-id "$(jq -er .pricingDcrImmutableId.value <<< "$TIERS")" \
    --cosmos-endpoint "$(jq -er .cosmosEndpoint.value <<< "$BUDGET")" --cosmos-database "$(jq -er .cosmosDatabaseName.value <<< "$BUDGET")" \
    --cosmos-container "$(jq -er .cosmosContainerName.value <<< "$BUDGET")" --redis-host "$(jq -er .redisHost.value <<< "$BUDGET")" \
    --tiers-json "$(jq -c .tiersConfig <<< "$CONFIG")" --team-governance-json "$(team_governance_config)"
fi
echo 'Selected steps completed. Runtime budget enforcement still requires traffic, telemetry delivery and per-tier verification; deployment success alone is not proof.'