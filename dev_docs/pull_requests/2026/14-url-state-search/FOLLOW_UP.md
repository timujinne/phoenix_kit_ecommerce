# PR #14 follow-up — list state in the URL

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - HIGH** a non-UUID `?parent=` / `?category=` crashes the list
  LiveView~~ — both values are re-parsed in `handle_url_state/2` through
  `Ecto.UUID.cast/1`: `web/categories.ex:77` + `parse_parent_filter/1`
  (`:232-241`, `"root"` kept), `web/products.ex:89` + `parse_category_uuid/1`
  (`:784-791`). Tests: `test/phoenix_kit_ecommerce/web/listing_lvs_test.exs:45`,
  `:75`, `:81`.

## Skipped (with rationale)

- **#2 OBSERVATION** the PR shipped no URL-state tests — the three tests above
  cover the crash; wider URL-state coverage was not audited in this pass.
- **#3 NITPICK** Categories publishes `?q=` (`web/categories.ex:16`), Products
  `?search=` — still so. Cosmetic; Products already published `?search=` links.
- **#4 OBSERVATION** `Categories.mount/3` still calls
  `load_static_category_data/1` (`web/categories.ex:60`) — left alone
  deliberately by the reviewer, with the reason recorded in the review.

## Open

None.
