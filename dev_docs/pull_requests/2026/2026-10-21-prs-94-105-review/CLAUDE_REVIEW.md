# PRs #94–#99, #104, #105 — shipping country lists, order tools, API fixes, cart client token

**Merged:** `8a7c121` (#94), `5411735` (#95), `9d3eb12` (#96), `3491a5e` (#98), `40b4ec3` (#99),
`4ddd9b3` (#104), `fe81ab1` (#105) · **Reviewed:** 2026-10-21, after 0.6.0 (not yet released)

Open drafts #106 and #107 are not covered: a draft is not reviewed until it is ready.

| PR | What | Size |
|---|---|---|
| #94 | "Deliver only to" / "Never deliver to" country lists, a pickup-point provider field, carriers follow the shop switch | 23 files |
| #95 | `ecommerce.list_orders`, `get_orders`, `get_order_customers`, `set_order_sync`, `API.OrderExport` | 20 files |
| #96 | API product and category URLs on the answer's language domain | 12 files |
| #98 | Product page thumbnail strip stays inside the gallery column | 2 files |
| #99 | Public API findings: option labels, facets switch, per-value prices, filter warnings, no replay key on credential tools | 24 files |
| #104 | Cart client token, credentials and error codes declared for the module-neutral core API | 19 files |
| #105 | Wrapping labels on the assistant cart settings | 1 file |

Method: every changed `lib/` file was read against the code around it and the invariants in
`AGENTS.md`; claims were checked against the producer (order line and order metadata keys written
by checkout, billing's order statuses and timestamp type, the search index pair format against the
options filter, `CartOptions.from_item/2` against the claim page, the flow of the shipping form from
provider change to country view). Tests of the touched areas were run against local core and
billing checkouts (`PHOENIX_KIT_PATH`, `PHOENIX_KIT_BILLING_PATH`), because against the Hex billing
the whole order family is excluded (`:billing_order_sync`).

## Findings

### BUG - MEDIUM — #96/#104 `mix precommit` was red on the default build (dialyzer)
Against the released core, dialyzer reported `call_to_missing` for `Routes.canonical_absolute_or_nil/2`
(`API.Context.absolute/3`) and for `RateLimit.check_new_rows/1` (`CartStore`). #96's commit message
says an ignore for the first was added, but `.dialyzer_ignore.exs` has none; #104 changed the
second entry to the "does not exist" wording, which is the form for a missing module, while the
module is loaded and dialyzer words a missing function as "Call to missing or private function".
Neither entry matched. **Fixed:** both entries use the `call_to_missing` text and say when to drop them.

### BUG - MEDIUM — #96 the language-domain test families were never excluded by the test helper
`test_helper.exs` computed `canonical_urls_exclude` (`:core_without_canonical_urls` on a core with
`Routes.canonical_absolute_or_nil/2`, `:requires_core_canonical_urls` on one without) but never
added it to the `exclude:` list, so the side that does not fit the core ran anyway and failed:
the full suite against a current core had one failure
(`absolute/3 ... ignores the host resolver on a core that has no language-domain helpers`), and
against a released core every `:requires_core_canonical_urls` test would. `AGENTS.md` promises
the opposite ("excluded when core lacks / has it"). **Fixed:** `canonical_urls_exclude` is part of
the exclude list; the context tests pass with the helper, the other side is excluded and counted.

### IMPROVEMENT - HIGH — #95 the order export dropped the options the buyer chose
An order line records `selected_specs` (the labels the buyer saw) and, for a line sold from the
catalogue, `selected_spec_keys`. `OrderExport.line/3` exported neither, so an external system
received two sizes or colours of one product as two identical lines (same sku, name and price). The
cart API already exposes options as `attribute_key`/`value_key`/`attribute_label`/`value_label`.
**Fixed:** each product line has `options`, an entry per option with `attribute_key`,
`attribute_label`, `value_label` and, for a keyed line, `value_key` (`nil` for a legacy line, `[]`
for none). Additive; the moduledoc, README and CHANGELOG say so. Test: keyed, legacy and plain
lines in `order_export_test.exs`.

### IMPROVEMENT - MEDIUM — #95 a Legacy-source order line has no product identifier in the export
`product_id` comes from the order line's `catalogue_item_uuid`, which checkout writes only for a
catalogue-backed line; a line of the Legacy product source records no product uuid at all (only the
`sku`), so its `product_id` is `nil` and `external_id`/`unit` are absent. **Not fixed:** it needs
the order-line writer to record the legacy product uuid (a checkout change, and older orders would
still have none). On record so a consumer of the export knows to match Legacy lines by `sku`.

### NITPICK — #104 `CartTools` moduledoc had a 150-character run-on line
**Fixed:** reflowed.

## Checked and clean

- **#94** `serves_country?/2` (case-insensitive on both sides, blank country passes, an allow-list of
  only invalid codes serves nobody) and every other reader of the lists (`available_for?/2`, the cart
  API's `country_not_served`, `checkout_countries/0`); the changeset normalises, drops unknown codes,
  turns NULL into `[]`, refuses a country in both lists and stays out of a list that is already an
  error; the form posts a blank entry so an emptied list is a value, keeps a ticked row for a stored
  code with no checkbox, and recomputes the country view after every provider change
  (`validate` → `sync_provider` → `assign_form_errors`); `open_countries` only changes UI state, so it
  needs no `Authz` gate; the pickup-point picks go through the same `Authz`-gated `pick_locality`,
  by id, against the results on screen; the carriers' integrations are hidden only on an explicit
  `"false"` and the provider cache is cleared on both toggles.
- **#95** statuses match billing's `@valid_statuses`; `updated_at` is `:utc_datetime`, so the
  `(updated_at, uuid)` cursor and `updated_since` truncation agree; the cursor is validated field by
  field; contacts, the delivery address and `notes` are gated by `contacts?/1` in every section;
  `get_order_customers` is the only tool that forces them and declares the scope; a dry run writes
  nothing and fingerprints the revisions it read; a database failure on one row is that row's
  retryable `database_error`; the log carries the class of a failure, never its text; `price_on_request`,
  `taxable` and the pay-on-delivery flag are read from the order's own snapshot.
- **#96** one resolver call per link; falls back to the request's host on `nil` or on a core without
  the helper.
- **#98 / #105** CSS only; the two `product-thumbnails` ids are in mutually exclusive branches.
- **#99** the option probe uses the same `key:value` pair format as the filter; the batch
  vocabulary memo is cleared in `after`; the `facets: false` path skips the pass and the truncation
  warning; the claim page reads labels through `CartOptions.labelled/3` and
  `SelectedSpecs.labels/1`; `replay: false` is declared only on a core that has the marker.
- **#104** `client_token`/`credentials` are set only where `Tool` has the fields; the quota call
  uses `check_new_rows/1` when exported and the old name through `apply/3` otherwise.

## Gate

`mix precommit` clean on the default (Hex) build. Full suite against local core and billing
(`PHOENIX_KIT_PATH`, `PHOENIX_KIT_BILLING_PATH`): 4689 tests, 1 failure before the test-helper fix
(the canonical-URL one above), none after it on the files touched. The `:catalogue`-tagged suite was
not run.
