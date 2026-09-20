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

    def complete(self, rates, identity=None, pipe_results=None):
        redis = MagicMock()
        redis.set.return_value = True
        redis.hgetall.return_value = rates
        # _complete now spends through a single pipeline (one MULTI/EXEC) rather than
        # calling incrbyfloat directly on the redis client, so the mock's pipeline()
        # call has to return something whose execute() gives back the per-command
        # results in the same order _complete queues them: user incr, user expire,
        # tier incr, and — only when the request is charged to a team — team incr,
        # team expire, profile incr.
        pipe = MagicMock()
        pipe.execute.return_value = pipe_results if pipe_results is not None else ["0.027582", True, "0.027582"]
        redis.pipeline.return_value = pipe
        ledger = MagicMock()
        identity = identity or {"oid": "user", "tier": "lite"}
        with patch.object(processor, "get_container", return_value=ledger), patch.object(processor, "TIERS", {}):
            processor._complete(redis, "cid", {
                "model": "claude-opus-5", "requestId": "msg_read",
                "prompt": 26, "completion": 121, "cached": 48854,
            }, identity)
        return redis, pipe, ledger.upsert_item.call_args.args[0]

    def test_reads_are_added_to_uncached_input_and_writes_stay_unknown(self):
        rates = {k: str(v) for k, v in pricing.PRICES["claude-opus-5"].items()}
        redis, pipe, row = self.complete(rates)
        self.assertAlmostEqual(row["costUsd"], 0.027582)
        self.assertAlmostEqual(pipe.incrbyfloat.call_args_list[0].args[1], 0.027582)
        self.assertIsNone(row["cacheWrite5mTokens"])
        self.assertIsNone(row["cacheWrite1hTokens"])
        self.assertEqual(row["cacheReadTokens"], 48854)
        self.assertEqual(row["requestId"], "msg_read")
        self.assertEqual(row["costCoverage"], "excludes_cache_writes")
        self.assertEqual(row["pricingStatus"], "priced")
        # A caller with no team role at all still gets a ledger row shaped the same as
        # every other row — None fields, not missing ones — so a reconciliation query
        # can filter on IS_NULL(teamId) instead of special-casing its absence.
        self.assertIsNone(row["teamId"])
        self.assertIsNone(row["teamProfile"])
        self.assertEqual(row["teamGovernanceState"], "disabled")
        # Loading write prices alone must not synthesize write usage or increase charges.
        _, _, without_write_prices = self.complete({k: v for k, v in rates.items() if not k.startswith("cache_write")})
        self.assertEqual(row["costUsd"], without_write_prices["costUsd"])

    def test_missing_rates_are_marked_in_the_ledger(self):
        for rates in ({}, {"input": "0.005", "output": "0.025"}):
            with self.subTest(rates=rates):
                _, _, row = self.complete(rates)
                self.assertEqual(row["pricingStatus"], "missing_rates")


