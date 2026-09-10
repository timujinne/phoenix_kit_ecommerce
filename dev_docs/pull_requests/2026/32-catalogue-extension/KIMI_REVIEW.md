# Code Review: PR #32 — Catalogue extension: Shop section and embedded schemas for data["ecommerce"]

**Reviewed:** 2026-09-08
**Reviewer:** Kimi Code
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/32
**Head SHA:** 98df7a0 (squash-merged)
**Status:** Merged

## Summary

The PR adds a duck-typed catalogue "extension slot": `Catalogue.Extension`
(key/enabled?/render/cast surface), two embedded schemas (`ItemCommerce`,
`CategoryCommerce`) owning the `data["ecommerce"]` namespace, a
`ShopSections` function-component pair rendering the Shop card in
catalogue's item/category forms, `PhoenixKitEcommerce.catalogue_extensions/0`
as the discovery hook, four test files, and gettext catalogues for the new
strings. The duck-typing requirement is honored (no direct
`PhoenixKitCatalogue` call — only moduledoc references), the embedded
schemas need no `SchemaPrefix`/UUIDv7, `@fields` lists match schema fields
exactly (21/21 and 5/5), and status lists mirror `Product`/`Category`
correctly. Two real problems: the PR reintroduces `"USD"` literals two PRs
after the module deliberately eliminated them, and it ships 32 fuzzy-flagged
gettext entries that are live at runtime — both contradicting the commit
message's own claims.

## Issues Found

### 1. [BUG - MEDIUM] The `"USD"` literal is back — extension-saved items in a non-USD shop silently store USD
**File:** `lib/phoenix_kit_ecommerce/catalogue/item_commerce.ex:31`, `lib/phoenix_kit_ecommerce/catalogue/shop_sections.ex:143`
**Confidence:** 85/100

PR #31 ("no USD literals") and PR #33 are ancestors of this PR, and
`migrations.ex:176` already declares V2 "the last 'USD' literal in the
module". `ItemCommerce` adds `field :currency, :string, default: "USD"` and
the form pre-fills `Map.get(@ecommerce, "currency", "USD")`. Because the
schema default means every save through the extension writes a non-nil
currency, the consumer's base-currency fallback
(`product_source/catalogue/view.ex:94-96`:
`Map.get(ecommerce, "currency") || ... base_currency`) is dead for
extension-saved items — an item created in a EUR shop silently stores and
displays USD. The round-trip test (`item_commerce_test.exs:53`) pins the
wrong contract.

**Fix:** drop the schema default (nil), prefill the form input from
`PhoenixKitEcommerce.get_base_currency/0` (exists at
`lib/phoenix_kit_ecommerce.ex:274`) or leave it blank, and update the test.

### 2. [BUG - MEDIUM] Gettext merged with fuzzy matching — 32 guessed translations live at runtime
**File:** `priv/gettext/{de,et,fr,ru}/LC_MESSAGES/default.po` (e.g. de:4730, ru:4752)
**Confidence:** 90/100

The PR merged gettext **with fuzzy matching enabled**, shipping 8
fuzzy-flagged entries per locale (32 total; all added by this PR, none
pre-existed). AGENTS.md mandates `--no-fuzzy` precisely because "fuzzy
entries are live at runtime" (Gettext 1.0.2 filters only `obsolete`
messages). The guesses are visibly wrong: de "Download limit" →
"Download-Limit:" (stray trailing colon from a different msgid), de
"Requires shipping" → "Erfordert Versand:", de "Charge tax on this item" →
"Steuer für dieses Produkt berechnen" (Produkt vs item). This also
contradicts the commit message's claim the strings were "translated" — the
fuzzy ones were guessed by msgmerge.

**Fix:** re-merge with `--no-fuzzy` and hand-translate or blank the fuzzy
msgstrs.

### 3. [IMPROVEMENT - MEDIUM] `cast/2` silently drops unknown keys under `data["ecommerce"]`
**File:** `lib/phoenix_kit_ecommerce/catalogue/item_commerce.ex:87-104` (same in `category_commerce.ex:53-67`)
**Confidence:** 78/100

`cast/2` silently drops any key in `current` that isn't in `@fields`: merge
→ `changeset` casts only `@fields` → `to_storage_map` emits only schema
fields. The merge deliberately preserves known no-input fields (`shopify`,
`price_modifiers`, `translation_fingerprints`, …), but any *unknown* key
under `data["ecommerce"]` — written by a newer version of this module, a
data migration, or catalogue itself — is wiped by the next form save.

**Fix:** either merge the validated storage map over the original `current`
(`Map.merge(current, storage_map)`), or state explicitly in the moduledoc
that the namespace is exclusively schema-shaped and foreign keys are
discarded.

### 4. [NITPICK] `category/1` missing attr declarations
**File:** `lib/phoenix_kit_ecommerce/catalogue/shop_sections.ex:263`
**Confidence:** 90/100

`category/1` declares only `attr :category`; unlike `item/1` it lacks
declarations for `:form`, `:data`, `:current_language`, which it uses.
Runtime-fine (map access), but the asymmetry loses compile-time
docs/checking for the category section.

### 5. [NITPICK] `maxlength="32"` on price-unit input has no matching validation
**File:** `lib/phoenix_kit_ecommerce/catalogue/shop_sections.ex:212` vs `item_commerce.ex:64-75`
**Confidence:** 85/100

The price-unit input's `maxlength="32"` is client-side only;
`ItemCommerce.changeset/2` has no matching `validate_length`, so
API/programmatic writes bypass the limit. Either add the validation or drop
the attribute.

## What looks good

- Duck-typing is clean: no hard `PhoenixKitCatalogue` reference, no mix.exs
  dep (with a clear comment why), `@behaviour` deliberately not declared.
- Field lists in sync: `@fields` matches schema fields exactly in both
  embedded schemas; statuses/product types mirror `Product` and `Category`;
  validations mirror `Product.changeset/2` as documented.
- The checkbox merge hazard was checked and is correctly avoided: core's
  `Checkbox` component emits a hidden `"false"` input
  (`deps/phoenix_kit/.../core/checkbox.ex:115`), so the params-over-current
  merge can't wedge a checkbox on.
- Error surfacing is well designed and tested: `field_errors/2` filters
  `:data` errors by `extension: "ecommerce"` + `field:`.
- Money discipline is right: `:decimal` fields, decimals stringified for
  JSONB, no floats. Blank `price_unit` language entries are dropped, not
  accumulated, with a pinning test; hidden carry-forward inputs have both an
  assert and a refute test.
- All 31 unit tests + 1 integration test pass on main.

## Unverified surfaces

- **The cross-repo contract with `phoenix_kit_catalogue`.** The package is
  not a dependency (no released version ships the slot), so unverifiable
  from this repo: that catalogue discovers `catalogue_extensions/0`, calls
  `key/0`, `enabled?/0`, `item_section/1`, `category_section/1`,
  `cast_item/2`, `cast_category/2` with these exact signatures; and
  critically that `PhoenixKitCatalogue.Extensions.absorb/3` tags cast
  errors on the `:data` field with `extension:`/`field:` opts in exactly the
  shape `ShopSections.field_errors/2` matches. The tests *fabricate* that
  tagging shape, so a mismatch on catalogue's side reintroduces the "silent
  no-op Save" this PR fixed, invisible to this suite.
- **`current_language` format.** `ShopSections.item/1` defaults it to `"en"`
  while the `price_unit` map comment and tests use dialect keys (`"en-US"`).
  If catalogue passes a plain code while stored keys are dialects, the
  visible input creates a parallel key alongside the hidden carry-forward.
