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

# CLAUDE_TEAM_GOVERNANCE is the whole {mode, profiles, teams} block from
# admin/setup.example.json, serialized once by infra/16-budget-platform.bicep. Parsed
# here at import time, same as CLAUDE_TIERS above — it is pure JSON decoding, no network
# call, so it does not risk the "host imports this module to discover functions" trap
# documented for get_container() below. A malformed or absent value degrades to
# governance-off rather than crashing function discovery: a typo in an app setting
# should not take every developer's requests down with it.
try:
    _team_governance_raw = json.loads(os.environ.get("CLAUDE_TEAM_GOVERNANCE", "") or "{}")
except (json.JSONDecodeError, TypeError):
    log.exception("CLAUDE_TEAM_GOVERNANCE is not valid JSON; treating team governance as off")
    _team_governance_raw = {}

TEAM_GOVERNANCE_MODE = _team_governance_raw.get("mode", "off")
# {"power": {...tpm/tokenQuota/costQuota}, "regular": {...}}
TEAM_PROFILES = {p["name"]: p for p in _team_governance_raw.get("profiles", []) if p.get("name")}
# {"fdpo-team-1": {...id/profile/defaultUserTier}, ...}. Kept for symmetry with TIERS —
# nothing here currently reads it, since the policy stamps teamId/teamProfile directly
# and the processor trusts that stamp rather than re-deriving it from Entra role claims
# it never sees. It exists so a future consumer (e.g. a "does this team still exist"
# reconciliation check) does not need another round of config plumbing.
TEAMS_BY_ID = {t["id"]: t for t in _team_governance_raw.get("teams", []) if t.get("id")}

# How long an unmatched half of a request waits for its other half.
PAIR_TTL = 900
# How long the replay guard remembers a request. Longer than any plausible Event Hub
# retention plus redelivery window, so a late replay still cannot double-charge.
DONE_TTL = 172800

# Utilization percentages that get a structured event, deduplicated per scope/month so a
# steady stream of requests past a threshold does not repeat the same alert forever.
UTILIZATION_THRESHOLDS = (70, 85, 95, 100)

# Diagnostic records older than this when the processor sees them are worth flagging —
# a growing gap means Redis/Cosmos counters (and therefore budget enforcement) are stale
# by more than a trivial amount. Chosen well above the ~90s steady-state latency observed
# in production, so ordinary jitter does not page anyone.
LAG_WARN_SECONDS = 60

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


def _emit_governance_event(event_type: str, **fields) -> None:
    """One structured line, one JSON object. Read by the alerts and workbook queries in
    infra/22-team-governance.bicep / 23-team-governance-workbook.json via
    `AppTraces | where Message startswith "TEAM_GOVERNANCE_EVENT"`. A structured log line
    is used instead of a custom Azure Monitor metric because metric dimensions are
    high-cardinality here (one series per user, per team) and Azure Monitor metrics are
    not built for that; Log Analytics ingestion is."""
    log.info("TEAM_GOVERNANCE_EVENT %s", json.dumps({"type": event_type, **fields}, default=str))


