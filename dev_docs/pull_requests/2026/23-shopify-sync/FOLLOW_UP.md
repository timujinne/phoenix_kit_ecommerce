# PR #23 follow-up — universal Shopify sync

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - HIGH** the sync LiveView route was missing from the test
  router~~ — `test/support/test_router.ex:100`.
- ~~**#2 BUG - HIGH** bulk apply dropped failed writes and reported success~~ —
  `Sync.apply_changes/3` (`shopify/sync.ex:569`) partitions results, and every
  bulk path in `web/shopify_sync.ex` destructures
  `%{succeeded: _, failed: _}` (`:595`, `:621`, `:892`).
- ~~**#3 BUG - MEDIUM** the network-failure test raised instead of simulating a
  transport error~~ — `Req.Test.transport_error/2`
  (`test/phoenix_kit_ecommerce/shopify/admin_client_test.exs:92`, `:605`).

## Skipped (with rationale)

- **#4 OBSERVATION** `Sync.check/1` loads the whole local catalogue
  (`shopify/sync.ex:203`) — still so; the reviewer left it as speculative at
  this module's catalogue sizes.
- **#5 OBSERVATION** `Web.ShopifySync.mount/3` reads connections in `mount/3` —
  the reviewer left it as consistent with the module's other admin LiveViews.

## Open

None.
