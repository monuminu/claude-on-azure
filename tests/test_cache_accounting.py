"""Offline regression checks for the measured cache-accounting corrections.

Install snippets/17-usage-processor/requirements.txt and requests, then run:
    python -m unittest discover -s tests -v
Cloud clients are replaced at the persistence boundary; no credentials are requested.
"""

import importlib.util
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch


ROOT = Path(__file__).resolve().parents[1]


def load_module(name, relative_path):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pricing = load_module("pricing", "snippets/15-load-pricing.py")
processor = load_module("processor", "snippets/17-usage-processor/function_app.py")
reconciler = load_module("reconciler", "snippets/20-cost-reconciler.py")


class CachePricingTests(unittest.TestCase):
    def test_seven_day_measured_opus_cost(self):
        rates = pricing.PRICES["claude-opus-5"]
        counts = {"input": 181428, "output": 97972, "cache_read": 5311188,
                  "cache_write_5m": 159197, "cache_write_1h": 875313}
        total = sum(counts[k] * rates[k] for k in counts) / 1000
        self.assertAlmostEqual(total, 15.76014525)
        # Applying the 5m rate to 1h writes caused the measured $3.28 shortfall.
        self.assertAlmostEqual(
            counts["cache_write_1h"] * (rates["cache_write_1h"] - rates["cache_write_5m"]) / 1000,
            3.28242375,
        )

    def test_write_ttl_rates_for_every_supported_model(self):
        for model, rates in pricing.PRICES.items():
            with self.subTest(model=model):
                self.assertAlmostEqual(rates["cache_write_5m"], rates["input"] * 1.25)
                self.assertAlmostEqual(rates["cache_write_1h"], rates["input"] * 2)

    def test_log_analytics_rows_keep_existing_ingestion_schema(self):
        for row in pricing.build_rows():
            self.assertEqual(set(row), {"TimeGenerated", "Model", "InputTokensPrice", "OutputTokensPrice"})


class ProcessorTests(unittest.TestCase):
    def test_probe_does_not_create_an_inference_pair(self):
        redis = MagicMock()
        processor._handle(redis, {
            "category": "GatewayLlmLogs",
            "properties": {"correlationId": "probe", "requestId": "", "modelName": "",
                           "promptTokens": 0, "completionTokens": 0},
        })
        self.assertEqual(redis.mock_calls, [])

    def test_zero_uncached_input_can_still_be_billable(self):
        for capitalized in (False, True):
            with self.subTest(capitalized=capitalized):
                redis = MagicMock()
                redis.hgetall.return_value = {}
                props = {"correlationId": "cid", "requestId": "msg_cache", "modelName": "claude-opus-5",
                         "promptTokens": 0, "completionTokens": 0, "promptCachedTokens": 4460}
                if capitalized:
                    props = {key[0].upper() + key[1:]: value for key, value in props.items()}
                processor._handle(redis, {"category": "GatewayLlmLogs", "properties": props})
                args = redis.hset.call_args
                self.assertEqual(args.args[0], "tok:cid")
                self.assertEqual(args.kwargs["mapping"]["cached"], 4460)
                self.assertEqual(args.kwargs["mapping"]["requestId"], "msg_cache")

    def test_missing_message_id_does_not_discard_known_usage(self):
        redis = MagicMock()
        redis.hgetall.return_value = {}
        with self.assertLogs("usage-processor", level="WARNING"):
            processor._handle(redis, {
                "category": "GatewayLlmLogs",
                "properties": {"correlationId": "cid", "promptTokens": 42},
            })
        self.assertEqual(redis.hset.call_args.kwargs["mapping"]["prompt"], 42)

    def complete(self, rates):
        redis = MagicMock()
        redis.set.return_value = True
        redis.hgetall.return_value = rates
        redis.incrbyfloat.return_value = "0.027582"
        ledger = MagicMock()
        with patch.object(processor, "get_container", return_value=ledger), patch.object(processor, "TIERS", {}):
            processor._complete(redis, "cid", {
                "model": "claude-opus-5", "requestId": "msg_read",
                "prompt": 26, "completion": 121, "cached": 48854,
            }, {"oid": "user", "tier": "lite"})
        return redis, ledger.upsert_item.call_args.args[0]

    def test_reads_are_added_to_uncached_input_and_writes_stay_unknown(self):
        rates = {k: str(v) for k, v in pricing.PRICES["claude-opus-5"].items()}
        redis, row = self.complete(rates)
        self.assertAlmostEqual(row["costUsd"], 0.027582)
        self.assertAlmostEqual(redis.incrbyfloat.call_args_list[0].args[1], 0.027582)
        self.assertIsNone(row["cacheWrite5mTokens"])
        self.assertIsNone(row["cacheWrite1hTokens"])
        self.assertEqual(row["cacheReadTokens"], 48854)
        self.assertEqual(row["requestId"], "msg_read")
        self.assertEqual(row["costCoverage"], "excludes_cache_writes")
        self.assertEqual(row["pricingStatus"], "priced")
        # Loading write prices alone must not synthesize write usage or increase charges.
        _, without_write_prices = self.complete({k: v for k, v in rates.items() if not k.startswith("cache_write")})
        self.assertEqual(row["costUsd"], without_write_prices["costUsd"])

    def test_missing_rates_are_marked_in_the_ledger(self):
        for rates in ({}, {"input": "0.005", "output": "0.025"}):
            with self.subTest(rates=rates):
                _, row = self.complete(rates)
                self.assertEqual(row["pricingStatus"], "missing_rates")


