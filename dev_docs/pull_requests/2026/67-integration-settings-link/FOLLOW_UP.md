# PR #67 follow-up — Link the Settings tab at the connected integration's own page

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~BUG - MEDIUM: the "not connected" link went to
  `/admin/settings/integrations/website` and landed on "Integration not
  found".~~ The prompt links the list itself
  (`lib/phoenix_kit_ecommerce/web/shopify_sync.ex:2097`).
- ~~IMPROVEMENT - MEDIUM: both links were shown to viewers core refuses.~~
  `:can_manage_integrations?` is assigned on mount from
  `integrations_system` (`web/shopify_sync.ex:154-155`, `:1156`) and gates the
  credentials panel and the prompt's link.

## Fixed (Batch 1 — 2026-10-13)

- ~~The same dead link on the shop settings page (not in the review; found
  while re-checking it).~~ "Connect" goes to the integrations list, or to the
  connection's own page when one exists, and only for an
  `integrations_system` holder (`web/settings.ex:36-37`;
  `test/phoenix_kit_ecommerce/web/settings_shopify_test.exs`).

## Skipped (with rationale)

- **NITPICK: `shopify_connection/0` picks the first of several
  connections.** The review left it: the sync runs against the same
  connection the page names, and choosing between connections is a separate
  feature.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce/web/settings.ex` | Connect link target and gate |
| `test/phoenix_kit_ecommerce/web/settings_shopify_test.exs` | pins both |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Open

None.
