# PR #49 follow-up — category featured-item image on the catalogue source

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - HIGH** missing duck-type compile guard broke `mix precommit`
  without the optional catalogue dependency~~ —
  `@compile {:no_warn_undefined, PhoenixKitCatalogue.Paths}`
  (`web/helpers.ex:15`).
- ~~**#2 BUG - HIGH** a struct literal broke test compilation without the
  optional dependency~~ — `struct!/2`
  (`test/phoenix_kit_ecommerce/catalogue/shop_sections_test.exs:126`); no
  `%PhoenixKitCatalogue.…{}` literal remains under `test/`.
- ~~**#3 BUG - MEDIUM** four catalogue-only tests carried no `:catalogue`
  tag~~ — `test/phoenix_kit_ecommerce/web/storefront_admin_edit_test.exs:149`,
  `:209`, `:253`, `:277`.

## Open

None.
