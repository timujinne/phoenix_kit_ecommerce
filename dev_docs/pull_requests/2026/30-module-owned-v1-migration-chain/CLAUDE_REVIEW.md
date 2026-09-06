# Code Review: PR #30 — Module-owned V1 migration chain (adoptive)

**Reviewed:** 2026-09-05
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/30
**Author:** Tymofii Shapovalov (timujeen)
**Head SHA:** 6dbaea16c750132d96631c6e167f7ac8fcb9e89f
**Status:** Merged

## Summary

Adds `PhoenixKitEcommerce.Migrations` — a module-owned, adoptive V1 chain over the
ten shop tables core still creates in its V135 baseline (plus the two slug-projection
functions and their triggers) — and registers it via `migration_module/0`. V1 changes
no shape: every statement is `CREATE … IF NOT EXISTS` / `CREATE OR REPLACE` /
`DO $$ … IF NOT EXISTS … $$`, and the only new object on an existing install is the
`pke_schema:1` COMMENT marker on `phoenix_kit_shop_config`. `down/1` rewrites the
marker and nothing else.

The chain was cross-checked statement-by-statement against core's own DDL:

* **columns** — all eight core-created tables match `postgres/v135.ex` exactly
  (column names, types, defaults, NOT NULLs, order);
* **projection tables** — match `postgres/shop_slug_projection.ex` (`up_sql/2`),
  including the pkey `(lang, value)` and the `ON DELETE CASCADE` owner FK, whose
  Postgres-generated names (`phoenix_kit_shop_product_slugs_product_uuid_fkey`,
  `…_pkey`) are the names `Product`/`Category` pass to `unique_constraint/3`;
* **indexes** — the 37 core indexes on these tables match core's manifest
  (`migrations/expected_schema.ex`) one-for-one, and the two V171-superseded
  expression indexes (`idx_shop_{products,categories}_slug_primary`) are correctly
  *not* adopted;
* **constraints** — a superset of core's manifest entries (the manifest folds the
  projection FKs into its table DDL and omits `…_slug_unique`), every name matching
  core's.

## Issues Found

### 1. [BUG - MEDIUM] Five `*_uuid_idx` names drop core's schema-name embedding, duplicating an index on every prefixed install — FIXED
**File:** `lib/phoenix_kit_ecommerce/migrations.ex` lines 619–738 (`indexes/2`)
**Confidence:** 95/100

Core does not name every index the same way in every schema. In `v135.ex` it binds

```elixir
pn = if prefix == "public", do: "", else: "#{prefix}_"
```

and uses it for exactly five of the shop indexes — the `*_uuid_idx` on
`phoenix_kit_shop_cart_items`, `…_carts`, `…_categories`, `…_products` and
`…_shipping_methods`. Core's expected-schema manifest carries the same rule as the
`__PK_NAME_EXEMPT__` marker, materialized to `""` for `public` and `"<prefix>_"`
otherwise. Every *other* shop index is named identically in every schema.

This chain emitted all 39 index names bare. Under `public` that is right, and the
whole test suite runs there — so the gap was invisible. Under any non-public prefix
core has already created `tenant_x_phoenix_kit_shop_carts_uuid_idx`, so the chain's
`CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_shop_carts_uuid_idx ON
tenant_x.phoenix_kit_shop_carts …` matches nothing, succeeds, and builds a **second,
redundant unique index on the same column** — five of them, one per table. The
result is permanent write amplification on the busiest shop tables plus a schema that
no longer matches core's manifest, which is precisely what an *adoptive* chain exists
to prevent. This is the same class of defect as the `functions/0` blocker the PR
already fixed (hardcoded `public.`): a statement that is only correct in the schema
the tests run in.

**Fix applied:** `indexes/1` became `indexes/2`, taking the raw prefix and deriving
core's `pn`; the five exempt indexes go through a new `exempt_unique_idx/5`. Two
tests were added: one asserting the five carry the `tenant_x_` embedding under a
foreign prefix and stay bare under `public`, and one asserting that *no other* index
carries it (the whole 39-name set is compared, so a future index added on either side
of the rule fails the test rather than drifting).

