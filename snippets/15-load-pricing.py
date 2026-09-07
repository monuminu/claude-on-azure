#!/usr/bin/env python3
"""Load Claude model prices into PRICING_CL (and, optionally, Redis).

STATUS: VERIFIED 2026-09-04 against the live workspace. One finding changed the design.

THE RETAIL PRICES API DOES NOT LIST CLAUDE. Not under a different name, not in another
region, not under another service. Checked exhaustively:

    serviceName eq 'Foundry Models' and armRegionName eq 'eastus'   -> 1,555 meters,
                                                                       0 mention Claude
    contains(tolower(skuName),'claude')      -> 0 hits, all services, all regions
    contains(tolower(productName),'claude')  -> 0 hits
    contains(tolower(meterName),'claude')    -> 0 hits
    contains(tolower(productName),'anthropic') -> 0 hits

Azure-Samples/AI-Gateway's finops lab pulls OpenAI prices this way and it works, because
those are first-party meters. Claude on Foundry is sold through the Marketplace with
Anthropic as publisher, and Marketplace pricing is not exposed by the retail API. So the
lab's central idea — prices as data rather than as a hardcoded table — survives, but the
source has to be a list you maintain.

That is still a real improvement on what it replaces: the price list used to be a
`datatable` copy-pasted into twenty workbook tiles and every Grafana panel. Now it is one
table, one place to edit, and every consumer reads it.

    pip install azure-identity azure-monitor-ingestion requests redis
    az login

    # Load the built-in list (edit PRICES below to match your agreement).
    python3 15-load-pricing.py --dcr-endpoint https://dcr-....ingest.monitor.azure.com \\
        --dcr-immutable-id dcr-0123456789abcdef

    # Re-check whether Azure has started publishing Claude meters.
    python3 15-load-pricing.py --discover --region eastus

Re-run whenever your pricing changes. A budget enforced against a stale price list is a
budget enforced against fiction.

NOTE ON UNITS. PRICING_CL stores price per 1K tokens, so every consumer divides by 1000.
The workbook's arithmetic was changed to match. The one thing that must not happen is two
consumers disagreeing about the unit — a per-1M price read as per-1K is a 1000x error
that still looks like a plausible number.
"""

import argparse
import json
import sys
from datetime import datetime, timezone

import requests

RETAIL_PRICES = "https://prices.azure.com/api/retail/prices"

# Price per 1,000 tokens, input and output.
#
# THESE ARE ANTHROPIC LIST PRICES. Claude in Microsoft Foundry bills through the Azure
# Marketplace in Claude Consumption Units: Anthropic rates your usage in USD at exactly
# these per-model rates, applies any negotiated discount, and converts at $0.01 per CCU
# (100 CCU = $1.00). So the list price IS the basis of your Azure bill — but a negotiated
# discount, or a US Data Zone Standard deployment (1.1x multiplier), moves it. Reconcile
# against a real invoice before anyone quotes a chargeback number.
#
# Log Analytics has no cache-token columns. Event Hub exposes cache reads, but no
# writes. Keep all five rates here for aggregate reconciliation and future measured
# usage; a price does not make a missing token count observable. PRICING_CL still
# receives only input/output; Redis receives all five rates. See CACHE-TOKEN-ANALYSIS.md.
# Verified against platform.claude.com/docs/en/about-claude/pricing on 2026-09-04.
# Getting these from the model NAME rather than the table is how you end up 3x out:
# $15/$75 is Opus 4.1 and Opus 4, both retired — Opus 5 is $5/$25. Sonnet 5 is $2/$10,
# not the $3/$15 that Sonnet 4.5 and 4.6 use (the introductory $2/$10 became permanent;
# the increase scheduled for 2026-09-01 was cancelled).
# cache_read is 0.1x input for every model here. It is written out rather than derived,
# because the multiplier is NOT universal: Claude Fable 5.1 and Mythos 5.1 read at
# 0.025x. Deriving it would quietly over-charge those two by 4x the day someone adds them.
PRICES = {
    "claude-opus-5":    {"input": 0.005, "output": 0.025, "cache_read": 0.0005,
                         "cache_write_5m": 0.00625, "cache_write_1h": 0.010},
    "claude-opus-4-5":  {"input": 0.005, "output": 0.025, "cache_read": 0.0005,
                         "cache_write_5m": 0.00625, "cache_write_1h": 0.010},
    "claude-sonnet-5":  {"input": 0.002, "output": 0.010, "cache_read": 0.0002,
                         "cache_write_5m": 0.0025, "cache_write_1h": 0.004},
    "claude-haiku-4-5": {"input": 0.001, "output": 0.005, "cache_read": 0.0001,
                         "cache_write_5m": 0.00125, "cache_write_1h": 0.002},
}


def fetch_prices(region: str, currency: str = "USD") -> list[dict]:
    """Every 1K-token meter for Foundry Models in one region, following pagination."""
    items: list[dict] = []
    url = (
        f"{RETAIL_PRICES}?currencyCode='{currency}'"
        f"&$filter=serviceName eq 'Foundry Models'"
        f" and armRegionName eq '{region}'"
    )
    while url:
        resp = requests.get(url, timeout=40)
        resp.raise_for_status()
        payload = resp.json()
        items.extend(payload.get("Items", []))
        url = payload.get("NextPageLink")
    return items


