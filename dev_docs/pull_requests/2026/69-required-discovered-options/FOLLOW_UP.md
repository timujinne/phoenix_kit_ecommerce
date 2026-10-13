# PR #69 follow-up — Require every option a catalogue product offers before it can be carted

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~IMPROVEMENT - MEDIUM: `add_to_cart/3` now refuses a product with metadata
  options (public API change to record).~~ Recorded for hosts in
  `CHANGELOG.md:250-253`, with `skip_spec_validation: true` named as the
  opt-out.
- ~~NITPICK: the page's "Please select:" flash was not translated.~~
  `gettext("Please select: %{options}", …)`
  (`lib/phoenix_kit_ecommerce/web/catalog_product.ex:498`).

## Fixed (Batch 1 — 2026-10-13)

- ~~NITPICK: a CSV-imported single-variant Shopify product recorded
  "Title: Default Title" as an option.~~ The CSV importer skips Shopify's
  placeholder option on both build paths
  (`import/option_builder.ex:18`, `:74`, `:158`, `:184`). Products imported
  earlier keep the option they already carry.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce/import/option_builder.ex` | placeholder option skipped |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Open

None.