class TeamAccountingTests(unittest.TestCase):
    """T016: atomic user+team accounting through _complete's pipeline."""

    def _complete(self, identity, team_profiles, pipe_results, tiers=None):
        redis = MagicMock()
        redis.set.return_value = True
        redis.hgetall.return_value = {k: str(v) for k, v in pricing.PRICES["claude-opus-5"].items()}
        pipe = MagicMock()
        pipe.execute.return_value = pipe_results
        redis.pipeline.return_value = pipe
        ledger = MagicMock()
        with patch.object(processor, "get_container", return_value=ledger), \
             patch.object(processor, "TIERS", tiers or {}), \
             patch.object(processor, "TEAM_PROFILES", team_profiles):
            processor._complete(redis, "cid", {
                "model": "claude-opus-5", "requestId": "msg",
                "prompt": 100, "completion": 100, "cached": 0,
            }, identity)
        return redis, pipe, ledger.upsert_item.call_args.args[0]

    def test_ok_state_with_recognized_profile_charges_both_scopes(self):
        redis, pipe, row = self._complete(
            identity={"oid": "user", "tier": "lite", "teamId": "fdpo-team-1",
                      "teamProfile": "power", "teamState": "ok"},
            team_profiles={"power": {"costQuota": 1000}},
            pipe_results=["1.5", True, "1.5", "0.75", True, "0.75"],
        )
        # Three counters incremented: user, tier, and team; plus the profile counter.
        self.assertEqual(pipe.incrbyfloat.call_count, 4)
        month = processor._month_key()
        keys = [call.args[0] for call in pipe.incrbyfloat.call_args_list]
        self.assertIn(f"mtd:{month}:user", keys)
        self.assertIn(f"mtd:{month}:team:fdpo-team-1", keys)
        self.assertIn(f"mtd:{month}:profile:power", keys)
        self.assertEqual(row["teamId"], "fdpo-team-1")
        self.assertEqual(row["teamProfile"], "power")
        self.assertEqual(row["teamGovernanceState"], "ok")

    def test_ambiguous_state_is_never_charged_to_a_team(self):
        redis, pipe, row = self._complete(
            identity={"oid": "user", "tier": "lite", "teamId": "fdpo-team-1",
                      "teamProfile": "power", "teamState": "ambiguous"},
            team_profiles={"power": {"costQuota": 1000}},
            pipe_results=["1.5", True, "1.5"],
        )
        month = processor._month_key()
        keys = [call.args[0] for call in pipe.incrbyfloat.call_args_list]
        self.assertEqual(keys, [f"mtd:{month}:user", f"mtd:{month}:tier:lite"])
        self.assertIsNone(row["teamId"])
        self.assertIsNone(row["teamProfile"])
        self.assertEqual(row["teamGovernanceState"], "ambiguous")

    def test_missing_state_is_never_charged_to_a_team(self):
        _, pipe, row = self._complete(
            identity={"oid": "user", "tier": "lite", "teamId": "", "teamProfile": "", "teamState": "missing"},
            team_profiles={"power": {"costQuota": 1000}},
            pipe_results=["1.5", True, "1.5"],
        )
        self.assertEqual(pipe.incrbyfloat.call_count, 2)
        self.assertIsNone(row["teamId"])

    def test_profile_unknown_to_this_processor_is_not_charged_even_if_state_is_ok(self):
        # The policy says "ok", but this processor's own CLAUDE_TEAM_GOVERNANCE config
        # was never told about a "power" profile — a config drift the processor must
        # not paper over by charging a team for an undefined profile's quota.
        _, pipe, row = self._complete(
            identity={"oid": "user", "tier": "lite", "teamId": "fdpo-team-1",
                      "teamProfile": "power", "teamState": "ok"},
            team_profiles={},
            pipe_results=["1.5", True, "1.5"],
        )
        self.assertEqual(pipe.incrbyfloat.call_count, 2)
        self.assertIsNone(row["teamId"])

    def test_team_over_budget_sets_a_scoped_flag_distinct_from_the_user_flag(self):
        redis, _, _ = self._complete(
            identity={"oid": "user", "tier": "lite", "teamId": "fdpo-team-1",
                      "teamProfile": "power", "teamState": "ok"},
            team_profiles={"power": {"costQuota": 1000}},
            pipe_results=["1.5", True, "1.5", "1500.0", True, "1500.0"],
        )
        set_keys = [call.args[0] for call in redis.set.call_args_list]
        self.assertIn("over:team:fdpo-team-1", set_keys)
        self.assertNotIn("over:user", set_keys)


class ThresholdTests(unittest.TestCase):
    """T016: structured, deduplicated utilization-threshold events."""

    def test_only_the_newly_crossed_guard_emits(self):
        # thresh:...:70/85/95 all evaluate true at 95% utilization, but SETNX has
        # already been tripped for 70 and 85 in earlier requests this month — only
        # the guard ending in ":95" is genuinely new.
        redis = MagicMock()
        redis.set.side_effect = lambda key, *a, **kw: key.endswith(":95")
        with patch.object(processor, "_emit_governance_event") as emit:
            processor._check_thresholds(redis, "team", "fdpo-team-1", "202609",
                                         950.0, 1000.0, 3600, profile="power")
        emit.assert_called_once_with(
            "threshold_crossed", scope="team", id="fdpo-team-1", month="202609",
            threshold=95, totalUsd=950.0, quotaUsd=1000.0, profile="power",
        )

    def test_a_guard_already_set_this_month_suppresses_the_event(self):
        redis = MagicMock()
        redis.set.return_value = False  # every SETNX in this test has already been tripped
        with patch.object(processor, "_emit_governance_event") as emit:
            processor._check_thresholds(redis, "user", "u1", "202609", 950.0, 1000.0, 3600)
        emit.assert_not_called()

    def test_zero_quota_is_skipped_rather_than_dividing_by_zero(self):
        redis = MagicMock()
        processor._check_thresholds(redis, "user", "u1", "202609", 100.0, 0.0, 3600)
        redis.set.assert_not_called()