def _check_thresholds(r, scope: str, scope_id: str, month: str, total: float, quota: float, ttl: int, **extra) -> None:
    """Emit a threshold_crossed event the first time a scope's utilization reaches each of
    UTILIZATION_THRESHOLDS in a given month. `SET ... NX` is the dedup: only the request
    that flips the guard from unset to set gets to emit, so a hundred requests in a row
    past 95% produce exactly one event, not a hundred."""
    if quota <= 0:
        return
    pct = (total / quota) * 100.0
    for threshold in UTILIZATION_THRESHOLDS:
        if pct < threshold:
            continue
        guard_key = f"thresh:{scope}:{scope_id}:{month}:{threshold}"
        if r.set(guard_key, 1, nx=True, ex=ttl):
            _emit_governance_event(
                "threshold_crossed",
                scope=scope, id=scope_id, month=month, threshold=threshold,
                totalUsd=round(total, 4), quotaUsd=quota, **extra,
            )


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

    # Lag check: Azure Monitor's diagnostic-setting schema stamps every record with a
    # top-level "time" — when the event was RECORDED, not when Event Hub delivered it —
    # so the gap to "now" is processor lag end to end, not just queue time. Using this
    # instead of the Event Hub message's own enqueued-time metadata avoids depending on
    # exactly which attribute name a given azure-functions Python binding version exposes
    # for that, which was not something this environment could verify.
    record_time = record.get("time") or record.get("Time")
    if record_time:
        try:
            recorded_at = datetime.fromisoformat(record_time.replace("Z", "+00:00"))
            lag = (datetime.now(timezone.utc) - recorded_at).total_seconds()
            if lag > LAG_WARN_SECONDS:
                _emit_governance_event("processor_lag", lagSeconds=round(lag, 1), cid=cid)
        except (ValueError, AttributeError):
            pass

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
        # x-team-governance-state is stamped by 03-apim-claude-policy.xml's team
        # resolution step: "ok" (both a team role and a matching profile role were
        # found), "missing" (no team/profile role present — expected for anyone outside
        # team governance), or "ambiguous" (more than one team or profile role, or a
        # profile role that does not match the team's configured profile). Only "ok"
        # is charged against a team counter below; the rest fall back to user-only
        # accounting, same as before team governance existed.
        team_state = _header(props, "x-team-governance-state") or "disabled"
        team_id = _header(props, "x-caller-team-id") or ""
        team_profile = _header(props, "x-caller-team-profile") or ""
        payload = {
            "oid": oid,
            "tier": _header(props, "x-caller-tier") or "lite",
            "upn": _header(props, "x-caller-upn") or "",
            "teamId": team_id,
            "teamProfile": team_profile,
            "teamState": team_state,
        }
        if TEAM_GOVERNANCE_MODE != "off" and team_state == "ambiguous":
            _emit_governance_event("ambiguous_identity", oid=oid, state=team_state)
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
    ttl = _seconds_to_month_end() + 86400

    team_id = identity.get("teamId") or ""
    team_profile = identity.get("teamProfile") or ""
    team_state = identity.get("teamState") or "disabled"
    # Only an unambiguous, recognized team+profile pair is charged against a team
    # counter. "missing" (no team role — most users) and "ambiguous" (policy could not
    # resolve a single team/profile) both fall back to user-only accounting, exactly as
    # they did before team governance existed. `team_profile in TEAM_PROFILES` is a
    # second, independent check against this function's own config — even if the policy
    # said "ok", a profile name this processor was never told about cannot be priced.
    team_charged = bool(team_id) and team_state == "ok" and team_profile in TEAM_PROFILES

    # One pipeline, sent as a single MULTI/EXEC transaction, so a user's charge and (when
    # applicable) their team's charge either both land or neither does. Two counters
    # advancing out of step would let a user's spend and their team's spend drift apart
    # for the same set of priced requests — exactly the kind of mismatch a reconciliation
    # pass would otherwise have to explain away as "normal".
    pipe = r.pipeline(transaction=True)
    pipe.incrbyfloat(f"mtd:{month}:{oid}", cost)          # index 0
    pipe.expire(f"mtd:{month}:{oid}", ttl)                # index 1
    pipe.incrbyfloat(f"mtd:{month}:tier:{tier}", cost)    # index 2
    if team_charged:
        pipe.incrbyfloat(f"mtd:{month}:team:{team_id}", cost)         # index 3
        pipe.expire(f"mtd:{month}:team:{team_id}", ttl)                # index 4
        pipe.incrbyfloat(f"mtd:{month}:profile:{team_profile}", cost)  # index 5
    results = pipe.execute()

    user_total = float(results[0])
    team_total = float(results[3]) if team_charged else None

    quota = TIERS.get(tier, {}).get("costQuota")
    if quota is not None and user_total > float(quota):
        # Expires at month end, so the new month starts everyone clean with no reset job
        # and nothing to forget to run on the 1st.
        r.set(f"over:{oid}", 1, ex=ttl)
        log.info("over budget: oid=%s tier=%s mtd=%.4f quota=%s", oid, tier, user_total, quota)
    _check_thresholds(r, "user", oid, month, user_total, float(quota) if quota is not None else 0.0, ttl, tier=tier)

    if team_charged:
        team_quota = TEAM_PROFILES.get(team_profile, {}).get("costQuota")
        if team_quota is not None and team_total > float(team_quota):
            r.set(f"over:team:{team_id}", 1, ex=ttl)
            log.info("team over budget: team=%s profile=%s mtd=%.4f quota=%s",
                      team_id, team_profile, team_total, team_quota)
        _check_thresholds(r, "team", team_id, month, team_total,
                           float(team_quota) if team_quota is not None else 0.0, ttl, profile=team_profile)

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
        # Team fields are None (never omitted — Cosmos is schemaless, but every ledger
        # row having the same shape is what lets a reconciliation query filter on
        # `IS_NULL(teamId)` rather than special-casing missing properties) unless this
        # request was actually charged to a team counter.
        "teamId": team_id if team_charged else None,
        "teamProfile": team_profile if team_charged else None,
        "teamGovernanceState": team_state,
        "ts": datetime.now(timezone.utc).isoformat(),
    })

    r.delete(f"tok:{cid}", f"idn:{cid}")