### 2. [OBSERVATION] `up/1` ignores the `:version` option core's generated migration passes
**File:** `lib/phoenix_kit_ecommerce/migrations.ex` lines 105–110
**Confidence:** 90/100

`mix phoenix_kit.update` writes `PhoenixKitEcommerce.Migrations.up(prefix: "…",
version: <target>)`, but `up/1` reads only `:prefix` and always applies through
`current_version/0`, stamping that. With one version in the chain the two can't
disagree. From V2 on, an old generated file (`…_update_v00_to_v01.exs`) replayed on a
fresh database applies and stamps V2 — harmless because every statement is idempotent
and the later file re-runs as a no-op, but the file no longer does what its name says.
Left as is: it is the `phoenix_kit_billing` template's shape, not a regression from
this chain, and the same reasoning the PR used to reject the `down_statements/2`
target clamp. Worth honouring when V2 lands.

### 3. [NITPICK] `validated_prefix/1` raises the wrong error for a non-binary prefix
**File:** `lib/phoenix_kit_ecommerce/migrations.ex` lines 845–858
**Confidence:** 85/100

A non-binary `:prefix` (`prefix: :tenant_x`) reaches `prefix =~ ~r/…/` and raises
`FunctionClauseError`, not the `ArgumentError` the module documents and
`migrated_version_runtime/1` re-raises deliberately. Unreached from core's call sites,
which always pass a string. Not fixed — a guard clause here buys nothing a caller can
act on.

### 4. [NITPICK] The chain is undocumented outside its own moduledoc — FIXED
**File:** `AGENTS.md`
**Confidence:** 100/100

`AGENTS.md` describes every other ownership contract in this module in detail, and
still said nothing about the module owning migrations; the nearest sentence
(`README.md`: "The test repo runs core's versioned migrations … — no module-owned
DDL") now reads as if this module owns none. That README line is about the *test
harness* and is still accurate, so it was left alone; a "Module-owned migrations"
section was added to `AGENTS.md` instead, stating the adoption contract, the two
rules an adoptive chain must hold (prefix-parameterized statements, core's per-schema
names) — each of which has now been broken exactly once — and that the DB-free
statement scans are the only check that runs.

## What Was Done Well

* **The adoption argument is written down, not assumed.** The moduledoc states which
  objects are new on an existing install (two `CREATE OR REPLACE` bodies and the
  marker), why `down/1` drops nothing, and that the column double-quoting differs
  from the `pg_dump` source deliberately. That is what made this chain checkable
  against core at all.
* **Statements as data.** `up_statements/1` / `down_statements/2` make the whole
  chain testable without a database — the reason both the earlier `public.` blocker
  and this review's finding could be pinned by a unit test instead of a live prefixed
  install.
* **The destructive-statement scan is scoped correctly**, stripping only the
  `$function$` body so a `DROP` added to a function's own DDL wrapper still fails,
  and distinguishing the `DELETE FROM` statement from the `ON DELETE CASCADE`
  referential action every adopted FK carries.
* **The exact-count assertion (77)** turns "did the chain lose an object" into a test
  failure rather than a silent omission.
* **`marker_to_version/1` reads a foreign or missing comment as 0**, and
  `migrated_version_runtime/1` re-raises the prefix `ArgumentError` rather than
  swallowing it into "not installed" — the failure mode that would have let an
  unvalidated prefix reach interpolated SQL in a caller's fallback path.

## Verdict

**Approved with fixes.** The chain is a faithful adoption of core's shop objects —
columns, index set, constraint names and projection DDL all check out against
`v135.ex`, `shop_slug_projection.ex` and `expected_schema.ex`. One real defect, in the
same "only correct under `public`" family as the blocker the PR itself caught, is
fixed here with tests that pin both sides of core's naming rule.