def discover(region: str, currency: str) -> None:
    """Re-test the finding above. If this ever prints Claude meters, switch to them."""
    items = fetch_prices(region, currency)
    if not items:
        print(f"No 'Foundry Models' meters in {region}. Check the region name.", file=sys.stderr)
        sys.exit(1)

    kw = ("claude", "opus", "sonnet", "haiku", "anthropic")
    claude = [i for i in items
              if any(k in (i.get("skuName", "") + i.get("meterName", "") +
                           i.get("productName", "")).lower() for k in kw)]

    print(f"{len(items)} Foundry Models meters in {region}; {len(claude)} mention Claude.\n")
    if not claude:
        print("As expected — Claude is Marketplace-billed and absent from the retail API.")
        print("Keep using the PRICES table in this file.")
        return

    print("Claude meters now published. Switch to them:\n")
    print(f"{'skuName':<44} {'meterName':<38} {'unit':<6} {'per 1K':>10}")
    print("-" * 102)
    for i in sorted(claude, key=lambda x: x.get("skuName", "")):
        print(f"{i.get('skuName',''):<44} {i.get('meterName',''):<38} "
              f"{i.get('unitOfMeasure',''):<6} {i.get('retailPrice',0):>10.6f}")


def build_rows() -> list[dict]:
    now = datetime.now(timezone.utc).isoformat()
    # PRICING_CL carries input/output only, and that is not an omission on the pricing
    # side — it is the sink's limit. The ApiManagementGatewayLlmLog table has no cached
    # token column, so a cache price there would have nothing to multiply. Redis gets the
    # full price set; the processor can apply only input, output and cache_read today.
    return [{
        "TimeGenerated": now,
        "Model": model,
        "InputTokensPrice": p["input"],
        "OutputTokensPrice": p["output"],
    } for model, p in PRICES.items()]


def upload_to_log_analytics(rows, endpoint, immutable_id, stream) -> None:
    from azure.identity import DefaultAzureCredential
    from azure.monitor.ingestion import LogsIngestionClient

    client = LogsIngestionClient(endpoint=endpoint, credential=DefaultAzureCredential())
    client.upload(rule_id=immutable_id, stream_name=stream, logs=rows)
    print(f"Uploaded {len(rows)} rows to {stream}")


def upload_to_redis(rows, redis_host: str, redis_port: int = 6380) -> None:
    """The usage processor prices requests from here, not from Log Analytics.

    Same numbers, different reader: Log Analytics serves the workbook, Redis serves the
    hot path. One loader writes both so they cannot drift — and if you load only one, the
    symptom is quiet. The processor logs "no price for model X", charges zero, and every
    developer looks free.

    Entra auth, not an access key: 16-budget-platform.bicep sets
    disableAccessKeyAuthentication, so there is no key to use even if you wanted one.
    """
    import base64

    import redis
    from azure.identity import DefaultAzureCredential

    token = DefaultAzureCredential().get_token("https://redis.azure.com/.default")
    payload = token.token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    # The username is the caller's object id, not a name. Wrong value here is a flat auth
    # failure that names neither half.
    username = json.loads(base64.urlsafe_b64decode(payload))["oid"]

    client = redis.Redis(
        host=redis_host, port=redis_port, ssl=True,
        username=username, password=token.token,
        decode_responses=True, socket_timeout=10,
    )
    pipe = client.pipeline()
    for model, p in PRICES.items():
        pipe.hset(f"price:{model}", mapping=p)
    pipe.execute()
    print(f"Wrote {len(PRICES)} price hashes (incl. cache_read and both write TTLs) to Redis at {redis_host}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--region", default="eastus", help="armRegionName, only used by --discover")
    p.add_argument("--currency", default="USD")
    p.add_argument("--discover", action="store_true", help="re-check whether Azure publishes Claude meters")
    p.add_argument("--dcr-endpoint", help="logsIngestion endpoint from 14-claude-tiers.bicep")
    p.add_argument("--dcr-immutable-id")
    p.add_argument("--dcr-stream", default="Custom-Json-PRICING_CL")
    p.add_argument("--redis-host", help="e.g. mycache.redis.cache.windows.net (Entra auth, no key)")
    p.add_argument("--redis-port", type=int, default=6380)
    p.add_argument("--dry-run", action="store_true", help="print the rows instead of uploading")
    args = p.parse_args()

    if args.discover:
        discover(args.region, args.currency)
        return

    rows = build_rows()

    if args.dry_run:
        print(json.dumps(rows, indent=2))
        return

    if not (args.dcr_endpoint and args.dcr_immutable_id) and not args.redis_host:
        p.error("give --dcr-endpoint and --dcr-immutable-id, or --redis-host, or --dry-run")

    if args.dcr_endpoint and args.dcr_immutable_id:
        upload_to_log_analytics(rows, args.dcr_endpoint, args.dcr_immutable_id, args.dcr_stream)
    if args.redis_host:
        upload_to_redis(rows, args.redis_host, args.redis_port)


if __name__ == "__main__":
    main()
