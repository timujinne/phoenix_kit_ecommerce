# Recent changes — resolutions and validation

See [CODEX_REVIEW.md](CODEX_REVIEW.md) and the
[PR #118 review](../118-fresh-core-3x-chain/CODEX_REVIEW.md).

| Finding | Severity | Resolution |
|---|---|---|
| Stale cart line bypasses stock checks or hides a quantity update | BUG - MEDIUM | Re-read the line after locking the active cart; validate and update the stored row; preserve enclosing transactions on stock refusal |
| Stale email markers permit duplicate deliveries | BUG - MEDIUM | Lock and re-read the order before checking, sending, and marking each email; keep buyer and copy commits independent |
| Queued emails confirm refunded or cancelled orders | BUG - MEDIUM | Check the stored terminal status under the same lock, including calls with stale snapshots |
| Built Legacy products are mistaken for catalogue items | BUG - MEDIUM | Resolve Warehouse identity from `origin: :catalogue` |
| Overview lists obsolete dependencies and table ownership | NITPICK | Align the engineering guide with `mix.exs` and core 2.x/3.x migration behavior |

## Validation

Resolved Hex dependencies: core 3.3.0, billing 0.25.0, catalogue 0.50.0,
entities 0.7.0, Warehouse 0.7.0. No lockfile changes or local dependency
overrides.

- Initial focused baseline: **86 tests, 0 failures** across order emails,
  stock limits, and paid-order stock handling.
- Before applying the fixes, the added regression cases produced **6 failures**
  across stale quantity writes, product origin, refund delivery, and stale email
  markers. The enclosing-transaction test already passed and pins that contract.
- Full suite: `PGPOOL=8 mix test --max-cases 6`, seed `611089`:
  **5,155 tests, 0 failures, 6 excluded**, 291.5 seconds. Database integration,
  catalogue, Warehouse, API, checkout, and migration tests ran. Excluded tags
  select incompatible dependency variants and the absent analytics integration:
  `:old_catalogue`, `:no_catalogue`, `:core_no_confirm`,
  `:core_without_canonical_urls`, and `:analytics`.
- Final focused regression run, including the real-connection email race and
  copy failure/retry: **78 tests, 0 failures** across `order_emails_test.exs`,
  `order_emails_race_test.exs`, and `stock_limits_test.exs`. This run also covers
  the final helper extraction and the assertions using pre-transition snapshots.
- `mix precommit`: **passed** on the final code and tests. Compilation with
  warnings as errors, unused-lock check, Hex audit, format check, strict Credo,
  and Dialyzer passed. Credo reports no issues; Dialyzer reports eight findings
  covered by existing suppressions and no unnecessary suppressions.
- `git diff --check`: passed. The committed-data email race fixture was removed
  after execution; no `EMAIL-RACE-*` order remained in the test database.

The suite emits existing cache-registry and test-helper warnings; they did not
cause failures. No migrations, dependency versions, release version, CHANGELOG,
tags, or Hex publication changed.
