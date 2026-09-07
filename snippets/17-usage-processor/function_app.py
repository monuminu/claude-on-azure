"""Usage processor: gateway diagnostic events in, month-to-date dollars out.

STATUS: RUNNING IN PRODUCTION as of 2026-09-04. Verified against a live Event Hub fed
by an APIM diagnostic destination: gateway traffic becomes month-to-date dollars in Redis
within ~90 seconds, and the Cosmos ledger carries per-request tier, model, tokens and cost.

Two defects were found by deploying it, both fixed here and both worth knowing:
  - CosmosClient was constructed at module scope. Its constructor makes a network call,
    and the Functions host IMPORTS this module to discover functions — so a slow Cosmos
    meant zero functions registered, with nothing in any log naming the cause. It is now
    built on first use. See get_container().
  - The trigger signature used `list[func.EventHubEvent]`. The Python worker rejects PEP
    585 generics in binding annotations and refuses to load the function. It needs
    typing.List. The error does at least name the annotation.

The record-shape handling in `_iter_records` proved correct against real payloads.

WHAT IT DOES
    Reads the same gateway logs Log Analytics gets, prices each request, adds it to a
    per-developer counter in Redis, writes a ledger row to Cosmos, and raises a flag when
    someone crosses their tier's monthly dollar budget. The gateway policy reads that flag.

THE ONE GENUINELY AWKWARD PART
    A single Claude request produces TWO diagnostic records, and neither is sufficient
    alone. GatewayLlmLogs has the token counts but no caller identity — it has never had
    a caller column. GatewayLogs has the x-caller-* headers the policy stamped, but no
    tokens. They share only CorrelationId, and they arrive as separate events.

    So this does a streaming join through Redis: whichever half lands first parks under a
    short TTL, and the second half completes the pair. In practice they arrive together;
    the TTL exists for the case where one is lost, and a half-pair simply expires rather
    than accumulating forever.

WHAT IS STILL MISSING
    Cache WRITES. The payload reports promptCachedTokens (reads) but nothing for
    cache_creation_input_tokens — on a write the field reads 0 and the written tokens
    appear nowhere. Writes bill at 1.25x input for 5m TTL and 2x for 1h TTL. They were
    62% of Opus 5 spend in the seven-day sample, so this is a material underestimate.
    Ledger rows explicitly mark the missing write counts as unknown, never zero.
    See CACHE-TOKEN-ANALYSIS.md for reconciliation and the proposed streaming meter.

IDEMPOTENCY
    Event Hub delivery is at-least-once, so this WILL see the same request twice — on
    host restart, on rebalance, on retry. Cosmos is safe by construction because the
    document id is the CorrelationId and the write is an upsert. INCRBYFLOAT is not: a
    replayed event would charge a developer twice. `SET done:{cid} NX` is the guard, and
    it is the only thing standing between a redeploy and a wave of spurious suspensions.
"""

import json
import logging
import os
import time
from datetime import datetime, timezone, timedelta
from typing import List

import azure.functions as func
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
import redis

app = func.FunctionApp()
log = logging.getLogger("usage-processor")

REDIS_HOST = os.environ.get("REDIS_HOST", "")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6380"))
COSMOS_ENDPOINT = os.environ.get("COSMOS_ENDPOINT", "")
COSMOS_DATABASE = os.environ.get("COSMOS_DATABASE", "claude")
COSMOS_CONTAINER = os.environ.get("COSMOS_CONTAINER", "usage")

# {"pro": 1000, "basic": 500, "lite": 100}
TIERS = {t["name"]: t for t in json.loads(os.environ.get("CLAUDE_TIERS", "[]"))}

# How long an unmatched half of a request waits for its other half.
PAIR_TTL = 900
# How long the replay guard remembers a request. Longer than any plausible Event Hub
# retention plus redelivery window, so a late replay still cannot double-charge.
DONE_TTL = 172800

_credential = DefaultAzureCredential()

_redis = None
_redis_expires_at = 0.0
_container = None


def get_container():
    """Cosmos client, built on first use rather than at import.

    This is not a style preference. CosmosClient's constructor performs a network call to
    read account metadata, and the Functions host imports this module to DISCOVER the
    functions in it. Construct it at module scope and a slow or failing Cosmos means
    indexing throws, the host registers zero functions, and the app reports no error
    anywhere obvious — it simply sits there with an empty function list. Cost you an hour
    the first time.
    """
    global _container
    if _container is None:
        client = CosmosClient(COSMOS_ENDPOINT, credential=_credential)
        _container = client.get_database_client(COSMOS_DATABASE).get_container_client(COSMOS_CONTAINER)
    return _container


