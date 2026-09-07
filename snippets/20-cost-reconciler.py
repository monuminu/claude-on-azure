#!/usr/bin/env python3
"""Price Foundry cache metrics per model and roll them into ClaudeCostRollup_CL.

WHY THIS EXISTS. ApiManagementGatewayLlmLog carries prompt/completion tokens and nothing
else. It has no cache columns, and neither does the GatewayLlmLogs Event Hub payload
beyond cache READS. Cache WRITES — billed at 1.25x input for 5m TTL and 2x for 1h — are
reported by no APIM surface at all. On measured traffic they were 62% of Claude spend, so
cost built on the log alone under-reports by roughly 2.6x. See CACHE-TOKEN-ANALYSIS.md.

Azure Monitor does expose them, as Anthropic-specific metrics on the Foundry account:
cacheReadInputTokens, ephemeral5mInputTokens, ephemeral1hInputTokens. Verified exact to
the token against wire usage.

    pip install azure-identity azure-monitor-ingestion requests
    az login

    # See what it would write, without writing it.
    python3 20-cost-reconciler.py --resource-id /subscriptions/.../accounts/monuminu --dry-run

    # Roll up the last 24h into the workspace.
    python3 20-cost-reconciler.py --resource-id /subscriptions/.../accounts/monuminu \\
        --hours 24 \\
        --dcr-endpoint https://dcr-....ingest.monitor.azure.com \\
        --dcr-immutable-id dcr-0123456789abcdef

TWO THINGS THAT LOOK LIKE THEY SHOULD WORK AND DO NOT.

1. You cannot read this from the AzureMetrics table. Exporting AllMetrics to a workspace
   via a diagnostic setting DOES deliver these metrics, but the export FLATTENS
   DIMENSIONS — there is no ModelName column, only resource-level totals. Opus, Sonnet
   and Haiku bill at different rates, so a resource-level total cannot be priced. This
   script therefore reads the Metrics API with ModelName splitting, which keeps them.

2. The account may serve more than Claude. Ours also runs gpt-4.1, gpt-4o and
   gpt-realtime, whose InputTokens/OutputTokens land on the same metrics. Anything whose
   model name is not in PRICES is dropped and named in the output — silence there would
   mean a newly deployed Claude model quietly costing nothing.

ATTRIBUTION. These metrics carry ApiName, Region, ModelDeploymentName, ModelName,
ModelVersion and ContextLength — and no caller dimension. There is no oid, because the
caller's token never reaches Foundry; APIM swaps it for managed identity at the backend
hop. This rollup is therefore exact in aggregate and says nothing about who spent it. Do
not join it to a developer.

IDEMPOTENCY. Logs Ingestion is append-only, so re-running a window appends a second copy
rather than replacing the first. BinStart is carried explicitly so readers can collapse
duplicates with `summarize arg_max(TimeGenerated, *) by BinStart, Model`. Every panel
query that reads this table must do that, or a re-run inflates cost silently.
"""

import argparse
import importlib.util
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests

# Metric name -> (token column, cost column, PRICES key). Metric names are case-sensitive
# exactly as written; 'CacheReadInputTokens' returns nothing at all rather than erroring.
METRIC_MAP = {
    "InputTokens":             ("InputTokens",         "InputCost",        "input"),
    "OutputTokens":            ("OutputTokens",        "OutputCost",       "output"),
    "cacheReadInputTokens":    ("CacheReadTokens",     "CacheReadCost",    "cache_read"),
    "ephemeral5mInputTokens":  ("CacheWrite5mTokens",  "CacheWrite5mCost", "cache_write_5m"),
    "ephemeral1hInputTokens":  ("CacheWrite1hTokens",  "CacheWrite1hCost", "cache_write_1h"),
}

# The components APIM can observe. VisibleCostUsd is deliberately computed from these
# metrics rather than from the pipeline's own billing, so that comparing it to
# TrueCostUsd isolates cache-write blindness on one consistent source. Comparing the
# pipeline's billed cost to VisibleCostUsd is a different diagnostic — it surfaces
# traffic that reached Foundry without traversing the gateway.
VISIBLE_COMPONENTS = ("InputCost", "OutputCost", "CacheReadCost")


