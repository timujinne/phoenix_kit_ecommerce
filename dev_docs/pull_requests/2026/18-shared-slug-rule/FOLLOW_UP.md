# PR #18 follow-up — one slug rule for products and categories

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - MEDIUM** the German table applied to every language~~ — N/A in
  current code: `lib/phoenix_kit_ecommerce/slugify.ex` no longer exists (PR #19
  deleted it), and slugs are generated per language through core,
  `Slug.slugify(text, locale: lang, transliterate: true)`
  (`localized_slug.ex:106`).
- ~~**#2 BUG - MEDIUM** the slug regression suite needed PostgreSQL~~ —
  `test/phoenix_kit_ecommerce/slugify_test.exs` is `ExUnit.Case, async: true`
  (`:24`); the schema-parity check lives in `slugify_parity_test.exs`.
- ~~**#3 BUG - LOW** the parity test compared a function to a changeset~~ —
  split into `slugify_parity_test.exs` as described in the review; its
  assertions were not re-read in this pass.
- ~~**#4 NITPICK** a translated string as a test selector~~ — the button has
  `id="checkout-review-change-billing"` (`web/checkout_page.ex:2025`) and the
  tests target it (`web/checkout_billing_profile_test.exs:419`, `:439`).
- ~~**#5 NITPICK** orphan comment in `product.ex`~~ — the German block and its
  comment went with the slugifier.

## Skipped (with rationale)

- **#6 OBSERVATION** no CHANGELOG entry — changelogs are the maintainer's.

## Open

None.
