#!/usr/bin/env bash
# Claude Code apiKeyHelper: mint a short-lived per-user Entra ID access token
# for the APIM gateway. Referenced from managed-settings.json as
#   "apiKeyHelper": "/usr/local/bin/claude-gateway-token"
#
# STATUS: VERIFIED 2026-09-01. Drove Claude Code through a live APIM gateway end to
# end. IMPORTANT: Claude Code sends this output in the x-api-key header AND sends a
# literal "Authorization: Bearer dummy" alongside it - your gateway policy must
# override Authorization when x-api-key is present.
#
# Contract, and it is strict:
#   - print ONLY the credential to stdout, nothing else
#   - a banner, prompt, or stray log line makes the helper fail
#   - exit non-zero, time out, or print nothing and requests fail after 3 attempts
#   - a warning banner appears if this takes longer than 10 seconds
#
# The audience must match the <audiences> entry in the APIM policy. A token
# scoped to https://ai.azure.com works against Foundry directly but is rejected
# by the gateway.

set -euo pipefail

API_APP_ID="${CLAUDE_GATEWAY_API_APP_ID:-api://REPLACE-WITH-APPLICATION-ID-URI}"

# --only-show-errors keeps CLI upgrade notices off stdout. 2>/dev/null is not
# enough on its own, because some az builds write notices to stdout.
az account get-access-token \
  --resource "$API_APP_ID" \
  --query accessToken \
  --only-show-errors \
  -o tsv
