# PR #40 follow-up — tags only on the default-language storefront

Triage of `KIMI_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - MEDIUM** tags vanished when the default is a non-canonical
  dialect~~ — `tags_visible?/1` compares `DialectMapper.extract_base/1` on both
  sides (`web/helpers.ex:227-237`).
- ~~**#2 IMPROVEMENT - HIGH** the test did not pin the bug~~ —
  `test/phoenix_kit_ecommerce/web/catalog_product_tags_test.exs` configures the
  default as `"en"` (`:25`) and asserts `"en-US"` and `"en"` (`:35-36`), plus an
  `"en-GB"` default (`:50-62`).

## Skipped (with rationale)

- **Unverified surfaces** (tags in SEO metadata, the catalogue view path) —
  raised as questions, not findings; not audited in this pass.

## Open

None.
