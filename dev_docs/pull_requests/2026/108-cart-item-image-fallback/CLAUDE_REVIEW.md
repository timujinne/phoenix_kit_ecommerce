# PR #108 — Cart: let the host app supply a picture for lines without a product photo

- **Author:** Tymofii Shapovalov (timujinne)
- **Merged:** 2026-10-24, squash commit `407e1d5`
- **Reviewer:** Claude, 2026-10-24, against `main` at `5cad878`

## Scope

New `PhoenixKitEcommerce.ItemImage.url/1`: a cart line's `product_image`
snapshot, else the result of the host's `:item_image_fallback` MFA, else `nil`
(the cube icon). `CartPage` and the checkout summary in `CheckoutPage` render
through it. Unit tests for the resolver, LiveView tests for both pages, README
and AGENTS.md entries.

## What was checked

- **The contract the moduledoc promises the callback.** A catalogue line has
  `product_uuid: nil` and its item uuid in `metadata["catalogue_item_uuid"]`
  (`CartItem.from_product/3`, `put_catalogue_item_uuid/2`); a Legacy line has
  `product_uuid`. The moduledoc says exactly that, so a host can tell the two
  apart.
- **Failure handling.** Function-level `rescue` takes `:error`, the `catch`
  takes `:exit` and `:throw`, so a host function cannot take the LiveView down
  during render. A missing module/function is an `UndefinedFunctionError`,
  rescued. Non-string and empty answers fall back to the icon.
- **Behaviour change for an empty snapshot.** Before, `if item.product_image`
  treated `""` as truthy and rendered `<img src="">`; now `""` goes to the
  fallback or the icon. An improvement.
- **Every place a cart/order line is drawn.** Only the two pages touched
  render a line picture. `CheckoutComplete`, `UserOrderDetails`, the claim page
  (`ClaimHTML`) and the public cart API (`API.CartView`) carry no line image at
  all, so nothing was missed.
- **Render cost.** The call sits inside the `for` comprehension, so it runs on
  every re-render of `@cart`, once per photo-less line. The moduledoc tells the
  host to keep the function a pure URL builder; acceptable.
- **Output safety.** The URL goes through a HEEx attribute (escaped); `<img
  src>` does not execute `javascript:` URLs. The moduledoc puts trust in the
  host's URL on record.

## Findings

### NITPICK — a broken fallback logs once per line per render

A misconfigured or failing callback logs a warning on every render of every
photo-less line, so a cart page that re-renders often (quantity changes,
shipping re-quotes) logs many identical lines. Not fixed: the warning is the
only signal an operator gets that the configuration is wrong, deduplicating it
needs process-global state (`:persistent_term` or ETS) for a configuration
error that is fixed once, and the volume is bounded by the cart traffic.

No bugs found; no code changes.

## Validation

- `mix test test/phoenix_kit_ecommerce/item_image_test.exs test/phoenix_kit_ecommerce/web/item_image_pages_test.exs`:
  11 tests, 0 failures.
- `mix precommit`: see `FOLLOW_UP.md`.
