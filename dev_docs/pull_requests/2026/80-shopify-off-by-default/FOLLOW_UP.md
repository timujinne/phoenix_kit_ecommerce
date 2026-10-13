# PR #80 follow-up — Shopify sync is off by default and fails closed

## No findings

`CLAUDE_REVIEW.md` and `CODEX_REVIEW.md` both approved with no defect; the
upgrade note (a host must run `mix phoenix_kit.update` for V3 to keep an
existing Shopify install enabled) is release-notes material, not a code
change. Re-verified against current code during the quality-sweep triage:

- `lib/phoenix_kit_ecommerce.ex:178-184` — `shopify_enabled?/0` answers `true`
  only for a stored `"true"` and `false` on a raise or an exit.

Reviewers: Claude, Codex. Nothing outstanding.

## Open

None.