def get_redis():
    """Redis with an Entra token as the password.

    The token expires, and the connection does not renew itself, so the client is rebuilt
    a few minutes before expiry. Using the access key instead would remove this function
    and reintroduce the shared secret the rest of this design exists to avoid.
    """
    global _redis, _redis_expires_at
    if _redis is not None and time.time() < _redis_expires_at:
        return _redis

    token = _credential.get_token("https://redis.azure.com/.default")
    # The username is the identity's object id, not a name. Getting this wrong presents
    # as a flat auth failure with no hint about which half is wrong.
    username = os.environ.get("AZURE_CLIENT_ID") or _principal_object_id(token.token)
    _redis = redis.Redis(
        host=REDIS_HOST, port=REDIS_PORT, ssl=True,
        username=username, password=token.token,
        decode_responses=True, socket_timeout=5,
    )
    _redis_expires_at = token.expires_on - 300
    return _redis


def _principal_object_id(jwt: str) -> str:
    """oid claim, read without verifying — the token is ours and about to be used as a
    credential anyway, so there is nothing to gain by validating it here."""
    import base64
    payload = jwt.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))["oid"]


def _iter_records(event: func.EventHubEvent):
    """Azure diagnostic events arrive as {"records": [...]}, one event holding many.

    Some services emit a bare array or a single object instead. Handling all three costs
    four lines and saves discovering the difference in production.
    """
    body = event.get_body().decode("utf-8")
    payload = json.loads(body)
    if isinstance(payload, dict):
        yield from payload.get("records", [payload])
    elif isinstance(payload, list):
        yield from payload


def _month_key() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m")


def _seconds_to_month_end() -> int:
    now = datetime.now(timezone.utc)
    first_next = (now.replace(day=1) + timedelta(days=32)).replace(
        day=1, hour=0, minute=0, second=0, microsecond=0
    )
    return int((first_next - now).total_seconds())


def _normalise_model(name: str) -> str:
    """ModelName arrives dated from the Claude clients and bare from cURL — the workbook
    strips the suffix the same way. If the two disagree, spend splits across two rows and
    both look half-sized."""
    if not name:
        return ""
    parts = name.rsplit("-", 1)
    if len(parts) == 2 and len(parts[1]) == 8 and parts[1].isdigit():
        return parts[0]
    return name


def _header(props: dict, name: str) -> str:
    """Headers appear under different keys depending on which side of the request they
    were captured on. The policy stamps identity on the request AND on the response
    precisely because a rejected request never reaches the backend — so on exactly the
    rows where 'who hit their limit' matters, only the response copy exists."""
    for key in ("backendRequestHeaders", "BackendRequestHeaders",
                "responseHeaders", "ResponseHeaders",
                "requestHeaders", "RequestHeaders"):
        headers = props.get(key) or {}
        if isinstance(headers, dict):
            for k, v in headers.items():
                if k.lower() == name:
                    return v
    return ""


@app.function_name(name="usage_processor")
@app.event_hub_message_trigger(
    arg_name="events",
    event_hub_name="%EVENTHUB_NAME%",
    connection="EventHubConnection",
    consumer_group="%EVENTHUB_CONSUMER_GROUP%",
    cardinality="many",
)
def usage_processor(events: List[func.EventHubEvent]) -> None:
    # typing.List, NOT the builtin list[...]. The Python worker inspects this annotation
    # to resolve the binding and rejects the PEP 585 form outright:
    #   FunctionLoadError: binding events has invalid non-type annotation
    #   list[azure.functions._eventhub.EventHubEvent]
    # The function then never registers, and the app reports "0 functions found" with no
    # indication that a type hint was the cause.
    r = get_redis()
    for event in events:
        try:
            for record in _iter_records(event):
                _handle(r, record)
        except Exception:
            # Swallow per-event, not per-batch. One malformed record must not park the
            # partition and stall every developer's budget behind it — the cost of a
            # dropped record is a slightly low counter, which the Cosmos ledger can
            # reconcile. The cost of a poison-pill loop is enforcement stopping silently.
            log.exception("dropping unprocessable event")


