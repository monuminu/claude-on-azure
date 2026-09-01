#!/usr/bin/env bash
# Smoke test for the APIM gateway in front of Claude on Microsoft Foundry.
#
# STATUS: VERIFIED 2026-09-01 against a live BasicV2 gateway. Cases 1-4 all behaved
# as written; see Findings 14-16 in TEST-LOG.md.
#
# NOTE on API_APP_ID: for an app registration with requestedAccessTokenVersion 2 the
# token's aud is the BARE application ID, not api://<guid>. Pass whichever your app
# actually issues - decode a token and look.
#
#   GATEWAY=https://<apim>.azure-api.net/anthropic \
#   API_APP_ID=api://<application-id-uri> \
#   ./05-gateway-smoke-test.sh

set -uo pipefail   # deliberately not -e: the negative cases are expected to fail

GATEWAY="${GATEWAY:?set GATEWAY to the APIM route, e.g. https://apim.azure-api.net/anthropic}"
API_APP_ID="${API_APP_ID:?set API_APP_ID to the Application ID URI of the API app registration}"
MODEL="${MODEL:-claude-opus-5}"

BODY='{"model":"'"$MODEL"'","max_tokens":64,
       "messages":[{"role":"user","content":"Reply with exactly: through the gateway."}]}'

# The audience matters. This token'\''s aud is API_APP_ID — the same value the policy
# lists under <audiences>. A token minted for https://ai.azure.com will be rejected
# by the gateway even though it would work against Foundry directly.
TOK=$(az account get-access-token --resource "$API_APP_ID" --query accessToken -o tsv)

echo "== 1. valid token, correct app role -> expect 200 =="
curl -s -w "\nHTTP:%{http_code}\n" "$GATEWAY/v1/messages" \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d "$BODY" -D /tmp/gw-headers.txt

echo "== token accounting headers returned by llm-token-limit =="
# Compare x-tokens-consumed against Foundry's own usage metrics. Under streaming
# these counts are estimates, and the docs describe the estimation only in OpenAI
# terms — the Anthropic SSE behaviour is unknown until measured.
grep -iE '^x-tokens-(consumed|remaining)' /tmp/gw-headers.txt || echo "(none returned)"

echo "== 2. no token -> expect the policy'\''s failed-validation-httpcode (401) =="
curl -s -o /dev/null -w "HTTP:%{http_code}\n" "$GATEWAY/v1/messages" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d "$BODY"

echo "== 3. wrong audience -> expect 401 =="
# A Foundry-scoped token. Valid, signed by the same tenant, wrong aud.
WRONG=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
curl -s -o /dev/null -w "HTTP:%{http_code}\n" "$GATEWAY/v1/messages" \
  -H "Authorization: Bearer $WRONG" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d "$BODY"

echo "== 4. streaming passes through incrementally (buffer-response=false) =="
# Events should arrive as they are produced. If they all land at once, response
# buffering is still on somewhere in the policy chain.
curl -sN "$GATEWAY/v1/messages" \
  -H "Authorization: Bearer $TOK" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"'"$MODEL"'","max_tokens":256,"stream":true,
       "messages":[{"role":"user","content":"Count slowly from 1 to 20."}]}' \
  | head -20

# Case 5 has no curl equivalent: a token for a user who is NOT assigned the
# Claude.User app role should return 401 from required-claims. Mint it as that user.
echo "== done. Record each result in TEST-LOG.md, including anything unexpected. =="
