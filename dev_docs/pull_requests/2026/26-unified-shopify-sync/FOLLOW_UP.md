# PR #26 follow-up — unified Shopify sync

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - MEDIUM** `:forbidden` had no `format_error/1` clause~~ —
  `web/shopify_sync.ex:1719-1720`.
- ~~**#2 BUG - MEDIUM** 84 msgids never extracted~~ — fixed at review time; the
  catalogues carry no `#, fuzzy` entries today. A code-vs-catalogue diff was
  not run in this pass.
- ~~**#3 BUG - MEDIUM** section and field labels held as module-attribute
  literals~~ — one `gettext/1` clause per field
  (`web/shopify_sync.ex:1473-1479`, `:1501-1508`).
- ~~**#4 IMPROVEMENT - MEDIUM** the modal guarded on `@pending` and dereferenced
  `@modal`~~ — `:if={@modal}` (`web/shopify_sync.ex:2080`).
- ~~**#5 IMPROVEMENT - LOW** row apply skipped the source-visibility guard~~ —
  routed through `visible_field_changes/3` (`web/shopify_sync.ex:451-458`).
- ~~**#6 OBSERVATION** `AdminClient` `Retry-After` unclamped~~ —
  `seconds |> max(0) |> min(@max_retry_after_seconds)`
  (`shopify/admin_client.ex:532`).

## Skipped (with rationale)

- **#3 limitation** `%{field}` is a bare noun interpolated into admin
  sentences — accepted by the reviewer for the admin surface.
- **#7 OBSERVATION** `mount/3` reads the Shopify connection — pre-existing and
  left by the reviewer.
- **#8 NITPICK** `TextDiff`'s "pure" wording, and `:telemetry` called without
  being a declared dependency — left by the reviewer; a dependency change is
  the maintainer's call.

## Open

None.
