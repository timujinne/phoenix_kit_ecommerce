# Code Review: PR #22 — test: stop relying on incidental first-user-becomes-Owner ordering

**Reviewed:** 2026-08-20
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/22
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** eca63cccd33ca467bd4153966449ee31acc1f553 (merge commit)
**Status:** Merged

## Summary

Two independent, test-only changes:

1. `config/test.exs` — `PGDATABASE` now overrides the hardcoded
   `phoenix_kit_ecommerce_test<partition>` database name, and `PGPOOL`
   overrides the default `schedulers_online() * 2` connection-pool size.
   Both are `case`-based, fall back to the previous unset-env behavior
   exactly, and mirror the identical mechanism already used by core
   `phoenix_kit` (and `phoenix_kit_catalogue`/`dashboards`/`entities`).
   This lets the suite run against a shared/managed Postgres instance
   where the test role has no `CREATEDB` grant, instead of silently
   excluding the entire `:integration` half.

2. `test/phoenix_kit_ecommerce/web/settings_notifications_test.exs` —
   the "recipient checkboxes persist the JSON list" test used to rely on
   its fixture user being the first user ever registered in the sandboxed
   transaction, which core auto-promotes to "Owner". Against a shared test
   database with a pre-existing committed Owner (e.g. a seed account), that
   promotion never fires, the fixture user is never a notification-recipient
   candidate, and the test fails for a reason unrelated to what it actually
   checks. The fix grants "Admin" + `shop.manage_carts` explicitly via
   `Roles.assign_role/2` + `Permissions.grant_permission/2`, instead of
   depending on registration order.

## Verification

- Confirmed `Permissions.grant_permission(role_uuid, "shop.manage_carts")`
  grants the sub-permission and cascades the base `"shop"` module key
  (`deps/phoenix_kit/lib/phoenix_kit/users/permissions.ex:964`), and that
  `admin_recipients/1` (`lib/phoenix_kit_ecommerce/notifications.ex:270`)
  resolves via `Permissions.users_with_permission("shop.manage_carts")` —
  the exact key granted, so the fixture user is picked up.
- Confirmed the new setup is byte-for-byte the same pattern as
  `create_admin_user/0` in `test/phoenix_kit_ecommerce/notifications_test.exs:352`,
  which the PR cites as precedent.
- Confirmed `Roles.assign_role/2` and `Permissions.grant_permission/3` exist
  with the signatures the test calls, and that `DataCase.fixture_user/0`
  generates a unique email per call (no collision risk from the extra call).
- Compared `config/test.exs`'s `PGDATABASE`/`PGPOOL` handling line-for-line
  against core `phoenix_kit/config/test.exs` — same fallback semantics, same
  `System.get_env/2`-avoidance rationale (a set-but-empty var must not raise).
- Ran the full gate: `mix precommit` (compile --warnings-as-errors, credo
  --strict, dialyzer) — clean. `mix test` — 476 tests, 0 failures, against
  a fresh (non-shared) database in this environment, so the pre-existing
  `CategoryTest`/`ImportUpsertTest` failures the PR description mentions
  (visible only against a shared/seeded DB, explicitly out of scope for
  this PR) did not reproduce here — expected, not a gap in this review.

## Issues Found

None. Both changes are correctly scoped, match an established sibling-repo
convention, and are covered by the very test they fix.

## What Was Done Well

- Root-caused a flaky-by-environment test instead of loosening the
  assertion or adding a retry.
- Reused an existing, already-exercised resolution path
  (`create_admin_user/0`'s pattern) rather than inventing a new one.
- The `PGDATABASE`/`PGPOOL` addition is defensively written (trims input,
  validates `PGPOOL` as a positive integer, raises with the bad value in
  the message) and is a no-op when unset, so CI and `mix hex.publish` are
  unaffected.
- Verified the fix locally against both an empty and a shared/seeded
  database (per the commit message) before landing it.

## Verdict

**Approved** — no changes needed. Gate is clean, full suite passes, no
follow-up items.
