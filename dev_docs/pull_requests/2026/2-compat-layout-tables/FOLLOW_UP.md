# Follow-up Items for PR #2

Triaged against `main` on 2026-06-04 as part of the quality sweep.
Review: `CLAUDE_REVIEW.md` (claude-opus-4-6, 2026-03-30). Findings are
grouped by current status below; each was re-verified against the code
that ships today, not the state at review time.

## Fixed (pre-existing)

- ~~**#1 `erl_crash.dump` committed to git history (BUG - CRITICAL)**~~ —
  removed post-merge via `git filter-repo` + force push; `.gitignore`
  already carries the entry. Verified the file is absent from the tree.
- ~~**#2 Missing admin auth check on individual category delete
  (BUG - MEDIUM)**~~ — `lib/phoenix_kit_ecommerce/web/categories.ex:103`
  now wraps the individual `delete` handler in
  `Scope.admin?(socket.assigns.phoenix_kit_current_scope)`, matching the
  bulk handlers at lines 174/192/211. Fixed pre-existing (commit
  `ceab14a`).
- ~~**#3 Raw HTML empty-state rows instead of table components
  (BUG - MEDIUM)**~~ — both
  `lib/phoenix_kit_ecommerce/web/shipping_methods.ex:131-137` and
  `lib/phoenix_kit_ecommerce/web/import_configs.ex:324-330` now use
  `<.table_default_row>` + `<.table_default_cell colspan=...>`. No raw
  `<tr><td>` remains. Fixed pre-existing (commit `ceab14a`).
- ~~**#4 Weight formatting inconsistency (BUG - MEDIUM)**~~ —
  `shipping_methods.ex:229` and `carts.ex:255` both now use
  `"#{Float.round(grams / 1000, 1)} kg"`; the integer-division
  `div(grams, 1000)` is gone. Fixed pre-existing (commit `ceab14a`).

## Fixed (this sweep — 2026-06-04)

- ~~**#7 Silent fallback on tax-rate parse failure (NITPICK)**~~ —
  `lib/phoenix_kit_ecommerce.ex` now logs a warning before falling back
  to `0` on a malformed `billing_default_tax_rate` setting, in both the
  decimal parse path (`:2791`) and the integer parse path (`:2812`).
  Previously the helpers fell back / raised silently on a non-numeric
  settings value. Commit *"Address PR review follow-ups (tax logging,
  compat marker)"* (`102acb9`).

## Skipped / Deferred (with rationale)

Max is away and granted full autonomy for this sweep. The items below
are cosmetic or carry a behavioral/product decision; none is a
correctness bug, and each is safer reviewed in a focused PR than folded
into a quality sweep.

- **#5 Category translation preload missing in products mount
  (NITPICK)** — low confidence (70/100) in the review. `products.ex`
  renders category names through `Translations.get(category, :name,
  @current_language)`, which resolves against the loaded translation
  map; the visible C0 baseline shows correct names. Adding an eager
  preload is a query-shape change with no observed defect; deferred for
  a focused review rather than changed blind.
- **#6 Hardcoded `$` currency symbol in price fallback (NITPICK)** —
  still live, scoped to the nil-currency edge case only:
  `lib/phoenix_kit_ecommerce/web/products.ex:887` and
  `lib/phoenix_kit_ecommerce/web/carts.ex:248` emit `"$#{...}"` *only*
  in the `format_price(price, nil)` / no-currency branch (the normal
  `format_price(price, currency)` path renders the configured currency).
  Picking a locale- or config-aware fallback symbol is a product
  decision (what should a price with no currency configured display?);
  deferred so the boss can decide the fallback behavior rather than
  having a sweep guess it.
- **#8 No max-size validation on import-config keyword lists
  (NITPICK)** — still live: `import_configs.ex` accepts unbounded
  `include_keywords` / `exclude_keywords` / `category_rules` (each
  rendered via `length(...)` but never capped). Admin-only page, so the
  risk is low. Choosing a cap is a product decision (what is a
  reasonable maximum?); deferred for that reason rather than imposing an
  arbitrary limit during the sweep.

## Files touched

| File | Change |
|------|--------|
| `lib/phoenix_kit_ecommerce.ex` | Log a warning on tax-rate parse failure before the `0` fallback (decimal + integer paths) |

## Verification

`mix precommit` green — compile (warnings-as-errors), `mix format`,
`credo --strict`, and `dialyzer` (0 errors; "Unnecessary Skips: 1" is a
stale entry in `.dialyzer_ignore.exs`, not a failure). `mix test` — 126
tests, 0 failures.

## Open

None. The three deferred items (#6 `$` fallback, #8 keyword cap, and
the #5 preload) are surfaced for Max as candidates for a focused
follow-up PR — each is gated on a product/behavioral decision, not
parked work.
