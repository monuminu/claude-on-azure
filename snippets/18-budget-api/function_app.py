"""Budget API: is this developer over their monthly dollar budget?

STATUS: RUNNING IN PRODUCTION as of 2026-09-04. Verified end to end: with over:{oid}
set, the gateway returns 403 with x-claude-denied-by: budget within one cache TTL, and
clearing the flag restores access on the same timescale.

One deployment note that is not in this file's control. Easy Auth in front of this app
must set defaultAuthorizationPolicy.allowedApplications to the gateway's managed identity
CLIENT id. Supply a validation block without it and Azure defaults it to an empty array,
which means "allow no application" — every correctly authenticated call then gets a
bodyless 403, and because this endpoint fails open, budgets silently stop being enforced
while everything looks healthy.

The entire contract is a status code:

    GET /v1/budget/{oid}  ->  200  within budget
                              402  over budget
                              anything else, or no answer at all: the gateway treats it
                              as within budget and lets the request through

That last line is the design, not a shortcut. This endpoint sits in the request path of
every Claude call at 100k developers. If it is slow or down, the correct behaviour is to
stop enforcing budgets, not to stop 100k people working — the per-tier token quota in
the gateway policy is still enforcing synchronously the whole time, which is exactly why
that backstop is sized the way it is.

402 rather than a JSON body is deliberate too. The policy reads one integer; there is no
body to parse, no generic type argument to escape into an XML attribute, and a garbled
response cannot accidentally read as "over budget".

WRITES NOTHING. Its Redis grant is Data Reader. Nothing reachable from the request path
can corrupt the ledger it reads.

TEAM GOVERNANCE (v2)

APIM's llm-token-limit / cache-lookup-value machinery allows exactly one cache-lookup-value
per policy section, so once a team budget needed checking too, the choice was between two
sequential HTTP calls per request or one endpoint that answers for both scopes. This is the
one-call version:

    GET /v1/budget/v2/{oid}?teamId=<teamId>   ->  200  body "ok"   neither scope is over
                                                   402  body "user" the USER is over budget
                                                   402  body "team" the TEAM is over budget
                                                   anything else / no answer: within budget,
                                                   same fail-open rule as v1

The policy caches this under `bud:v2:<teamId>:<oid>` (empty teamId string when the caller
has no team) and reads the body only when the status is 402, to set
`x-claude-denied-by: user-budget` or `team-budget` — the ONE place in this design a
response body is parsed, and it is a two-word constant, not anything structured.

`teamId` omitted or empty checks the user scope only and never queries a `team:` key —
there is no team-shaped key to collide with an empty id, but the check is skipped
explicitly rather than relying on that.

v1 is UNCHANGED and stays reachable. It is smaller, still correct for any caller with no
concept of team governance, and removing it would be a breaking change for zero benefit.
"""

import json
import logging
import os
import time

import azure.functions as func
from azure.identity import DefaultAzureCredential
import redis

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)
log = logging.getLogger("budget-api")

REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6380"))

_credential = DefaultAzureCredential()
_redis = None
_redis_expires_at = 0.0


def get_redis():
    """Same token-refresh dance as the processor: the Entra token expires and the
    connection will not renew itself."""
    global _redis, _redis_expires_at
    if _redis is not None and time.time() < _redis_expires_at:
        return _redis

    token = _credential.get_token("https://redis.azure.com/.default")
    username = os.environ.get("AZURE_CLIENT_ID") or _principal_object_id(token.token)
    _redis = redis.Redis(
        host=REDIS_HOST, port=REDIS_PORT, ssl=True,
        username=username, password=token.token,
        decode_responses=True,
        # Under the gateway's 2 second ceiling by a wide margin. Better to give up fast
        # and be treated as "within budget" than to hold a request open.
        socket_timeout=1, socket_connect_timeout=1,
    )
    _redis_expires_at = token.expires_on - 300
    return _redis


def _principal_object_id(jwt: str) -> str:
    import base64
    payload = jwt.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))["oid"]


@app.function_name(name="budget")
@app.route(route="v1/budget/{oid}", methods=["GET"])
def budget(req: func.HttpRequest) -> func.HttpResponse:
    oid = req.route_params.get("oid", "")
    if not oid:
        return func.HttpResponse(status_code=400)

    try:
        over = get_redis().exists(f"over:{oid}")
    except Exception:
        # Fail open, loudly. The log line is the only signal that budgets stopped being
        # enforced — alert on its rate, because the user-visible symptom is nothing at all.
        log.exception("redis unavailable, allowing request for %s", oid)
        return func.HttpResponse(status_code=200)

    if over:
        return func.HttpResponse(status_code=402, body="over")
    return func.HttpResponse(status_code=200, body="ok")


@app.function_name(name="budget_v2")
@app.route(route="v1/budget/v2/{oid}", methods=["GET"])
def budget_v2(req: func.HttpRequest) -> func.HttpResponse:
    oid = req.route_params.get("oid", "")
    if not oid:
        return func.HttpResponse(status_code=400)
    team_id = req.params.get("teamId", "") or ""

    try:
        r = get_redis()
        # User checked first: it is the tighter, always-applicable scope, and a caller
        # denied for being over their OWN budget should never see "team" in the body —
        # that would send an admin investigating the wrong quota.
        user_over = bool(r.exists(f"over:{oid}"))
        team_over = bool(team_id) and bool(r.exists(f"over:team:{team_id}"))
    except Exception:
        # Same fail-open contract as v1, for the same reason: this endpoint is in the
        # request path of every Claude call, and a Redis blip must not become a
        # site-wide outage.
        log.exception("redis unavailable, allowing request for %s (team %s)", oid, team_id)
        return func.HttpResponse(status_code=200, body="ok")

    if user_over:
        return func.HttpResponse(status_code=402, body="user")
    if team_over:
        return func.HttpResponse(status_code=402, body="team")
    return func.HttpResponse(status_code=200, body="ok")


@app.function_name(name="health")
@app.route(route="health", methods=["GET"])
def health(req: func.HttpRequest) -> func.HttpResponse:
    """Distinguishes 'this app is up' from 'this app can reach Redis'. The gateway cannot
    tell the difference — both look like 200 to it — so this is where you look when
    budgets have quietly stopped applying."""
    try:
        get_redis().ping()
        return func.HttpResponse(status_code=200, body="ok")
    except Exception as exc:
        return func.HttpResponse(status_code=503, body=f"redis: {exc}")
