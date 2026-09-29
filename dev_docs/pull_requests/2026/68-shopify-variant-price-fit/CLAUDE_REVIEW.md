# PR #68: Shopify variants — read every variant, fit prices never cheaper than Shopify, show approximations

- **Author:** Tymofii Shapovalov
- **Reviewer:** Claude
- **Merged as:** `3404e50`
- **Verdict:** correct as merged. One efficiency finding was fixed after the
  merge. Two nitpicks are recorded here and were deliberately not changed.

## Summary

Four changes that depend on each other:

1. **`AdminClient` re-reads capped variant lists.** Shopify's REST product
   payload embeds at most 100 variants. Any product at that cap is now
   re-read from `products/{id}/variants.json`, four at a time
   (`Task.async_stream`). A product whose re-read fails, or was never
   requested, comes back flagged `"_variants_incomplete"`. Callers pass
   `:complete_variants` (`true` / `false` / a predicate) to choose which
   capped products get re-read.
2. **Consumers refuse flagged products.** `ProductDiff` compares no price
   for a flagged product and never offers one as a new product. The media
   sync worker's `"variants"` kind refuses a flagged product with its own
   error entry.
3. **`VariantMapper.build/2` fits prices by rule.** Under `:never_cheaper`
   (the default), one option whose value is on every priced variant
   absorbs the shortfall. The candidate with the least total overcharge
   wins, and a tie goes to the lower Shopify position. `:cheapest` keeps
   the plain min-based modifiers. The fit is measured against the item's
   own `base_price`, so a base that drifted from Shopify's cheapest
   variant shows up as `:base_offset` instead of being reported as an
   approximation.
4. **The fit is surfaced.** It is stored on the item
   (`data.ecommerce.shopify.price_fit`) and deleted again once the fit is
   exact. The item form gets a rule selector and a note. The run record
   gets a separate `"warnings"` list (no longer mixed into `"errors"`), an
   `"approximated"` stat, and a paged warnings list on the sync page.

## Checks

- **The never-cheaper guarantee holds.** For the absorber `a`, each
  priced variant predicts `min_all + Σ_{o≠a} M_o + A(v_a)`, and `A(v_a)`
  is at least that variant's residual. So every prediction is at least
  its Shopify price. The eligibility rule (every priced variant has a
  value for `a`) is what makes this hold. Without it, a variant missing
  the value would fall into no `A(v)` group.
- **`Enum.min_by(…, Decimal)` sorts correctly.** It dispatches to
  `Decimal.compare/2`, not structural term order.
- **Predicates run in the caller.** `complete_all/4` evaluates `wanted`
  before it spawns anything. Tasks capture only `req` and `shop_domain`,
  so the media worker's item index is never copied into them.
  `Req.Test` stubs still resolve inside the tasks through `$callers`.
- **Concurrency is bounded.** It is `@backfill_concurrency`.
  `timeout: :infinity` is bounded in practice by `fetch_all/5`'s own
  retry cap.
- **Refusal happens before the currency verdict.** In
  `apply_writer("variants", …)`, `Writer.sync_variants/3` is never
  reached for a flagged product.
- **Every consumer checks one key.** `ProductDiff`, the worker and the
  writer all go through `AdminClient.variants_incomplete?/1`.
- **`fetch_product/3` always completes the list.** So the single-product
  check never works from a truncated list.
- **Storefront price.** `ProductSource.Catalogue.View` prices from
  `item.base_price` directly, with no markup. Measuring the fit against
  `base_price` therefore matches what the shopper pays.
- **Stale notes can't outlive their price.** An exact fit deletes
  `price_fit`.
- **Gettext.** Every new msgid is translated in de/fr/et/ru, and Russian
  plurals have all three forms. No fuzzy flags were added.
- **Out-of-scope count.** `new_product_changes/5` now scopes before it
  builds, so a capped out-of-scope product (flagged `:not_requested`)
  still counts as out of scope. The PR's catalogue test pins this.

## Findings

### IMPROVEMENT - MEDIUM — `Sync.check/2` re-read capped newcomers under the Legacy source (fixed)

The predicate `put_complete_variants/4` builds for the Admin client was
"matched handle **or** in scope". Only the catalogue source builds
new-product changes, though (`new_product_changes/5` returns `{[], 0}`
under Legacy). Under Legacy, then, every capped unmatched in-scope product
was re-read for a price nothing ever reads. Under the default
`mode: :all` scope, that is every capped product in the store. The PR's
own measurement was 68 of them, about 62 s sequential or about 16 s at
concurrency 4, spent on every Legacy check.

**Fix:** the in-scope branch now also requires
`ProductSource.current() == ProductSource.Catalogue`. That is the same
condition `new_product_changes/5` uses. `SyncTest`'s predicate test (Legacy
source) now refutes the in-scope newcomer's re-read. A new
`SyncCatalogueTest` case pins that under the catalogue source the capped
in-scope newcomer is re-read, the capped out-of-scope product is not, and
the out-of-scope count still includes the latter.

### NITPICK — the `":not_requested"` marker is matched by string in `ProductDiff` (not changed)

`ProductDiff.creatable?/1` compares `shopify_product["_variants_incomplete"]`
against `inspect(:not_requested)` directly. The key and the value both
duplicate private details of `AdminClient`. A
`variants_not_requested?/1` beside `variants_incomplete?/1` would keep the
two in one place. It is not changed because the only effect of drift is a
logged warning's wording (both branches return `false`), and the PR's
tests pin the current marker.

### NITPICK — the base-offset note shows a signed amount without naming a direction (not changed)

"The base price was -5.00 off Shopify's cheapest variant" is readable,
but "off" hides that a negative offset means the storefront is
*cheaper*. It is left as is: the note already names the one place that
fixes it, and the sign is accurate.

## Validation

- `mix precommit` — clean (compile `--warnings-as-errors`, format,
  `credo --strict`, dialyzer).
- `mix test` — 1522 tests, 0 failures (270 excluded).
- `:catalogue` suite through the path bridge (`PHOENIX_KIT_PATH`,
  `PHOENIX_KIT_CATALOGUE_PATH`, `PHOENIX_KIT_ENTITIES_PATH`) — 270 tests,
  0 failures. Against Hex core 2.37.5 instead, the sibling catalogue
  checkout fails 21 image-attachment tests. It calls core APIs that 2.37.5
  does not ship (`Storage.ResourceFolders`, `PhoenixKitWeb.Attachments`).
  That is skew between the sibling checkouts, unrelated to this PR.
