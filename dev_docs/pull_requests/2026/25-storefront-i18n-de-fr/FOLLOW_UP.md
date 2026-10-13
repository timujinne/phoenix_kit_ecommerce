# PR #25 follow-up — German and French storefront translations

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - MEDIUM** `ru` and `et` duplicated the count on `item`/`items`~~ —
  both entries carry the bare noun
  (`priv/gettext/ru/LC_MESSAGES/default.po:2598-2602`,
  `priv/gettext/et/LC_MESSAGES/default.po:2594-2597`).

## Skipped (with rationale)

- **#2 OBSERVATION** `et`/`ru` render "Vendor" in the supplier sense — the
  reviewer left it as a merchandising decision for the operator.
- **#3 NITPICK** `builtin_labels/0` is rebuilt per call
  (`web/components/catalog_sidebar.ex:415-417`) — still so; the reviewer judged
  a compile-time attribute the worse trade.

## Open

None.
