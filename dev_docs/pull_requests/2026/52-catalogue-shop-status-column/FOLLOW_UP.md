# PR #52 follow-up — Catalogue: surface shop status as its own column

## Fixed (pre-existing)

- ~~BUG - MEDIUM: the item-side "contradiction" warning was stale once
  `product_status/2` started checking `item.status` first.~~ The warning is
  gone on both sides: `lib/phoenix_kit_ecommerce/catalogue/shop_status_column.ex`
  no longer contains any `contradiction` plumbing, and its moduledoc section
  "No warnings — the reachability leak is closed on both sides" (`:40`)
  records why. The category-side warning the review left in place was removed
  later by the week-2026-09-13 review (finding W2), after
  `category_status/2` closed the category leak.

## Open

None.
