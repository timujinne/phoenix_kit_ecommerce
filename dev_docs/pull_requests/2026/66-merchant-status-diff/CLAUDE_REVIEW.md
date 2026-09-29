# PR #66: Diff the merchant status a sync writes, not the one the storefront shows

- **Author:** Tymofii Shapovalov
- **Reviewer:** Claude
- **Merged as:** `b86d8b2`
- **Verdict:** correct as merged. Three findings addressed post-merge, one
  recorded and deliberately not fixed.

## Summary

`ProductDiff.build_change/4` compared `product.status`. Under the catalogue
source that is a DERIVED value — `ProductSource.Catalogue.View.product_status/2`
forces `"archived"` whenever the catalogue retired the item — while
`Sync.apply_change/3` writes `shop_status`. Read one field, write another:
a retired product whose stored merchant status already equalled Shopify's
was reported as differing and stayed reported through every apply.

The PR adds a virtual `:merchant_status` to `%Product{}`, fills it from
`data["ecommerce"]["shop_status"]` in the catalogue view, and compares that
instead, falling back to `:status` (nil under the legacy source, where
`:status` IS the merchant status).

## Checks

- **The trigger is real and the fix reaches it.** Verified end to end:
  `Sync.check/2` loads products through `Shop.list_products/0`, which under
  the catalogue source reaches `View.product_view/2` via
  `ProductSource.Catalogue.build_products/2`. `Sync.check_one/3` goes
  through `Shop.get_product/1` → `build_product/2` → the same
  `product_view/2`. Those two are the ONLY producers of a `%Product{}` under
  the catalogue source (`struct(Product, …)` appears at `view.ex:120` and, as
  a featured-image stub never diffed, at `view.ex:185`), so no diffed product
  can reach `ProductDiff` with `:merchant_status` unset by accident.
- **The apply side really does write what the diff now reads.**
  `Writer.maybe_put_shop_status/2` (catalogue) and `apply_legacy_change/2`
  (legacy) write exactly the field each source's `merchant_status` reads.
- **No other consumer depended on the old meaning.** `changes[:status]`
  is read for `:incoming` by the writer and for display by
  `Web.ShopifySync` (`@row.current`); nothing branches on it.
- **The other comparable fields are symmetric already.** `price` ↔
  `item.base_price`, `description` ↔ `_summary`, `title`/`body_html` ↔ the
  language buckets plus the primary column, `vendor`/`tags`/
  `compare_at_price` ↔ the same `data["ecommerce"]` keys. `status` was the
  only asymmetric one.
- **The value domain matches its sources of truth.**
  `["draft", "active", "archived"]` agrees with `ItemCommerce`'s
  `shop_status` domain, `ShopStatusColumn`'s `@item_shop_statuses` and
  `Writer.shopify_shop_status/1`; the `"active"` fallback for an absent
  value agrees with `Query`'s `COALESCE(shop_status, 'active')`.
- **The virtual field is inert everywhere else.** Ecto ignores it on insert
  and update, `Product.changeset/2` does not cast it, `@type t` is
  `%__MODULE__{}`, and nothing in the repo enumerates `__schema__(:fields)`
  for `Product`.
- **Suites:** `mix test` 1473/0, `mix test --only catalogue` (path bridge)
  251/0, `mix precommit` clean.

## Findings

### 1. IMPROVEMENT - HIGH — the regression guard did not run without a database

`test/phoenix_kit_ecommerce/shopify/product_diff_merchant_status_test.exs`
used `PhoenixKitEcommerce.DataCase`, which tags the file `:integration`.
Every test in it is pure — hand-built structs, an explicit `base_locale`
so `diff/4` never reaches `Translations.default_language/0`, no `Repo`
call — so all seven tests that pin the live defect were excluded on any
machine without Postgres, which is precisely the fresh-checkout case the
repo's two-tier suite exists to serve. `product_diff_test.exs`, the pure
tests for the same module, already uses `ExUnit.Case`.

**Fixed:** switched to `use ExUnit.Case, async: true` with a comment
recording why. Verified pure: the seven now run and pass under
`--exclude integration`, with no sandbox checkout — a `Repo` call would
raise "cannot find ownership process" there.

### 2. BUG - MEDIUM — an incoming status the apply cannot land still produced a change

`maybe_put(:status, merchant_status(product), shopify_product["status"], only)`
reported a difference for ANY incoming value, but
`Writer.shopify_shop_status/1` coerces anything outside
`["draft", "active", "archived"]` to `"draft"`. A status Shopify returned
in some other shape (an uppercase `"ACTIVE"`, a future value, an absent
key) would therefore be offered as an apply that silently RETIRES the
product to draft and still leaves the two sides differing on the next
check — the same never-converging shape this PR exists to remove, arriving
from the write end instead of the read end. Not reachable today
(`AdminClient` uses the REST product endpoint, whose `@product_fields`
always asks for `status` and which answers in lowercase), which is why it
is MEDIUM and not HIGH; it is the third incident of this class in three
PRs (#63, #66), so the class is worth closing rather than documenting.

**Fixed:** `maybe_put_status/4` skips a `:status` comparison whose incoming
value is not one the apply can store faithfully. Ignoring an unknown status
is strictly better than acting on it. Three tests added, including that the
rest of the diff is unaffected.

### 3. NITPICK — documentation drift

`ProductDiff`'s moduledoc listed `status` among the compared fields without
saying WHICH status, and `Product`'s moduledoc field list omitted
`merchant_status` although the field itself carries a seven-line comment.
A reader arriving at either moduledoc — the entry point for both modules —
learned nothing about the distinction the PR turns on.

**Fixed:** both moduledocs now name it and point at each other.

### 4. Observation — a catalogue-retired item is now silent, deliberately not changed

After this PR, a product Shopify considers `active` that the catalogue has
retired reports no status difference at all (its stored merchant status
already agrees). That is the intended behaviour — visibility is the
catalogue's call, not Shopify's — but it also means the sync page no longer
shows the operator anything about products Shopify believes are live and
the storefront hides. Before the PR that showed up, misleadingly, as a
permanent `archived -> active` row.

**Not fixed.** Surfacing it properly is a new panel ("live in Shopify,
retired in the catalogue"), not a diff change, and inventing a fourth
report shape inside a bug-fix review is exactly the scope creep that
produced the two-values-meant-to-agree problem in the first place. Recorded
here so the limitation is on record.