class AmbiguousIdentityLoggingTests(unittest.TestCase):
    """T016: ambiguous_identity events, gated on team governance actually being on."""

    def _gateway_log_record(self, cid, oid, team_state, team_id="fdpo-team-1", team_profile="power"):
        return {
            "category": "GatewayLogs",
            "properties": {
                "correlationId": cid,
                "backendRequestHeaders": {
                    "x-caller-oid": oid, "x-caller-tier": "lite",
                    "x-team-governance-state": team_state,
                    "x-caller-team-id": team_id, "x-caller-team-profile": team_profile,
                },
            },
        }

    def test_ambiguous_state_emits_when_governance_is_on(self):
        redis = MagicMock()
        redis.hgetall.return_value = {}
        with patch.object(processor, "TEAM_GOVERNANCE_MODE", "enforce"), \
             patch.object(processor, "_emit_governance_event") as emit:
            processor._handle(redis, self._gateway_log_record("cid2", "user2", "ambiguous"))
        emit.assert_called_once_with("ambiguous_identity", oid="user2", state="ambiguous")

    def test_missing_state_never_emits_ambiguous_identity(self):
        redis = MagicMock()
        redis.hgetall.return_value = {}
        with patch.object(processor, "TEAM_GOVERNANCE_MODE", "enforce"), \
             patch.object(processor, "_emit_governance_event") as emit:
            processor._handle(redis, self._gateway_log_record("cid3", "user3", "missing"))
        emit.assert_not_called()

    def test_governance_off_never_emits_even_if_the_state_is_ambiguous(self):
        # Mode "off" means skip all team behaviour, including its own diagnostics — an
        # operator who has not turned this on should not start seeing its log lines.
        redis = MagicMock()
        redis.hgetall.return_value = {}
        with patch.object(processor, "TEAM_GOVERNANCE_MODE", "off"), \
             patch.object(processor, "_emit_governance_event") as emit:
            processor._handle(redis, self._gateway_log_record("cid4", "user4", "ambiguous"))
        emit.assert_not_called()


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

    def test_ledger_replay_rebuilds_user_team_and_aggregate_counters(self):
        rows = [
            {"id": "a", "month": "202609", "oid": "user-1", "tier": "pro", "costUsd": 12.5,
             "teamId": "fdpo-team-1", "teamProfile": "power"},
            {"id": "b", "month": "202609", "oid": "user-1", "tier": "pro", "costUsd": 7.5,
             "teamId": "fdpo-team-1", "teamProfile": "power"},
            {"id": "c", "month": "202609", "oid": "user-2", "tier": "lite", "costUsd": 3.0,
             "teamId": None, "teamProfile": None},
        ]
        totals = reconciler.build_ledger_totals(rows, "202609")
        self.assertEqual(totals["users"], {"user-1": 20.0, "user-2": 3.0})
        self.assertEqual(totals["tiers"], {"pro": 20.0, "lite": 3.0})
        self.assertEqual(totals["teams"], {"fdpo-team-1": 20.0})
        self.assertEqual(totals["profiles"], {"power": 20.0})

    def test_ledger_replay_rejects_changed_or_unknown_team_mapping(self):
        rows = [{"id": "a", "month": "202609", "oid": "user-1", "tier": "pro", "costUsd": 5,
                 "teamId": "fdpo-team-1", "teamProfile": "power"}]
        with self.assertRaisesRegex(ValueError, "profile mismatch"):
            reconciler.build_ledger_totals(rows, "202609", {"fdpo-team-1": "regular"})
        with self.assertRaisesRegex(ValueError, "unknown team"):
            reconciler.build_ledger_totals(rows, "202609", {"fdpo-team-2": "power"})

    def test_ledger_replay_sets_month_ttl_and_scoped_flags(self):
        redis = MagicMock()
        redis.pipeline.return_value = redis
        redis.execute.return_value = []
        totals = {
            "users": {"user-1": 120.0}, "tiers": {"lite": 120.0},
            "teams": {"fdpo-team-1": 1200.0}, "profiles": {"power": 1200.0},
            "userTiers": {"user-1": "lite"}, "teamProfiles": {"fdpo-team-1": "power"},
        }
        reconciler.apply_ledger_totals(
            redis, totals, "202609", 3600,
            {"lite": {"costQuota": 100}}, {"power": {"costQuota": 1000}},
        )
        redis.set.assert_any_call("mtd:202609:user-1", 120.0, ex=3600)
        redis.set.assert_any_call("mtd:202609:team:fdpo-team-1", 1200.0, ex=3600)
        redis.set.assert_any_call("over:user-1", 1, ex=3600)
        redis.set.assert_any_call("over:team:fdpo-team-1", 1, ex=3600)


if __name__ == "__main__":
    unittest.main()
