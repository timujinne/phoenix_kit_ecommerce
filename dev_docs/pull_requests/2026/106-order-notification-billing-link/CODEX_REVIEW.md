# PR #106 — order notification links

Reviewed 2026-10-22 against `e5c0fee`, including the earlier review and follow-up.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/106

## BUG - MEDIUM — shop-only operators receive an inaccessible Billing link

The notification recipients hold `shop.manage_carts`, Owner, or `*`. This does
not imply the `billing` module permission required by the Billing admin route.
With Billing enabled, the PR sends every recipient to its order page, including
operators who cannot open it. The earlier review identified this but left it open.

Fixed by resolving Billing recipients through the existing `admin_recipients/1`
helper, which already handles Owner and wildcard grants. Group the original shop
recipients by Billing access and send at most two batches: the Billing order link
for permitted recipients, the existing carts link for everyone else. Disabled
Billing and failed permission resolution retain the carts fallback. This changes
links, not the recipient set or customer notification.

Regression coverage creates distinct shop-only, Billing, wildcard, and Owner
recipients in one send and asserts exactly one usable admin link per recipient.
Existing tests retain disabled-Billing, operator-buyers, and customer-only behavior.

## Validation

See `FOLLOW_UP.md` for the final gate and suite results.
