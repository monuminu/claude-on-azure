#!/usr/bin/env bash
# Tier and budget smoke test. Extends 05-gateway-smoke-test.sh, which covers the auth
# cases; this one covers everything added by TIERED-QUOTAS.md.
#
# STATUS: NOT RUN. Written against the design, not against a deployment.
#
#   GATEWAY=https://<apim>.azure-api.net/anthropic \
#   API_APP_ID=<application-id> \
#   ./19-tier-smoke-test.sh
#
# WHAT TO SET UP FIRST. Most of these cases need more than one identity, because the
# whole point is that two developers get different treatment:
#
#   a test account in Claude.Tier.Pro
#   a test account in Claude.Tier.Lite
#   a test account with Claude.User and NO tier role   (should behave as Lite)
#
# Sign in as each in turn, or mint tokens for each and set TOK_PRO / TOK_LITE / TOK_NONE.

set -uo pipefail   # not -e: several cases are expected to fail

GATEWAY="${GATEWAY:?set GATEWAY, e.g. https://apim.azure-api.net/anthropic}"
API_APP_ID="${API_APP_ID:?set API_APP_ID to the application ID of the gateway app registration}"
MODEL="${MODEL:-claude-haiku-4-5}"

TOK="${TOK:-$(az account get-access-token --resource "$API_APP_ID" --query accessToken -o tsv)}"

BODY='{"model":"'"$MODEL"'","max_tokens":32,
       "messages":[{"role":"user","content":"Reply with exactly: ok."}]}'

hdr() { grep -iE "^$1:" /tmp/tier-headers.txt | tr -d '\r' | sed "s/^$1: *//I"; }

call() {
  curl -s -o /tmp/tier-body.txt -D /tmp/tier-headers.txt -w "%{http_code}" \
    "$GATEWAY/v1/messages" \
    -H "Authorization: Bearer ${1}" \
    -H "content-type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -d "$BODY"
}

echo "== 0. what tier does the gateway think you are? =="
# The token is the source of truth for the tier, so read it from the token rather than
# from the gateway. If these two ever disagree, the policy's precedence logic is wrong.
python3 - "$TOK" <<'PY'
import base64, json, sys
payload = sys.argv[1].split(".")[1]
payload += "=" * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
roles = claims.get("roles", [])
print("  oid   :", claims.get("oid"))
print("  upn   :", claims.get("preferred_username"))
print("  roles :", roles or "(none — the gateway will treat you as Lite)")
tier = ("pro" if "Claude.Tier.Pro" in roles
        else "basic" if "Claude.Tier.Basic" in roles else "lite")
print("  tier  :", tier, "(suspended)" if "Claude.Suspended" in roles else "")
PY

echo
echo "== 1. a normal call carries the tier back on the response =="
# x-caller-tier on a 200 proves the outbound stamp works. It has to be present here AND
# on a rejection — see case 3, which is the one that actually matters.
code=$(call "$TOK")
echo "  HTTP:$code  x-caller-tier: $(hdr x-caller-tier)  x-caller-oid: $(hdr x-caller-oid)"
echo "  tokens consumed: $(hdr x-tokens-consumed)  quota remaining: $(hdr x-quota-remaining)"
[ "$code" = "200" ] || echo "  !! expected 200"

echo
echo "== 2. GET /v1/models answers without touching the budget API =="
# Served from the policy before the budget check, so a Claude Desktop launch probe does
# not cost a callout — and a suspended developer's client still starts up cleanly.
curl -s -o /dev/null -w "  HTTP:%{http_code}\n" "$GATEWAY/v1/models" -H "Authorization: Bearer $TOK"

echo
echo "== 3. burst past tokens-per-minute -> expect 429, WITH identity attached =="
# The important assertion is not the 429. It is that x-caller-tier and x-caller-oid come
# back on it. A throttled request never reaches the backend, so those headers can only
# have come from the on-error section — which is exactly the row where "who hit their
# limit" is the question you are asking.
BIG='{"model":"'"$MODEL"'","max_tokens":4096,
      "messages":[{"role":"user","content":"Write a very long essay about queueing theory."}]}'
got429=0
for i in $(seq 1 12); do
  code=$(curl -s -o /dev/null -D /tmp/tier-headers.txt -w "%{http_code}" \
    "$GATEWAY/v1/messages" -H "Authorization: Bearer $TOK" \
    -H "content-type: application/json" -H "anthropic-version: 2023-06-01" -d "$BIG")
  if [ "$code" = "429" ]; then
    got429=1
    echo "  429 on attempt $i"
    echo "    retry-after  : $(hdr retry-after)"
    echo "    x-caller-tier: $(hdr x-caller-tier)   <- must not be empty"
    echo "    x-caller-oid : $(hdr x-caller-oid)    <- must not be empty"
    break
  fi
done
[ "$got429" = "1" ] || echo "  no 429 in 12 attempts. Either the tier's TPM is high, or the"
[ "$got429" = "1" ] || echo "  token bucket refilled faster than the debit — lower tier-*-tpm and retry."

echo
echo "== 4. the three rejection reasons are distinguishable =="
# One 403 means "you have spent your money", another means "an admin stopped you", and a
# third means "you burned the token backstop". Without x-claude-denied-by they are the
# same row in the log and nobody can triage them.
echo "  x-claude-denied-by on the last response: '$(hdr x-claude-denied-by)'"
echo "  (empty on 200/429; 'budget' or 'admin' on the two return-response rejections)"

echo
echo "== 5. budget enforcement, end to end =="
cat <<'STEPS'
  Not scriptable from here — it spans Redis and Entra. Run it by hand:

  a. Set the Lite tier's costQuota to 0.01 and redeploy infra/16-budget-platform.bicep.
  b. Make one Lite call. Within a few seconds:
       redis-cli -h <host> --tls GET mtd:$(date -u +%Y%m):<oid>     -> a small number
       redis-cli -h <host> --tls EXISTS over:<oid>                  -> 1
  c. Within 30s (the policy's cache TTL) the next call returns
       403 with x-claude-denied-by: budget
  d. Raise the quota, DEL over:<oid>, wait out the cache, confirm 200 returns.

  Then the case that actually matters, because it is the one that bites in production:

  e. FAIL-OPEN. Stop the budget API. Confirm calls still return 200, not 403.
     Then stop Redis too. Same. 100k developers must not be blocked by a
     dependency that only decides how they are billed. `curl <budget-api>/health`
     should be the only thing reporting the fault.

  f. SUSPENSION. Add the account to the Claude.Suspended group. Confirm the CURRENT
     token still works — group membership is not a CAE trigger, so it applies on the
     next token, not this one. Then mint a fresh token and confirm
     403 with x-claude-denied-by: admin.
STEPS

echo
echo "== 6. reconcile the three views of the same number =="
cat <<'STEPS'
  Redis, Cosmos and the workbook are three independent paths to one figure. If they
  disagree, one of them is wrong and you do not yet know which:

    redis-cli GET mtd:<yyyymm>:<oid>

    SELECT VALUE SUM(c.costUsd) FROM c
    WHERE c.oid = '<oid>' AND c.month = '<yyyymm>'

    -- workbook, Models & cost tab, "Estimated cost per developer, per model"
STEPS

echo
echo "== done. =="
