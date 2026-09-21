#!/usr/bin/env bash
set -euo pipefail

CONFIG=''
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DRY_RUN=false
INSTALL_CLAUDE=false
INSTALL_VSCODE=false
LOGIN=false
SMOKE_TEST=false
TEST_ONLY=false
RAW=''
SETTINGS=''
HELPER_DIR=''
HELPER=''
MERGED=''
EXISTING='{}'
TOKEN=''
BODY=''
STATUS=''
TEMP=''
BACKUP=''
ENV_NAME=''
TOKEN_SCOPE=''

usage() {
  printf '%s\n' 'Usage: setup-claude-workstation.sh --config FILE [--claude-dir DIR] [--dry-run] [--install-claude] [--install-vscode] [--login] [--smoke-test | --test-only]' 'Requires jq and Azure CLI. Installation additionally requires npm or the VS Code code command.' 'Dry run makes no changes or network calls. Smoke tests make a small billable request.'
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --config|--claude-dir)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      case "$1" in --config) CONFIG=$2 ;; --claude-dir) CLAUDE_DIR=$2 ;; esac
      shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;; --install-claude) INSTALL_CLAUDE=true; shift ;;
    --install-vscode) INSTALL_VSCODE=true; shift ;; --login) LOGIN=true; shift ;;
    --smoke-test) SMOKE_TEST=true; shift ;; --test-only) TEST_ONLY=true; SMOKE_TEST=true; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -n "$CONFIG" ]] || { usage >&2; exit 2; }
