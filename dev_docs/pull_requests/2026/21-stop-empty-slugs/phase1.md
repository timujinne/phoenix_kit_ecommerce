# PR #21 Phase 1 Review — phoenix_kit_ecommerce

**Title:** Stop writing empty slugs that lock a shop out of its own index
**Author:** Max Don (mdon)
**Date:** 2026-08-14
**Verdict:** APPROVE WITH NOTES

---

## Summary

Fixes a real, reproducible production bug: `Slug.slugify/2` silently returns `""`
for scripts it cannot romanize (CJK, Arabic, emoji), and the unique index
`extract_primary_slug(slug)` is partial on `IS NOT NULL` only — so a written `""`
was enforced, and the _second_ product with an unromanizable title could not be
inserted (`duplicate key value violates unique constraint`).

The fix is local and self-contained: both `Product` and `Category` get an
extracted `put_generated_slug/2` helper that guards the _result_ of `slugify/2`
(not just the input), plus a trailing `Enum.reject` pass that scrubs pre-existing
`""` values from the slug map. Legacy rows self-heal on their next changeset save
without a migration. PR says it is intentionally independent of the
`put_slug/3` core series and carries its own test suite (5 regression tests).

**Stats:** +129 / -16 across 3 files. No migration. No version bump. No CHANGELOG entry.

---

## Findings

### Blockers

**None.** The fix is correct and the tests are solid. However the two items below
must land before a Hex release can be cut.

### Non-blockers

1. **Missing `@version` bump and CHANGELOG entry** — PR body explicitly says
   "No `CHANGELOG.md`, no `@version`." Both are required before publishing to
   Hex. Current version is `0.2.1`; this warrants at minimum a patch bump to
   `0.2.2`. CHANGELOG needs a `### Fixed` entry describing the empty-slug bug.
   _Will block Hex publish, not the merge itself._

2. **No migration for currently-locked shops** — The self-heal approach is valid
   and documented, but shops that _already_ have `{"en": ""}` slugs in production
   are still unable to insert new products until some save event clears the
   poisoned row. A one-off migration that runs
   `UPDATE shop_products SET slug = slug - '<lang>' WHERE slug->>'<lang>' = ''`
   (or equivalent) would give immediate relief. The PR explicitly defers this,
   so it is a conscious decision — worth flagging to Dmitri if we have known
   affected tenants.

3. **Duplicate `put_generated_slug/2`** — Identical private function defined in
   both `Product` and `Category`. Once this lands, worth extracting into a shared
   helper (e.g. `PhoenixKitEcommerce.Slug` or a `SlugHelpers` module). Not
   urgent, just accumulating duplication.

### Nitpicks

- The inline comments in `product.ex` and `category.ex` are unusually long (8+
  lines explaining the bug). They're accurate, but that explanation belongs in
  the commit message / PR body, not the source. Could be trimmed post-merge.
- `put_generated_slug(&2, &1)` argument inversion in `Enum.reduce/3` is correct
  but slightly non-obvious; a named `fn acc, kv -> put_generated_slug(acc, kv) end`
  reads more clearly.

---

## Technical correctness

| Check | Result |
|-------|--------|
| Guards result of `slugify/2`, not just input | ✅ |
| Scrubs pre-existing `""` values (self-heal) | ✅ |
| `put_generated_slug/2` arg order vs `Enum.reduce` | ✅ correct |
| Final `Enum.reject … Map.new()` doesn't clobber valid slugs | ✅ |
| No migration needed for fix itself | ✅ |
| Independent of unreleased `put_slug/3` core feature | ✅ |

---

## Stats

- **Tests:** 5 new regression tests in `test/phoenix_kit_ecommerce/empty_slug_test.exs`
  (unit-level changeset tests + 2 DB-level integration tests against the real index)
- **Migrations:** None (by design — self-heal on save)
- **Version bump:** ❌ Missing — needed before Hex publish
- **CHANGELOG entry:** ❌ Missing — needed before Hex publish
- **Dependency changes:** None (no phoenix_kit version change required)

---

## Delta Review (2026-08-14)

**Updated title:** "Empty-slug lockout fix, and put_slug/3 for shipping methods"
**New stats:** +252 / -49 across 6 files (+123 additions / -33 deletions vs original)
**Overall delta verdict:** APPROVE WITH NOTES — unchanged. Shipping method adoption is correct and well-tested. Two hard dependencies now documented below.

