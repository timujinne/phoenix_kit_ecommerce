# Code Review: PR #23 — Add universal Shopify sync (0.3.0)

**Reviewed:** 2026-08-21
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/23
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** b33cb899ba7f6143ef5a8b10538675bb660c17d8 (merge commit 97b74e0)
**Status:** Merged

## Summary

Adds a one-way, human-confirmed catalog sync from a connected Shopify store
into this module's products: a `PhoenixKit.Integrations` provider
(`Shopify.Provider`, static Admin API token, not OAuth), a paginated REST
client (`Shopify.AdminClient`), a pure diff engine
(`Shopify.ProductDiff`), an orchestration layer (`Shopify.Sync`), and an
admin LiveView (`Web.ShopifySync`) at Shop → Shopify Sync. Also extracts
`HtmlText.extract_description/2` out of `ProductTransformer` for reuse, and
carries an unrelated pre-existing `test_helper.exs` fix (two support files
missing from the explicit `Code.require_file` list).

## Issues Found

### 1. [BUG - HIGH] New LiveView test suite couldn't run at all — route never added to the test router — FIXED
**File:** `test/support/test_router.ex`
**Confidence:** 100/100

`test/phoenix_kit_ecommerce/web/shopify_sync_test.exs` (all 4 tests) calls
`live(conn, "/en/admin/shop/shopify-sync")`, but the manually-maintained
`test/support/test_router.ex` (which mirrors the app's routes rather than
generating them from `route_module/0`) never got the corresponding `live
"/shopify-sync", ShopifySync, :index` entry that every other admin LV in
this file has. `mix test` on the merged commit fails with `NoRouteError`
on all 4 tests — the module's own testing gate (AGENTS.md: "Where `mix
test` is expected, run it") was not run clean before merge, or `mix
compile --force` wasn't re-run after adding the test file.

Added the missing route, matching the existing pattern in that file.

### 2. [BUG - HIGH] Bulk "apply all price-only updates" silently drops failed writes and reports them as succeeded — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/shopify_sync.ex` (handler for
`"apply_safe_prices"`)
**Confidence:** 95/100

```elixir
Enum.each(safe, &Sync.apply_change(&1, [:price]))
...
socket
|> assign(:diff, rest)
|> put_flash(:info, gettext("Updated %{count} product price(s).", count: length(safe)))
```

`Sync.apply_change/2` can return `{:error, changeset}` (e.g. a Shopify
price of 0 or a race where the product changed between check and apply),
but the bulk path discards the return value entirely. Every item in `safe`
is removed from `diff` and the flash claims all of them updated,
regardless of whether the write actually happened — an admin has no way to
know a price silently failed to sync, and the product disappears from the
"needs attention" list. This is inconsistent with the single-product path
(`apply_one_change/3`), which does check `{:ok, _}` / `{:error, _}` and
reports failures — the bulk path was the one place this got missed.

No test exercised this path in either direction (the LiveView test file's
own moduledoc notes `Sync.check/1` isn't network-stubbable from that
layer, so bulk-apply success/failure was untested end to end).

**Fix:** added `Sync.apply_changes/2` (domain layer, per the module's own
"no LiveView/UI wiring here" boundary) that applies a list of changes and
partitions the results into `%{succeeded:, failed:}`, never raising on one
bad changeset. The LiveView now keeps failed changes in `diff` (so they
stay visible and retryable) and shows a separate error flash with the
failure count instead of misreporting them as applied. Locked in with two
new tests in `sync_test.exs` covering the all-succeed and
one-fails-among-many cases (the latter using a negative incoming price to
trigger the schema's `validate_number(:price, greater_than_or_equal_to:
0)`).

### 3. [BUG - MEDIUM] `admin_client_test.exs`'s "network failure" test raises instead of simulating a transport error, and fails as shipped — FIXED
**File:** `test/phoenix_kit_ecommerce/shopify/admin_client_test.exs`
**Confidence:** 100/100

```elixir
Req.Test.stub(@stub, fn _conn -> raise "connection refused" end)
assert {:error, _reason} = AdminClient.fetch_products(uuid, req_options())
```

Raising inside a `Req.Test.stub` callback re-raises through the request
pipeline as a real exception — it does not get converted into an
`{:error, reason}` tuple the way an actual transport failure would. This
test fails on its own on the merged commit (confirmed by reverting the
review's other changes and running it in isolation): `** (RuntimeError)
connection refused`, uncaught. `AdminClient.fetch_products/2` itself is
correct (its `{:error, reason}` catch-all clause on `Req.get/2` is fine);
only the test's simulation technique was wrong.

**Fix:** simulate the transport failure the way `Req.Test` supports —
`Req.Test.transport_error(conn, :closed)` — and assert on the
`%Req.TransportError{}` that `Req.get/2` actually returns for a real
connection failure.

### 4. [OBSERVATION] `list_products()` called unfiltered in `Sync.check/1`
**File:** `lib/phoenix_kit_ecommerce/shopify/sync.ex`

`check/1` loads the *entire* local catalog into memory
(`Shop.list_products()`, no pagination) to diff against every Shopify
product. Fine at the catalog sizes this module is otherwise built for; a
store with tens of thousands of products would make this a heavy
synchronous LiveView call. Not fixed — no evidence this module targets
that scale, and adding pagination/streaming here would be speculative
complexity for a problem nobody has yet.

### 5. [OBSERVATION] `Web.ShopifySync.mount/3` queries the DB directly (`Integrations.list_connections/2`)
**File:** `lib/phoenix_kit_ecommerce/web/shopify_sync.ex`

`mount/3` runs twice (dead render + connected mount), so this is two
identical connection lookups per page load — the same pattern already
present throughout this module's other admin LiveViews (e.g.
`Web.Imports.mount/3` loads `list_imports()`, `migration_stats()`, and
`list_import_configs()` unconditionally in `mount/3` too). Consistent with
existing project style, not something introduced by this PR, and a single
cheap lookup on a low-traffic admin settings page — not worth a one-off
fix that would make this file's convention diverge from its siblings.
Flagging in case a future cleanup pass wants to move data loading to
`handle_params/3` module-wide.

## What Was Done Well

- `ProductDiff.diff/3` is a pure function with genuinely thorough test
  coverage (matching, each compared field, tag-set normalization,
  extreme-price flagging) — the most convincing part of the PR.
- `AdminClient.fetch_all/4` correctly preserves product order across pages
  despite building the accumulator via `Enum.reverse(products, acc)` +
  final reverse; verified by tracing the pagination test.
- `Sync.apply_change/2`'s localized-field merge reads from the *original*
  `product` struct per field rather than an accumulator, which avoids a
  classic "second localized field clobbers the first" bug when multiple
  localized fields change in the same apply — deliberate and correct.
- Real security reasoning in `Shopify.Provider`'s moduledoc for choosing
  `:credentials` over OAuth (core's generic OAuth callback doesn't verify
  Shopify's HMAC callback param).
- `X-Shopify-Access-Token` header (not `Authorization: Bearer`), 429
  back-off honoring `Retry-After`, and per-page retry budget reset are all
  correct against Shopify's actual Admin API contract.
- Nothing is written without an explicit click; the extreme-price (>3x)
  guard forces individual confirmation even under the bulk path.

## Verdict

**Approved with fixes.** The diff/domain layer (`ProductDiff`, most of
`AdminClient`) was solid and well-tested. The three issues above were all
in the less-tested edges — the bulk-apply UI path and two test-simulation
bugs — and are now fixed and covered; `mix test` (525 tests) and `mix
precommit` (format, compile --warnings-as-errors, credo --strict,
dialyzer) both pass clean on this state.
