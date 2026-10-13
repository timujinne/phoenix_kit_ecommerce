# PR #32 follow-up — catalogue extension, Shop section

Triage of `KIMI_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - MEDIUM** the `"USD"` literal was back on `ItemCommerce` and the
  form prefill~~ — the schema carries no default
  (`catalogue/item_commerce.ex:31`) and the prefill reads the base currency or
  stays blank (`catalogue/shop_sections.ex:670`).
- ~~**#2 BUG - MEDIUM** 32 fuzzy gettext entries live at runtime~~ — no
  `#, fuzzy` entry remains in any of the six catalogues.
- ~~**#3 IMPROVEMENT - MEDIUM** `cast/2` dropped unknown keys~~ — the validated
  map is merged over `current` (`catalogue/item_commerce.ex:161`,
  `catalogue/category_commerce.ex:79`).
- ~~**#4 NITPICK** `category/1` missing attr declarations~~ —
  `catalogue/shop_sections.ex:332-335`.

## Skipped (with rationale)

- **#5 NITPICK** `maxlength="32"` on the price-unit input
  (`catalogue/shop_sections.ex:281`) has no matching `validate_length` — still
  so. Client-side cap only; a longer value written through the API is stored
  and rendered, nothing breaks.
- **Unverified surfaces** (the cross-repo contract with `phoenix_kit_catalogue`,
  the `current_language` format) — not checkable from this repo without the
  catalogue bridge.

## Open

None.