def load_prices() -> dict:
    """Import PRICES from the loader rather than restating it.

    Two rate tables that can drift is the failure mode that produces a plausible wrong
    number, so there is exactly one. The filename is not an importable module name, hence
    the spec loader — the same approach tests/test_cache_accounting.py uses.
    """
    path = Path(__file__).with_name("15-load-pricing.py")
    spec = importlib.util.spec_from_file_location("pricing_loader", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load prices from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.PRICES


def _normalise_model(name: str) -> str:
    """Strip a trailing -YYYYMMDD, matching the rest of the pipeline.

    The metric dimension reports 'claude-haiku-4-5-20251001' where PRICES holds
    'claude-haiku-4-5'. Without this every dated model silently prices at zero.
    """
    import re
    return re.sub(r"-\d{8}$", "", name or "")


def aligned_window(hours: int, grain_minutes: int, now: datetime | None = None):
    """Return (start, end) floored to the grain, excluding the bin in progress.

    THE METRICS API ALIGNS BINS TO THE START OF THE TIMESPAN, not to the clock. A window
    of `now - 168h` therefore produces bins at :35 past the hour when the script runs at
    :35, and at :07 when it runs at :07 — so two runs of the "same" window emit different
    BinStart values, nothing dedupes, and the totals double. Verified the hard way: a
    re-run produced 66 rows and $31.77 against 33 rows and $15.88.

    Flooring `end` to the grain also drops the current, incomplete bin. That is wanted: a
    partial bin ingested now and again after it closes would be two different numbers for
    the same key, and arg_max keeps the later, complete one — but only if the keys match,
    which is exactly what this alignment guarantees.
    """
    grain = timedelta(minutes=grain_minutes)
    epoch = datetime(1970, 1, 1, tzinfo=timezone.utc)
    now = now or datetime.now(timezone.utc)
    end = epoch + (now - epoch) // grain * grain
    return end - timedelta(hours=hours), end


def fetch_metrics(resource_id: str, hours: int, grain_minutes: int) -> dict:
    """Return {(bin_start, model): {metric_name: total}} from the Metrics API.

    `$filter=ModelName eq '*'` is what splits the series per model. Without it the
    response is a single resource-level series and the whole point is lost.

    Called over REST rather than through azure-monitor-query deliberately.
    That SDK removed MetricsQueryClient in 2.0.0 (it is logs-only now) and moved metrics
    to a separate package, so an unpinned install breaks this script. The REST contract
    has been stable on api-version 2018-01-01 for years, and `requests` is already a
    dependency of 15-load-pricing.py.
    """
    from azure.identity import DefaultAzureCredential

    token = DefaultAzureCredential().get_token("https://management.azure.com/.default")
    start, end = aligned_window(hours, grain_minutes)

    resp = requests.get(
        f"https://management.azure.com{resource_id}/providers/Microsoft.Insights/metrics",
        params={
            "api-version": "2018-01-01",
            "metricnames": ",".join(METRIC_MAP),
            "timespan": f"{start.strftime('%Y-%m-%dT%H:%M:%SZ')}/{end.strftime('%Y-%m-%dT%H:%M:%SZ')}",
            "interval": f"PT{grain_minutes}M",
            "aggregation": "Total",
            "$filter": "ModelName eq '*'",
        },
        headers={"Authorization": f"Bearer {token.token}"},
        timeout=60,
    )
    resp.raise_for_status()

    buckets: dict = {}
    for metric in resp.json().get("value", []):
        metric_name = metric.get("name", {}).get("value", "")
        for series in metric.get("timeseries", []):
            # metadatavalues names arrive lower-cased ('modelname'), not as declared.
            meta = {m.get("name", {}).get("value", ""): m.get("value", "")
                    for m in series.get("metadatavalues", [])}
            model = _normalise_model(meta.get("modelname") or meta.get("ModelName") or "")
            if not model:
                continue
            for point in series.get("data", []):
                total = point.get("total")
                if not total:
                    continue
                buckets.setdefault((point["timeStamp"], model), {})[metric_name] = float(total)
    return buckets


def build_rows(buckets: dict, prices: dict, resource_name: str) -> tuple[list[dict], set]:
    """Price each (bin, model) bucket. Returns (rows, models dropped for want of a rate)."""
    now = datetime.now(timezone.utc).isoformat()
    rows: list[dict] = []
    dropped: set = set()

    for (bin_start, model), totals in sorted(buckets.items(), key=lambda kv: (kv[0][0], kv[0][1])):
        rate = prices.get(model)
        if rate is None:
            # gpt-4.1 and friends land here, which is correct. So would a new Claude
            # model, which is not — hence the caller reports this set rather than
            # swallowing it.
            dropped.add(model)
            continue

        row = {
            "TimeGenerated": now,
            "BinStart": bin_start.isoformat() if hasattr(bin_start, "isoformat") else str(bin_start),
            "Model": model,
            "ResourceName": resource_name,
        }
        for metric_name, (token_col, cost_col, rate_key) in METRIC_MAP.items():
            tokens = int(totals.get(metric_name, 0))
            row[token_col] = tokens
            # Rates are per 1,000 tokens throughout this repo. A per-1M rate read as
            # per-1K is a 1000x error that still looks like a plausible number.
            row[cost_col] = tokens * float(rate[rate_key]) / 1000.0

        row["TrueCostUsd"] = sum(row[c] for _, (_, c, _) in METRIC_MAP.items())
        row["VisibleCostUsd"] = sum(row[c] for c in VISIBLE_COMPONENTS)
        rows.append(row)

    return rows, dropped


def upload_to_log_analytics(rows, endpoint, immutable_id, stream) -> None:
    from azure.identity import DefaultAzureCredential
    from azure.monitor.ingestion import LogsIngestionClient

    client = LogsIngestionClient(endpoint=endpoint, credential=DefaultAzureCredential())
    client.upload(rule_id=immutable_id, stream_name=stream, logs=rows)
    print(f"Uploaded {len(rows)} rows to {stream}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--resource-id", required=True,
                   help="ARM id of the Foundry / Cognitive Services account serving Claude")
    p.add_argument("--hours", type=int, default=24, help="lookback window (metrics retain 93 days)")
    p.add_argument("--grain-minutes", type=int, default=60, help="bin size; 60 matches the hourly rollup")
    p.add_argument("--dcr-endpoint", help="logsIngestion endpoint from 14-claude-tiers.bicep")
    p.add_argument("--dcr-immutable-id")
    p.add_argument("--dcr-stream", default="Custom-Json-CLAUDECOSTROLLUP_CL")
    p.add_argument("--dry-run", action="store_true", help="print the rows instead of uploading")
    args = p.parse_args()

    prices = load_prices()
    resource_name = args.resource_id.rstrip("/").split("/")[-1]

    buckets = fetch_metrics(args.resource_id, args.hours, args.grain_minutes)
    rows, dropped = build_rows(buckets, prices, resource_name)

    if dropped:
        # Not an error — a mixed-workload account is normal. But an unpriced CLAUDE model
        # here means it is billing at zero, which is the quiet failure worth shouting at.
        print(f"Skipped {len(dropped)} model(s) with no rate: {', '.join(sorted(dropped))}",
              file=sys.stderr)

    if not rows:
        print("No priced usage in this window.", file=sys.stderr)
        return

    true_total = sum(r["TrueCostUsd"] for r in rows)
    visible_total = sum(r["VisibleCostUsd"] for r in rows)
    coverage = (100.0 * visible_total / true_total) if true_total else 0.0
    print(f"{len(rows)} rows  true=${true_total:.4f}  visible=${visible_total:.4f}  "
          f"coverage={coverage:.1f}%", file=sys.stderr)

    if args.dry_run:
        print(json.dumps(rows, indent=2))
        return

    if not (args.dcr_endpoint and args.dcr_immutable_id):
        p.error("give --dcr-endpoint and --dcr-immutable-id, or --dry-run")

    upload_to_log_analytics(rows, args.dcr_endpoint, args.dcr_immutable_id, args.dcr_stream)


if __name__ == "__main__":
    main()