class ReconcilerTests(unittest.TestCase):
    """20-cost-reconciler.py — the only surface that prices cache writes."""

    def buckets(self, model="claude-opus-5", bin_start="2026-09-06T09:00:00Z"):
        # The measured seven-day Opus 5 sample from CACHE-TOKEN-ANALYSIS.md 3.2.
        return {(bin_start, model): {
            "InputTokens": 181428.0, "OutputTokens": 97972.0,
            "cacheReadInputTokens": 5311188.0,
            "ephemeral5mInputTokens": 159197.0, "ephemeral1hInputTokens": 875313.0,
        }}

    def test_reproduces_the_measured_seven_day_opus_cost(self):
        rows, dropped = reconciler.build_rows(self.buckets(), pricing.PRICES, "monuminu")
        self.assertEqual(dropped, set())
        row, = rows
        self.assertAlmostEqual(row["InputCost"], 0.90714)
        self.assertAlmostEqual(row["OutputCost"], 2.4493)
        self.assertAlmostEqual(row["CacheReadCost"], 2.655594)
        self.assertAlmostEqual(row["CacheWrite5mCost"], 0.99498125)
        self.assertAlmostEqual(row["CacheWrite1hCost"], 8.75313)
        self.assertAlmostEqual(row["TrueCostUsd"], 15.76014525)
        # Same total the processor's rate table produces, reached from metrics instead of
        # from the log. If these two ever diverge, one of them is billing fiction.
        self.assertAlmostEqual(row["VisibleCostUsd"], 6.012034)

    def test_coverage_matches_the_measured_thirty_eight_percent(self):
        row, = reconciler.build_rows(self.buckets(), pricing.PRICES, "monuminu")[0]
        coverage = 100.0 * row["VisibleCostUsd"] / row["TrueCostUsd"]
        self.assertAlmostEqual(coverage, 38.1, places=1)

    def test_unpriced_models_are_dropped_and_named(self):
        # The Foundry account also serves gpt-*, whose tokens land on the same metrics.
        # Dropping them silently would be wrong in the other direction: a new Claude model
        # would bill zero and nothing would say so.
        buckets = self.buckets()
        buckets[("2026-09-06T09:00:00Z", "gpt-4o")] = {"InputTokens": 26150.0}
        rows, dropped = reconciler.build_rows(buckets, pricing.PRICES, "monuminu")
        self.assertEqual(dropped, {"gpt-4o"})
        self.assertEqual([r["Model"] for r in rows], ["claude-opus-5"])

    def test_dated_model_names_resolve_to_a_rate(self):
        # The metric dimension reports claude-haiku-4-5-20251001; PRICES holds the
        # undated key. Without normalisation the model prices at zero.
        self.assertEqual(reconciler._normalise_model("claude-haiku-4-5-20251001"),
                         "claude-haiku-4-5")
        self.assertIn(reconciler._normalise_model("claude-haiku-4-5-20251001"), pricing.PRICES)

    def test_rate_table_is_shared_not_copied(self):
        # Two rate tables that can drift is how a plausible wrong number gets produced.
        # The reconciler imports PRICES from the loader rather than restating it.
        self.assertEqual(reconciler.load_prices(), pricing.PRICES)

    def test_visible_components_exclude_writes(self):
        # VisibleCostUsd is the ceiling of what APIM could ever bill. If a write component
        # leaks into it, the coverage panel silently reports full coverage.
        self.assertNotIn("CacheWrite5mCost", reconciler.VISIBLE_COMPONENTS)
        self.assertNotIn("CacheWrite1hCost", reconciler.VISIBLE_COMPONENTS)

    def test_bins_are_grain_aligned_so_a_rerun_dedupes(self):
        # THE REGRESSION THIS FILE EXISTS FOR MOST. The Metrics API aligns bins to the
        # start of the requested timespan, so an unaligned window makes every run emit
        # different BinStart values — dedupe by (BinStart, Model) then matches nothing and
        # a re-run doubles the cost. Caught live: 66 rows and $31.77 against 33 and $15.88.
        from datetime import datetime, timedelta, timezone
        hour = datetime(2026, 9, 6, 15, 0, 0, tzinfo=timezone.utc)
        # Every run WITHIN one hour must resolve to the same window. Runs in different
        # hours legitimately differ — that is the rollup advancing, not drift.
        windows = {reconciler.aligned_window(168, 60, hour + timedelta(minutes=m, seconds=s))
                   for m, s in ((0, 0), (7, 13), (35, 47), (59, 59))}
        self.assertEqual(len(windows), 1)
        start, end = windows.pop()
        self.assertEqual((end.minute, end.second, end.microsecond), (0, 0, 0))
        # The in-progress bin is excluded, not half-reported.
        self.assertEqual(end, hour)
        self.assertEqual(end - start, timedelta(hours=168))

    def test_row_schema_matches_the_ingestion_stream(self):
        # Must stay in step with the Custom-Json-CLAUDECOSTROLLUP_CL declaration and the
        # ClaudeCostRollup_CL table in infra/14-claude-tiers.bicep. A column present here and
        # absent there is dropped at ingestion without an error.
        row, = reconciler.build_rows(self.buckets(), pricing.PRICES, "monuminu")[0]
        self.assertEqual(set(row), {
            "TimeGenerated", "BinStart", "Model", "ResourceName",
            "InputTokens", "OutputTokens", "CacheReadTokens",
            "CacheWrite5mTokens", "CacheWrite1hTokens",
            "InputCost", "OutputCost", "CacheReadCost",
            "CacheWrite5mCost", "CacheWrite1hCost",
            "TrueCostUsd", "VisibleCostUsd",
        })


if __name__ == "__main__":
    unittest.main()
