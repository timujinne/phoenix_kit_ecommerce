# PR #69: Require every option a catalogue product offers before it can be carted

- **Author:** Tymofii Shapovalov
- **Reviewer:** Claude
- **Merged as:** `83dd6c4`
- **Verdict:** correct as merged. One pre-existing untranslated flash on
  the path the PR touched was fixed after the merge. One behaviour change
  of the public API is recorded for the CHANGELOG, and one nitpick was
  deliberately not changed.

## Summary

The live defect: a catalogue product at base 35.52, where every liquid
colour costs +32.00, was headlined at 35.52 and carted at 35.52 with no
colour chosen. Two gaps allowed it:

1. **Discovered options were never required.** An option that comes from
   the product's own `_option_values` (the catalogue attribute sets, or
   an imported product's options) now gets `"required" => true`. The
   price-affecting discovery is now the priced subset of the selectable
   discovery (`discover_options_from_metadata/1` filters
   `discover_selectable_options_from_metadata/1`), so the two lists can't
   disagree on a key.
2. **An empty selection skipped validation.** `add_to_cart/4` validates
   an empty `selected_specs` too, in both clauses. `:skip_spec_validation`
   is still the only opt-out.

Round 1 of the PR fixed a shadowing case. An admin's price-neutral,
optional schema option with the same key as a discovered priced option
won on the picker, while the price list kept the discovered, required
+32.00 spec. `require_keys_priced_as_required/2` now marks a picker key
required whenever the price list's spec for that key is required. The
option schema is read once for both lists. The product page also shows
a context-side `:missing_required_option` by its label instead of its key.

## Checks

- **The only caller is the product page.** `rg add_to_cart` finds
  `Web.CatalogProduct` and the `compat/` delegate, and nothing in the
  sibling checkouts. The page already refuses a missing required option
  itself (`validate_required_specs/2`), so the context check only fires
  when options changed after mount. `labelled_detail/3` re-reads the
  product's current specs for that reason. That is one extra query, and
  only on the error branch.
- **The headline is now a price the shopper can actually pay.**
  `build_default_specs/2` starts a required select on its first value.
  The "From" range (`Options.get_price_range/3`) already added each
  option's minimum modifier, so it assumed every priced option would be
  chosen. Making them required brings the cart into line with the price
  the range already advertised.
- **`""` can't satisfy a required option.** `validate_required_options/2`
  only checks that the key is present. But `""` is not in any non-empty
  `"options"` list, so `validate_spec_values/2` refuses it first
  (`:invalid_option_value`).
- **Admin intent is preserved.** A price-affecting schema option is on
  both lists, so its own `required` flag decides. A slot-resolved option
  keeps the slot's flag. Tests pin both.
- **No extra queries per product.** `get_selectable_specs_for_product/1`
  now also computes the price list, but it reuses the one schema read.
  The rest (filtering, discovery) is pure.
- **Nothing else re-validates existing lines.** `update_cart_item/2`,
  cart merge and checkout never call `validate_selected_specs/2`, so
  lines already in carts are not suddenly refused.

## Findings

### IMPROVEMENT - MEDIUM — `add_to_cart(cart, product, qty)` now refuses products with metadata options (recorded, CHANGELOG)

This is the intended fix, but it changes the public, scope-less API. A
host that adds a product through the context without `:selected_specs`
used to get a bare line. It now gets
`{:error, :missing_required_option, key}` for any product whose metadata
lists option values. That includes Legacy products from CSV imports, not
only the catalogue source. No caller in this repo or the sibling
checkouts is affected. The CHANGELOG entry flags it for hosts, and
`:skip_spec_validation` is still available for trusted callers that
really mean to cart a bare line.

### NITPICK — the page's own "Please select:" flash was not translated (fixed)

`do_add_to_cart/1` built `"Please select: #{labels}"` from a raw string.
The PR localised the context-side message on the same failure. This
page-side message is the one shoppers actually see, and it stayed
English in every locale. It is now
`gettext("Please select: %{options}", …)`, extracted and translated in
de/fr/et/ru, merged with `--no-fuzzy`.

### NITPICK — CSV-imported single-variant Shopify products now record "Title: Default Title" (not changed)

Shopify's CSV export gives a variant-less product `Option1 Name =
Title`, `Option1 Value = Default Title`. The live sync skips that
placeholder (`VariantMapper`'s `@default_option_names`), but the CSV
`OptionBuilder` does not. So such products carry
`_option_values: %{"title" => ["Default Title"]}`. The product page
already rendered this as a one-value picker before this PR. Now that
the option is required, the value is pre-selected and stored on the
cart line. Nothing is mispriced and nothing is refused. It is not
changed here: the fix belongs in the CSV importer, and it would not
clean products that were already imported.

## Validation

- `mix precommit` — clean (compile `--warnings-as-errors`, format,
  `credo --strict`, dialyzer).
- `mix test` — 1544 tests, 0 failures (272 excluded). The first run,
  against the PR as merged, had one failure:
  `StorefrontClientTest` `:page_delay_ms` (`elapsed_ms < 300`, got 737).
  It is a wall-clock assertion that failed while a parallel compile was
  loading the machine. It passed on the re-run and is unrelated to this
  PR.
- `:catalogue` suite through the path bridge (`PHOENIX_KIT_PATH`,
  `PHOENIX_KIT_CATALOGUE_PATH`, `PHOENIX_KIT_ENTITIES_PATH`) — 272 tests,
  0 failures. `mix.lock` was restored afterwards.
