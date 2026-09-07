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