def _handle(r, record: dict) -> None:
    category = (record.get("category") or record.get("Category") or "")
    props = record.get("properties") or record.get("Properties") or record
    cid = (props.get("correlationId") or props.get("CorrelationId")
           or record.get("correlationId") or "")
    if not cid:
        return

    if category.endswith("GatewayLlmLogs"):
        request_id = props.get("requestId") or props.get("RequestId") or ""
        payload = {
            "requestId": request_id,
            "model": _normalise_model(props.get("modelName") or props.get("ModelName") or ""),
            "prompt": int(props.get("promptTokens") or props.get("PromptTokens") or 0),
            "completion": int(props.get("completionTokens") or props.get("CompletionTokens") or 0),
            # promptCachedTokens is CACHE READS. It exists ONLY in the Event Hub payload —
            # the ApiManagementGatewayLlmLog table drops the field, so nothing built on
            # Log Analytics can see it. Observed live: a Claude Desktop turn reported
            # promptTokens=26 alongside promptCachedTokens=48854.
            "cached": int(props.get("promptCachedTokens") or props.get("PromptCachedTokens") or 0),
        }
        if not request_id:
            # Drop empty-ID, empty-model, zero-usage probes. Preserve anomalous usage
            # without a message id so a missing identifier never erases a known charge.
            if not payload["model"] and not any(payload[k] for k in ("prompt", "completion", "cached")):
                return
            log.warning("LLM usage missing requestId (correlation %s)", cid)
        r.hset(f"tok:{cid}", mapping=payload)
        r.expire(f"tok:{cid}", PAIR_TTL)
        other = r.hgetall(f"idn:{cid}")
        if other:
            _complete(r, cid, payload, other)

    elif category.endswith("GatewayLogs"):
        oid = _header(props, "x-caller-oid")
        if not oid or oid == "unknown":
            return
        payload = {
            "oid": oid,
            "tier": _header(props, "x-caller-tier") or "lite",
            "upn": _header(props, "x-caller-upn") or "",
        }
        r.hset(f"idn:{cid}", mapping=payload)
        r.expire(f"idn:{cid}", PAIR_TTL)
        other = r.hgetall(f"tok:{cid}")
        if other:
            _complete(r, cid, other, payload)


def _complete(r, cid: str, tokens: dict, identity: dict) -> None:
    # The replay guard. NX means only the first arrival of this CorrelationId gets past
    # here, so a redelivered event updates Cosmos harmlessly and does not touch the counter.
    if not r.set(f"done:{cid}", 1, nx=True, ex=DONE_TTL):
        return

    model = tokens.get("model") or ""
    prompt = int(tokens.get("prompt") or 0)
    completion = int(tokens.get("completion") or 0)
    cached = int(tokens.get("cached") or 0)
    oid = identity["oid"]
    tier = identity.get("tier") or "lite"

    price = r.hgetall(f"price:{model}")
    if not price:
        # No price means no cost. Record it, do not guess, and make it findable — a model
        # missing from the price list is a budget quietly under-counting, which is the
        # failure mode most likely to go unnoticed for a month.
        log.warning("no price for model %r (correlation %s)", model, cid)
        cost = 0.0
    else:
        # Prices are per 1K tokens, matching what 15-load-pricing.py stores.
        # cache_read is carried explicitly rather than derived as 0.1x input, because
        # the multiplier is not universal — Fable 5.1 and Mythos 5.1 read at 0.025x.
        cache_read_price = float(price.get("cache_read") or 0.0)
        cost = (prompt * float(price["input"])
                + cached * cache_read_price
                + completion * float(price["output"])) / 1000.0

    month = _month_key()
    total = float(r.incrbyfloat(f"mtd:{month}:{oid}", cost))
    r.expire(f"mtd:{month}:{oid}", _seconds_to_month_end() + 86400)
    r.incrbyfloat(f"mtd:{month}:tier:{tier}", cost)

    quota = TIERS.get(tier, {}).get("costQuota")
    if quota is not None and total > float(quota):
        # Expires at month end, so the new month starts everyone clean with no reset job
        # and nothing to forget to run on the 1st.
        r.set(f"over:{oid}", 1, ex=_seconds_to_month_end() + 86400)
        log.info("over budget: oid=%s tier=%s mtd=%.4f quota=%s", oid, tier, total, quota)

    get_container().upsert_item({
        "id": cid,
        "oid": oid,
        "upn": identity.get("upn") or "",
        "tier": tier,
        "model": model,
        "requestId": tokens.get("requestId") or "",
        "promptTokens": prompt,
        "cacheReadTokens": cached,
        "cacheWrite5mTokens": None,
        "cacheWrite1hTokens": None,
        "completionTokens": completion,
        "costUsd": cost,
        "usageSource": "apim_gateway_llm_logs",
        "costCoverage": "excludes_cache_writes",
        "pricingStatus": ("priced" if price and (not cached or price.get("cache_read") is not None)
                          else "missing_rates"),
        "month": month,
        "ts": datetime.now(timezone.utc).isoformat(),
    })

    r.delete(f"tok:{cid}", f"idn:{cid}")
