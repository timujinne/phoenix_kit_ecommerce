# PR #31 follow-up — currency hygiene

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - HIGH** the `"USD"` literal survived as the column default~~ —
  V2 drops the default on the four `currency` columns (`migrations.ex:217`),
  and `test/test_helper.exs:100` applies the module chain.
- ~~**#2 BUG - HIGH** `create_cart/1` could fail and both storefront callers
  hard-matched `{:ok, cart}`~~ — both use `case`
  (`web/cart_page.ex:66`, `web/catalog_product.ex:498`). Regression test:
  `test/phoenix_kit_ecommerce/regression/cart_without_default_currency_test.exs`.
- ~~**#3 BUG - MEDIUM** a comment justified the change with a validation that
  does not run~~ — the comment now says the changeset does not reject it
  (`web/shipping_method_form.ex:41-47`).
- ~~**#4 / #5 NITPICK** stale `(default: USD)` doc and stale
  `validate_cart_currency/2` comment~~ — neither string remains.

## Skipped (with rationale)

- **#6 OBSERVATION** `maybe_set_default_currency/1`
  (`lib/phoenix_kit_ecommerce.ex:1566-1572`) raises on a keyword list — still
  so; no caller passes one, and the reviewer left it deliberately.

Note: a `"USD"` fallback written later, in `Catalogue.Writer`, is tracked
under the 0.5.0 release sweep rather than here; it is not one of this PR's
four fields.

## Open

None.