### New changes in this update

The PR gained three sets of changes beyond the original commit 1:

1. **`ShippingMethod` — drops local `maybe_generate_slug/1` + `slugify/1`, adopts `Slug.put_slug(:name, max_length: 100)` from core**
2. **`Product` + `Category` — `unique_constraint` name updated from old expression-index names to V171 projection primary-key names**
3. **`import_upsert_test.exs` — "spelling twins" test rewritten to assert V171 blocks the twin insert as a changeset error**

---

### Shipping method adoption — analysis

**Pattern match with Product/Category:** The local generator had two structural bugs:
- Keyed on `get_change(:name)` — renaming a method regenerated its slug and moved it (rename-stability bug)
- `slugify/1` used `~r/[^\w\s-]/` without the `/u` flag — ASCII-only, so Cyrillic names wrote `""`, locking subsequent Cyrillic-named methods via the unique column index — the identical shape as commit 1's product bug

Both are fixed by delegating to `Slug.put_slug/3` from core, which preserves existing slugs and handles romanization + suffixing. The adoption is clean.

**Length cap:** Old code had `validate_length(:slug, max: 100)` before slug generation, so generated slugs could silently exceed 100 chars. The fix passes `max_length: 100` to `put_slug/3` (cap applied _during_ generation) and retains `validate_length` after (caps user-supplied slugs). Belt-and-suspenders, correct.

**No-name edge case:** Nil name cannot reach the slug generator — `validate_required(@required_fields)` runs first. Non-issue.

**Shipping vs Product/Category pattern difference:** Product/Category slugs are JSONB maps (multilingual). Shipping method slugs are plain string columns. `put_slug/3` takes `:name` (string → string). Correctly a different call signature, not a parity error.

**Tests (4 new in `shipping_method_slug_test.exs`):**

| Test | Behavior covered |
|------|-----------------|
| Cyrillic → romanized slug | Core's romanization replaces the empty-producing ASCII-only local slugify |
| Rename does not move slug | `put_slug/3` preserves existing slug on rename |
| Name collision → `-2` suffix | Suffixing via DB roundtrip, not a guess |
| Length cap respected with suffix | `max_length: 100` applies to generated + suffixed slug |

All four directly address the twin bugs fixed. Coverage is sufficient.

---

### New finding — V171 constraint name change (Product + Category)

The original review did not flag the `unique_constraint` name changes because they weren't in the diff at that time. They are now:

- `Product`: `idx_shop_products_slug_primary` → `phoenix_kit_shop_product_slugs_pkey`
- `Category`: `idx_shop_categories_slug_primary` → `phoenix_kit_shop_category_slugs_pkey`

These names reference the **V171 projection table** primary keys. The PR body says the JSONB index redesign is "core-side work (V170 + a lockstep ecommerce change), reviewed separately." If V171 has not run in a given environment, the old constraint names remain active and collision errors will surface as raw `ConstraintError` instead of changeset errors — invisible regression from the operator's perspective. The `import_upsert_test.exs` delta confirms V171 behavior is now expected by the test suite.

**This is a hard deployment dependency**: both ecommerce commits 1 and 2 now require V171 (or the equivalent core migration) to be present in the database before deploying this version.

---

### Dependency gates — updated summary

| Gate | Commit 1 (empty-slug fix) | Commit 2 (shipping put_slug) |
|------|--------------------------|------------------------------|
| V171 projection table | ✅ Required (constraint names changed) | n/a (plain column) |
| `phoenix_kit#711` (core `Slug.put_slug/3`) | Not required | ✅ Required |
| Hex publish | Blocked by version bump + CHANGELOG | Additionally blocked by #711 shipping |

The PR body already calls out the commit 2 gate. The V171 dependency for commit 1 is implicit in the constraint renames — worth confirming with Max that V171 is part of the same core release wave.

---

### Pre-publish checklist (unchanged from original review)

- [ ] `@version` bump — `0.2.1` → `0.2.2` (or `0.3.0` given the shipping method feature)
- [ ] `CHANGELOG.md` — `### Fixed` for empty-slug bug; `### Changed` or `### Added` for `put_slug/3` adoption
- [ ] Confirm V171 and `phoenix_kit#711` land first (or gate the ecommerce release on their tags)

**Merge remains unblocked.** Hex publish remains blocked until the above are resolved.
