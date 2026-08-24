# Code Review: PR #21 — Empty-slug lockout fix, and put_slug/3 for shipping methods

**Reviewed:** 2026-08-14
**Reviewer:** Grok (grok-4.6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/21
**Author:** Max Don (mdon)
**Head SHA:** `09434799bc17f1258b8cd4c563b17f6c9d5e0af3`
**Merge commit:** `8e59f78`
**Status:** Merged

## Summary

Three commits, all real:

1. Product and Category stop writing `""` when `Slug.slugify/2` cannot romanize
   the title. The old `extract_primary_slug` index was partial only on
   `IS NOT NULL`, so the first CJK-only product took the empty key and the
   second could not be inserted.
2. Shipping methods drop the local generator (keyed on `get_change(:name)`,
   ASCII-only slugify) and adopt core's `Slug.put_slug/3`.
3. `unique_constraint` names follow V171's projection primary keys, so a
   collision is a changeset error on `:slug` instead of a raw Postgrex error.

The diagnosis is correct and the tests fail against the old code. What the PR
did not do is finish the URL, name the core floor it now depends on, or keep
the third copy of the same reduce from landing.

## Issues Found

### 1. [BUG - HIGH] `:phoenix_kit` floor admitted cores without `put_slug/3` and without V171 — FIXED

**File:** `mix.exs`
**Confidence:** 95/100

`ShippingMethod.changeset/2` calls `PhoenixKit.Utils.Slug.put_slug/3`, added
in core **2.4.0**. Product and Category name
`phoenix_kit_shop_{product,category}_slugs_pkey`, which exist only after
**V171 / core 2.6.0**. The pin stayed `~> 2.0`.

Core's own 2.4.0 note says this outright: adopters must pin `~> 2.4` or the
failure lands in the consumer's app. Same shape as
`phoenix_kit_publishing` PR #41. A host resolving 2.0–2.5 compiled, then
either raised `UndefinedFunctionError` on every shipping-method save or
turned a product slug collision back into a raw `Postgrex.Error`.

**Fix:** floor raised to `~> 2.6` (two-segment, so later 2.x still resolve).
`core_pin_conformance_test.exs` updated to the new floor. `dependency_floor_test.exs`
now asserts `put_slug/3` and `ShopSlugProjection` exist on the resolved core.

### 2. [BUG - HIGH] CJK shipping-method names cannot be inserted — FIXED

**File:** `lib/phoenix_kit_ecommerce/schemas/shipping_method.ex`
**Confidence:** 95/100

`phoenix_kit_shop_shipping_methods.slug` is `NOT NULL` (V135). `put_slug/3`
deliberately leaves the changeset alone when `slugify` returns `""`, which is
the documented contract for a nullable column. Against this table it is a
`not_null_violation` on insert. The PR's tests only covered Cyrillic (which
romanizes), so a Japanese shop creating "店舗受取" could not save the method
at all.

**Fix:** `LocalizedSlug.put_plain_fallback/3` after `put_slug/3` writes the
same stable `item-<hash>` used for products, suffixing `-2` on collision.
Caught by a test that inserts two CJK names — it raised on the first row.

### 3. [BUG - HIGH] Unromanizable titles had no storefront URL — FIXED

**File:** `lib/phoenix_kit_ecommerce/schemas/product.ex`,
`lib/phoenix_kit_ecommerce/schemas/category.ex`
**Confidence:** 90/100

The PR's generator kept only non-empty results, so a CJK-only title wrote
`%{}`. That fixes the lockout. It also means `SlugResolver.product_slug/2`
returns `nil` and `Shop.product_url/2` interpolates it into `/shop/product/`.
The catalog card is a dead link. The parity test for PR #18 already named
this symptom: *"a category with no URL at all."*

AI translation already had a fallback for the same empty result. The
changeset path — every create and every CSV upsert — did not.

**Fix:** unromanizable text now gets a stable `item-<sha256>` fallback, so
two different CJK titles never share a key and the same title always
produces the same slug (and therefore still collides, correctly, like two
products named "Hat").

### 4. [BUG - MEDIUM] `SlugResolver` treated `""` as a real slug — FIXED

**File:** `lib/phoenix_kit_ecommerce/slug_resolver.ex`
**Confidence:** 90/100

`""` is truthy. `localized_slug/2` did `slug_map[lang]` and returned the
empty string, so a legacy `%{"en" => ""}` row — even one that also had a
German slug — produced `/shop/product/` instead of falling through.

**Fix:** skip blank values; fall through to another language or `nil`.

### 5. [IMPROVEMENT - MEDIUM] Duplicate `put_generated_slug/2` — FIXED

**File:** Product and Category
**Confidence:** 85/100

Identical private function in both schemas. Product and Category have
already drifted twice on this exact reduce (Cyrillic, then German). PR #21
would have been the third copy.

**Fix:** `PhoenixKitEcommerce.LocalizedSlug` owns the reduce, the empty
guard, the fallback, and the leftover-`""` scrub. Both changesets call
`maybe_generate/2`.

### 6. [NITPICK] Comments still described the index V171 replaced — FIXED

Product, Category, `empty_slug_test.exs`, and `category_test.exs` still
talked about `extract_primary_slug` and `idx_shop_*_slug_primary` after
commit 3 retargeted the constraints. Trimmed.

## What Was Done Well

- The lockout is a real, reproduced production bug, not a hypothetical.
- Shipping adoption matches the rest of the `put_slug/3` series: rename
  stability, romanization, suffixing, length cap *during* generation.
- The V171 test rewrite is honest — it stops pinning behaviour the
  projection deliberately outlaws, and asserts the refusal instead.
- Tests were written to fail against the old code (verified by the author
  by stashing). That is the right kind of regression test.

## Verdict

Approved with fixes — applied on `main`. Released in **0.2.2**.
