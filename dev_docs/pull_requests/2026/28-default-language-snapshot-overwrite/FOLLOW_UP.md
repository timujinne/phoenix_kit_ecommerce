# PR #28 follow-up — mount-time snapshot overwriting default-language edits

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - CRITICAL** saving a product wiped the default language's
  `body_html`, `seo_title` and `seo_description`~~ — `merge_field_value/4`
  treats `{:ok, nil}` as not submitted
  (`web/components/translation_tabs.ex:445-461`), and both forms build
  `default_values` with `Map.take/2` over the translatable fields
  (`web/product_form.ex:2493`, `web/category_form.ex:1051`). Regression test:
  `test/phoenix_kit_ecommerce/translation_tabs_test.exs`.

## Skipped (with rationale)

- **#2 OBSERVATION** the snapshot's default-language entry is no longer a merge
  input — a note for a future change that makes that tab editable; nothing to
  fix.

## Open

None.
