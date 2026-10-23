# Follow-up: PRs #94–#99, #104, #105 review (2026-10-21)

Resolutions for `CLAUDE_REVIEW.md`.

| Finding | Resolution |
|---|---|
| #95 order export drops the chosen options | Fixed: `options` on each product line; test in `order_export_test.exs`; README and CHANGELOG |
| #95 Legacy order lines have no product identifier | Open — needs the checkout line writer to record the legacy product uuid; consumers match by `sku` |
| #96 canonical-URL test families never excluded | Fixed: `canonical_urls_exclude` added to the exclude list in `test_helper.exs` |
| #96/#104 dialyzer ignores did not match | Fixed: `.dialyzer_ignore.exs` entries use the `call_to_missing` text |
| #104 overlong moduledoc line | Fixed |

## Gate

`mix precommit` clean (format, `compile --warnings-as-errors`, credo --strict, dialyzer) on the default
build. Full suite against local core and billing: 4689 tests, 1 failure (the canonical-URL helper
exclusion, fixed); the touched test files pass after the fixes. The `:catalogue` suite was not run.
