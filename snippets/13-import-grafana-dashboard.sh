#!/usr/bin/env bash
# Import the Claude usage dashboard into Azure Managed Grafana.
#
# WHY A SCRIPT AND NOT BICEP: Azure Managed Grafana has no ARM resource for dashboards.
# The instance is deployable (11-grafana.bicep); its contents are not. Import goes
# through the Grafana API, which the `amg` Azure CLI extension wraps.
#
#   ./13-import-grafana-dashboard.sh <grafana-name> <resource-group> <workspace-resource-id>
#
# Requires: az CLI with the amg extension (installed on first use), and Grafana Admin
# or Editor on the instance. Azure RBAC Owner/Contributor on the resource is NOT enough
# to write dashboards - that mapping is separate, and 11-grafana.bicep assigns it.

set -euo pipefail

GRAFANA_NAME="${1:?usage: $0 <grafana-name> <resource-group> <workspace-resource-id>}"
RESOURCE_GROUP="${2:?missing resource group}"
WORKSPACE_ID="${3:?missing Log Analytics workspace resource ID}"

DASHBOARD_FILE="$(dirname "$0")/12-claude-usage-grafana-dashboard.json"
[ -f "$DASHBOARD_FILE" ] || { echo "not found: $DASHBOARD_FILE" >&2; exit 1; }

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

echo "==> ensuring the amg CLI extension is present"
az extension show --name amg >/dev/null 2>&1 || az extension add --name amg --only-show-errors

# The dashboard ships with a placeholder so the JSON is portable across workspaces.
# The `workspace` template variable is a hidden constant - every panel resolves
# ${workspace} to this value, so it must be a full ARM resource ID, not a workspace GUID.
echo "==> targeting workspace ${WORKSPACE_ID##*/}"
TMP="$(mktemp -t claude-dash.XXXXXX.json)"
trap 'rm -f "$TMP"' EXIT
sed "s#WORKSPACE_RESOURCE_ID_PLACEHOLDER#${WORKSPACE_ID}#g" "$DASHBOARD_FILE" > "$TMP"

if grep -q WORKSPACE_RESOURCE_ID_PLACEHOLDER "$TMP"; then
  echo "placeholder substitution failed" >&2; exit 1
fi

echo "==> importing"
az grafana dashboard create \
  --name "$GRAFANA_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --definition "@$TMP" \
  --overwrite true \
  --only-show-errors \
  --query "{uid:uid, url:url, version:version}" -o json

ENDPOINT=$(az grafana show --name "$GRAFANA_NAME" --resource-group "$RESOURCE_GROUP" \
             --query properties.endpoint -o tsv)
echo
echo "==> open: ${ENDPOINT}/d/claude-gateway-usage"
echo
echo "If panels are empty but the same query works in Log Analytics, check in this order:"
echo "  1. the Azure Monitor datasource is selected in the Data source dropdown"
echo "  2. Grafana's managed identity holds Monitoring Reader on the workspace"
echo "  3. the dashboard time range overlaps the data you expect"
echo "The History row stays empty until the summary rule's first bin completes."
