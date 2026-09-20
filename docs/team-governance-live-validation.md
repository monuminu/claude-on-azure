# Team Governance Live Validation

Use this checklist after local tests and ARM what-if approval. It performs billable inference and
may change Entra/Azure state; do not run it without the tenant, gateway, and workload owners.

## Evidence and approvals

- Record config commit, tenant/subscription, resource groups, APIM revision, Function packages,
  operator, approvers, timestamps, and governance mode.
- Archive governance `--check` output and manifest. Verify every user is a direct member of one
  declared group and a fresh token contains `Claude.User`, one tier, one team, and one profile role.
- Approve expected Graph additions, ARM what-if for modules `16`, `22`, and `04`, billable test
  traffic, temporary low-limit profiles, fail-open interruption, and rollback rehearsal.

## Offline gates

- Run `node --test tests/test_gateway_scripts.mjs` and
  `python3 -m unittest tests/test_cache_accounting.py`.
- Parse Bash, PowerShell, XML, and JSON; build modules `04`, `16`, `22`, and
  `admin/pricing-access.bicep`.
- Confirm APIM v2 support, EP1/Redis capacity, managed-identity RBAC, Graph permissions, Entra
  licensing, workspace/action groups, and all declared user objects.

## Observe mode

- Deploy in dependency order: APIM bootstrap without policy, `14`, `16`, pricing/RBAC, Functions,
  Entra reconciliation, `22`, then final `04` policy. Confirm outputs before final policy.
- With `mode=off`, verify existing individual behavior and no team denial.
- With `mode=observe`, test valid, missing, duplicate, and mismatched team/profile roles. Valid
  users must show expected team headers; invalid identities must be logged but retain individual
  behavior.
- Verify `/v1/models` succeeds before suspension and budget checks and consumes no team budget.
- Send streamed requests from every governed user. Correlate APIM logs, Event Hub, processor logs,
  one Cosmos row, and exactly one user plus one team Redis increment per completed request.
- Compare Redis user sums to team totals within documented pricing tolerance. Replay Cosmos into
  Redis and prove totals/flags are unchanged; mapping drift must fail without rewriting history.
- Verify workbook drill-down, identity violations, denials, processor lag, missing-price signals,
  and configured utilization alerts.

## Controlled denials

- In an isolated low-limit profile, independently produce user-cost, team-cost, user-token, and
  team-token denial. Record status, reset/retry headers, caller/team identity, and
  `x-claude-denied-by` attribution.
- Exhaust both user and team cost and verify the combined budget scope is reported.
- Stop or isolate the budget API, then Redis, and prove inference fails open while individual/team
  token controls remain effective and a fail-open alert fires.
- Verify a suspended user keeps access with an old token and is denied only after obtaining a fresh
  token; record this expected propagation window.

## Promote and rollback

- Require an agreed observe burn-in with zero unexplained identity drift, healthy processor lag,
  successful replay, and approved cost variance.
- Change only the module `22` mode named value to `enforce`, obtain fresh tokens, and rerun valid,
  missing, duplicate, mismatch, streaming, and all four denial cases.
- Rehearse rollback by returning mode to `observe`. Confirm individual tier, suspension, token, and
  budget controls remain active and record recovery time.