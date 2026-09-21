#!/usr/bin/env bash
set -euo pipefail

SUBSCRIPTION_ID=''
TENANT_ID=''
RESOURCE_GROUP=''
DEPLOYMENT_NAME='04-apim-gateway'
DEPLOYMENT_FILE=''
OUTPUT='./claude-client-configuration.json'
TOKEN_RESOURCE=''
CLIENT_ID=''
SCOPES=''
CLIENT_SETTINGS_FILE=''
OPUS_MODEL=''
SONNET_MODEL=''
HAIKU_MODEL=''
FORCE=false
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Internal working state; these are not configuration inputs.
DEPLOYMENT=''
DEPLOYED_TENANT=''
APP=''
SETTINGS='{}'
CONFIG=''

usage() {
  printf '%s\n' \
    'Usage: export-claude-client-configuration.sh [options]' \
    'Run without options for an interactive live-Azure export.' \
    'Common options: --subscription-id ID --resource-group NAME --client-id DESKTOP-CLIENT-ID --scopes "openid profile API-SCOPE" --output FILE --force' \
    'Advanced options: --tenant-id ID --deployment-name NAME --deployment-file FILE --token-resource URI --client-settings FILE --opus-model NAME --sonnet-model NAME --haiku-model NAME' \
    'The live export discovers the gateway URL, tenant, API token resource, and delegated scope. The JSON contains client settings only.'
}
prompt_value() {
  local label=$1 default=${2:-} answer=''
  printf '%s%s: ' "$label" "${default:+ [$default]}" >&2
  IFS= read -r answer || { echo 'Input ended; supply explicit arguments for unattended export.' >&2; return 1; }
  answer=${answer:-$default}
  [[ -n "$answer" ]] || { echo 'A value is required.' >&2; return 1; }
  printf '%s' "$answer"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --force) FORCE=true; shift ;;
    --subscription-id|--tenant-id|--resource-group|--deployment-name|--deployment-file|--output|--token-resource|--client-id|--scopes|--client-settings|--opus-model|--sonnet-model|--haiku-model)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      case "$1" in
        --subscription-id) SUBSCRIPTION_ID=$2 ;; --tenant-id) TENANT_ID=$2 ;;
        --resource-group) RESOURCE_GROUP=$2 ;; --deployment-name) DEPLOYMENT_NAME=$2 ;;
        --deployment-file) DEPLOYMENT_FILE=$2 ;; --output) OUTPUT=$2 ;;
        --token-resource) TOKEN_RESOURCE=$2 ;; --client-id) CLIENT_ID=$2 ;;
        --scopes) SCOPES=$2 ;; --client-settings) CLIENT_SETTINGS_FILE=$2 ;;
        --opus-model) OPUS_MODEL=$2 ;; --sonnet-model) SONNET_MODEL=$2 ;; --haiku-model) HAIKU_MODEL=$2 ;;
      esac
      shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null || { echo 'Install jq first.' >&2; exit 1; }
[[ ! -e "$OUTPUT" || "$FORCE" == true ]] || { echo 'Output exists; use --force to replace it.' >&2; exit 1; }
if [[ -n "$DEPLOYMENT_FILE" ]]; then
  DEPLOYMENT=$(jq -e . "$DEPLOYMENT_FILE")
else
  command -v az >/dev/null || { echo 'Install Azure CLI first.' >&2; exit 1; }
  [[ -n "$SUBSCRIPTION_ID" ]] || SUBSCRIPTION_ID=$(prompt_value 'Azure subscription ID')
  [[ -n "$RESOURCE_GROUP" ]] || RESOURCE_GROUP=$(prompt_value 'Gateway resource group')
  DEPLOYMENT=$(az deployment group show --subscription "$SUBSCRIPTION_ID" --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --only-show-errors -o json)
fi
jq -e '.properties.provisioningState == "Succeeded" and (.properties.outputs.gatewayBaseUrl.value | type == "string")' <<< "$DEPLOYMENT" >/dev/null || { echo 'Missing gateway URL or unsuccessful deployment.' >&2; exit 1; }
DEPLOYED_TENANT=$(jq -r '.properties.parameters.entraTenantId.value // empty' <<< "$DEPLOYMENT")
[[ -z "$TENANT_ID" || -z "$DEPLOYED_TENANT" || "$TENANT_ID" == "$DEPLOYED_TENANT" ]] || { echo 'Tenant differs from deployed gateway tenant.' >&2; exit 1; }
TENANT_ID=${TENANT_ID:-$DEPLOYED_TENANT}
if [[ -z "$TENANT_ID" && -z "$DEPLOYMENT_FILE" ]]; then
  TENANT_ID=$(az account show --subscription "$SUBSCRIPTION_ID" --query tenantId --only-show-errors -o tsv)
fi
[[ -n "$TENANT_ID" ]] || { echo 'Offline export needs --tenant-id or a deployed entraTenantId parameter.' >&2; exit 1; }
if [[ -z "$SCOPES" && -z "$DEPLOYMENT_FILE" ]]; then
  APP=$(az ad app show --id "$(jq -er .properties.parameters.gatewayAudience.value <<< "$DEPLOYMENT")" --only-show-errors -o json)
  if [[ -z "$TOKEN_RESOURCE" ]]; then
    TOKEN_RESOURCE=$(jq -er --arg default "api://$(jq -er .properties.parameters.gatewayAudience.value <<< "$DEPLOYMENT")" '.identifierUris | if index($default) != null then $default elif length == 1 then .[0] else error("Supply --token-resource for ambiguous identifier URIs") end' <<< "$APP")
  fi
  SCOPES=$(jq -r --arg resource "$TOKEN_RESOURCE" '[.api.oauth2PermissionScopes[]? | select(.isEnabled) | .value] | if index("access_as_user") != null then "openid profile " + $resource + "/access_as_user" elif length == 1 then "openid profile " + $resource + "/" + .[0] else empty end' <<< "$APP")
fi
[[ -n "$CLIENT_ID" ]] || CLIENT_ID=$(prompt_value 'Desktop OIDC client ID (public-client registration)')
[[ -n "$SCOPES" ]] || SCOPES=$(prompt_value 'Scopes (space-separated; include the registered gateway API scope)')
[[ -n "$OPUS_MODEL" ]] || OPUS_MODEL=$(prompt_value 'Opus model deployment name' 'claude-opus-5')
[[ -n "$SONNET_MODEL" ]] || SONNET_MODEL=$(prompt_value 'Sonnet model deployment name' 'claude-sonnet-5')
[[ -n "$HAIKU_MODEL" ]] || HAIKU_MODEL=$(prompt_value 'Haiku model deployment name' 'claude-haiku-5-4')
[[ -z "$CLIENT_SETTINGS_FILE" ]] || SETTINGS=$(jq -e . "$CLIENT_SETTINGS_FILE")
CONFIG=$(jq -n --arg url "$(jq -er .properties.outputs.gatewayBaseUrl.value <<< "$DEPLOYMENT")" --arg tenant "$TENANT_ID" --arg client "$CLIENT_ID" --arg scopes "$SCOPES" \
  --arg opus "$OPUS_MODEL" --arg sonnet "$SONNET_MODEL" --arg haiku "$HAIKU_MODEL" --argjson settings "$SETTINGS" -f "$ROOT/client-configuration.jq")
mkdir -p "$(dirname "$OUTPUT")"
printf '%s\n' "$CONFIG" > "$OUTPUT"
printf 'Created %s (client settings only; no credentials). Model defaults are not proof of deployment availability.\n' "$OUTPUT"