[[ "$CLAUDE_DIR" == /* ]] || CLAUDE_DIR="$PWD/$CLAUDE_DIR"
command -v jq >/dev/null || { echo 'Install jq first (macOS: brew install jq).' >&2; exit 1; }
RAW=$(jq -e '
  def guid: type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
  .gatewaySso.clientId as $client |
  if .provider == "gateway" and .credentialKind == "interactive_sign_in" and (.gatewaySso.clientId | guid) and
    (.gatewaySso.issuerUrl | type == "string" and test("^https://login.microsoftonline.com/[0-9a-fA-F-]+/v2.0$")) and
    (.gatewaySso.issuerUrl | split("/")[3] | guid) and
    (.gatewayUrl | type == "string" and test("^https://[A-Za-z0-9.-]+(:[0-9]+)?/anthropic$")) and
    (.gatewaySso.scopes | type == "string" and (test("[\r\n]") | not) and
      (split(" ") | map(select(startswith("api://") or startswith("https://")) | sub("/[^/]+$"; "")) | unique |
        length == 1 and all(.[]; test("^(api://|https://)[A-Za-z0-9./:_-]+$") and . != ("api://" + $client)))) and
    ([.models.opus, .models.sonnet, .models.haiku] | all(.[]; type == "string" and length > 0))
  then . else error("Invalid claude-client-configuration.json; obtain a fresh export from your administrator") end' "$CONFIG")
TOKEN_SCOPE=$(jq -er '.gatewaySso.scopes | split(" ") | map(select(startswith("api://") or startswith("https://"))) | first' <<< "$RAW")
SETTINGS="$CLAUDE_DIR/settings.json"
HELPER_DIR="$CLAUDE_DIR/gateway"
HELPER="$HELPER_DIR/claude-gateway-token.sh"
[[ ! -f "$SETTINGS" ]] || EXISTING=$(jq -e 'if type == "object" and ((.env // {}) | type == "object") then . else error("Invalid existing Claude settings") end' "$SETTINGS")
MERGED=$(jq --argjson config "$RAW" --arg helper "bash $(printf '%q' "$HELPER")" '
  .env = (.env // {}) |
  del(.forceLoginMethod, .forceLoginOrgUUID, .env.ANTHROPIC_API_KEY, .env.ANTHROPIC_AUTH_TOKEN,
      .env.CLAUDE_CODE_USE_FOUNDRY, .env.ANTHROPIC_FOUNDRY_RESOURCE, .env.ANTHROPIC_FOUNDRY_BASE_URL,
      .env.ANTHROPIC_FOUNDRY_API_KEY, .env.ANTHROPIC_FOUNDRY_AUTH_TOKEN,
      .env.CLAUDE_CODE_USE_BEDROCK, .env.CLAUDE_CODE_USE_VERTEX) |
  .env.ANTHROPIC_BASE_URL = $config.gatewayUrl |
  .env.CLAUDE_CODE_API_KEY_HELPER_TTL_MS = "2700000" |
  .env.ANTHROPIC_DEFAULT_OPUS_MODEL = $config.models.opus |
  .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $config.models.sonnet |
  .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $config.models.haiku |
  .apiKeyHelper = $helper' <<< "$EXISTING")
printf 'Gateway: %s\nSettings: %s\n' "$(jq -r .gatewayUrl <<< "$RAW")" "$SETTINGS"
if [[ "$DRY_RUN" == true ]]; then
  printf 'DRY RUN: validate config, merge settings, create token helper. Install Claude=%s; VS Code=%s; login=%s; smoke=%s; test-only=%s. No writes or network calls.\n' "$INSTALL_CLAUDE" "$INSTALL_VSCODE" "$LOGIN" "$SMOKE_TEST" "$TEST_ONLY"
  exit 0
fi
for ENV_NAME in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_FOUNDRY_RESOURCE ANTHROPIC_FOUNDRY_BASE_URL ANTHROPIC_FOUNDRY_API_KEY ANTHROPIC_FOUNDRY_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX; do
  [[ -z "${!ENV_NAME:-}" ]] || { printf 'Unset inherited %s before setup; it can override gateway settings.\n' "$ENV_NAME" >&2; exit 1; }
done
command -v az >/dev/null || { echo 'Install Azure CLI first (macOS: brew install azure-cli).' >&2; exit 1; }
if [[ "$LOGIN" == true ]]; then az login --tenant "$(jq -r '.gatewaySso.issuerUrl | split("/")[3]' <<< "$RAW")" --scope "$TOKEN_SCOPE" --allow-no-subscriptions --only-show-errors -o none; fi
TOKEN=$(az account get-access-token --tenant "$(jq -r '.gatewaySso.issuerUrl | split("/")[3]' <<< "$RAW")" --resource "$(jq -r '.gatewaySso.scopes | split(" ") | map(select(startswith("api://") or startswith("https://")) | sub("/[^/]+$"; "")) | unique[0]' <<< "$RAW")" --query accessToken --only-show-errors -o tsv)
[[ -n "$TOKEN" ]] || { echo 'No token. Run again with --login.' >&2; exit 1; }
if [[ "$TEST_ONLY" != true ]]; then
  if [[ "$INSTALL_CLAUDE" == true ]]; then npm install -g @anthropic-ai/claude-code; fi
  if [[ "$INSTALL_VSCODE" == true ]]; then code --install-extension anthropic.claude-code; fi
  command -v claude >/dev/null || { echo 'Install Claude Code first or pass --install-claude.' >&2; exit 1; }
  mkdir -p "$HELPER_DIR"
  chmod 700 "$HELPER_DIR"
  BACKUP="$SETTINGS.backup.$(date +%Y%m%d%H%M%S).$$"
  [[ ! -f "$SETTINGS" ]] || cp -p "$SETTINGS" "$BACKUP"
  printf '%s\n' "$RAW" > "$HELPER_DIR/claude-client-configuration.json"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\nCONFIG=%q\n' "$HELPER_DIR/claude-client-configuration.json"
    printf '%s\n' 'TENANT=$(jq -er '\''.gatewaySso.issuerUrl | split("/")[3]'\'' "$CONFIG")' 'RESOURCE=$(jq -er '\''.gatewaySso.scopes | split(" ") | map(select(startswith("api://") or startswith("https://")) | sub("/[^/]+$"; "")) | unique[0]'\'' "$CONFIG")' 'TOKEN=$(az account get-access-token --tenant "$TENANT" --resource "$RESOURCE" --query accessToken --only-show-errors -o tsv)' '[[ -n "$TOKEN" ]] || { echo "No token; run az login for your gateway tenant." >&2; exit 1; }' 'printf "%s\n" "$TOKEN"'
  } > "$HELPER"
  chmod 700 "$HELPER"
  TEMP=$(mktemp "$CLAUDE_DIR/.settings.XXXXXX")
  trap '[[ -z "$TEMP" ]] || rm -f "$TEMP"' EXIT
  printf '%s\n' "$MERGED" > "$TEMP"
  mv "$TEMP" "$SETTINGS"
  printf 'Configured Claude Code. Existing settings backup (when present): %s\n' "$BACKUP"
fi
if [[ "$SMOKE_TEST" == true ]]; then
  BODY=$(jq -cn --arg model "$(jq -r .models.sonnet <<< "$RAW")" '{model:$model,max_tokens:16,messages:[{role:"user",content:"Reply with READY"}]}')
  STATUS=$(curl --silent --show-error --connect-timeout 15 --max-time 90 --output /dev/null --write-out '%{http_code}' \
    "$(jq -r .gatewayUrl <<< "$RAW")/v1/messages" -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' --data "$BODY")
  [[ "$STATUS" == 401 ]] || { printf 'Unauthenticated request: expected 401, got %s\n' "$STATUS" >&2; exit 1; }
  STATUS=$(printf 'header = "x-api-key: %s"\nheader = "Authorization: Bearer dummy"\n' "$TOKEN" | curl --config - --silent --show-error --connect-timeout 15 --max-time 90 --output /dev/null --write-out '%{http_code}' \
    "$(jq -r .gatewayUrl <<< "$RAW")/v1/messages" -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' --data "$BODY")
  [[ "$STATUS" == 200 ]] || { printf 'Authenticated request: expected 200, got %s. Check role assignment, model, quota and backend.\n' "$STATUS" >&2; exit 1; }
  echo 'Smoke tests passed: unauthenticated 401; authenticated inference 200.'
fi
unset TOKEN
echo 'Restart Claude Code / reload VS Code. Organization-managed settings and project settings can override user settings.'