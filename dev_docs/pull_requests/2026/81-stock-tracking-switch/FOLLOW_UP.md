# PR #81 follow-up — Add a Stock tracking switch that needs the Warehouse module

## Fixed (pre-existing)

- ~~BUG - MEDIUM (`CODEX_REVIEW.md`): `stock_tracking_enabled?/0` and
  `warehouse_status/0` were missing from the compatibility shim.~~
  `lib/phoenix_kit_ecommerce/compat/shop.ex:34-35`; exports pinned by
  `test/phoenix_kit_ecommerce/compat_shop_test.exs`.

## Not changed by the reviewer (design notes, not defects)

- The stored key can outlive its effect while Warehouse is disabled.
  `CLAUDE_REVIEW.md` records this as the documented design.
- The optional `phoenix_kit_warehouse` dependency pulls catalogue packages in,
  so `:catalogue` tests run in a plain `mix test`. Documented by the PR.

## Open

None.
