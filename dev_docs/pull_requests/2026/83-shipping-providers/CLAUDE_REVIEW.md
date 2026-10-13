# PR #83: Carrier-agnostic shipping providers, calculated rates and a checkout destination picker

- **Author:** Tymofii Shapovalov (timujinne)
- **Reviewer:** Claude
- **Merge:** `37d11ec` on `main`
- **Verdict:** approve with fixes. The first pass missed three bugs that
  Codex reproduced afterwards (see "After the Codex review" below); all are
  fixed. A page crash, a credential leak, a cache/expiry interaction, a
  wrong-carrier quote and a rounding error were fixed in total.

## Summary

~10k lines of source (95 files) in four layers: a provider behaviour and
facade (`Shipping`, `Shipping.Cache`, `RateLimit`, `Pricing`, packer, the
`Fixed` and `Table` providers); the cart/order integration (destination and
hashed quote stored on the cart, totals from the stored quote, checkout
refused without a current one, order keeps provider/destination/quote/
parcels); the storefront picker (`ShippingDestinationPicker` + parent-owned
snapshot); and the admin cost-calculation card, parcel dimensions and
defaults. Reviewed by area (core, cart/order, storefront, admin + gettext);
every finding below was re-checked against the code.

## Fixed in this review

- **BUG - MEDIUM: a tuple `service_error` crashed the whole page.** The
  picker did `Atom.to_string(@reason)`, but `Shipping.business_error?/1`
  also accepts `{reason, details}` and a provider's `{:error, tuple}`
  passes `normalize/2` untouched, so the cart/checkout LiveView raised on
  render for every shopper on that method. Now `CartQuote.error_reason/1`.
- **BUG - MEDIUM: crash reasons carried credentials.** `run_safely`
  returned `Exception.message/1`, which for `KeyError`/`MatchError` embeds
  the offending term (typically the credentials map the provider was
  handed). The reason went to the log, the 30 s negative cache and every
  caller. Credential strings are now redacted from the message, the throw
  banner, the exit reason, and the text is bounded to 300 characters (the
  `bad_return` text too).
- **BUG - MEDIUM: a cached quote outlived its own `expires_at`.** Quotes
  were cached for a flat 10 min while `CartQuote.expired?` goes stale at
  the carrier's `expires_at`; the re-quote then got the same cached quote
  and was stale again, blocking checkout until the entry died (the 3-in-a-row
  re-quote cap gave no way out). `Cache.fetch` takes `clamp_ttl:`; quotes
  clamp to their expiry and an already-expired quote is not stored.
- **IMPROVEMENT - MEDIUM: list callbacks were checked for `is_list` only.**
  A provider returning bare maps was cached for 6 h and then crashed the
  readers (`check_service`, the picker) outside the isolated worker.
  `services`, `search_localities` and `list_pickup_points` now require
  `Service` / `Locality` / `PickupPoint` structs, else `bad_return`.
- **IMPROVEMENT - HIGH: shopper-driven quotes were unthrottled.** Only the
  two lookups were rate limited; `apply_address`, `apply_manual`,
  `pick_point` and `requote` each stored a destination and started an
  uncached carrier quote, bounded only by one-in-flight. They now share a
  per-component `lookup_interval` throttle (a repeat inside it is ignored).
  The per-provider quote budget across sessions is not added; see below.
- **IMPROVEMENT - MEDIUM: picker events crashed on a missing service.**
  `apply_manual`/`apply_address` dereferenced `socket.assigns.service`
  unconditionally, so a form left open across a transient `service_error`
  (or a crafted event) killed the parent LiveView. Both now require a
  service whose `destination` is the kind the event stores.
- **IMPROVEMENT - MEDIUM: `Pricing` settled on 2 decimals for any base
  currency.** A JPY base with a 7.5% markup put 1326.55 on the cart. The
  base-currency branch now rounds to the base currency's places.
- **IMPROVEMENT - MEDIUM: admin locality pick was by list position.** A
  debounced search result landing between render and click shifted the
  index and selected another city. The button now carries the locality id,
  which wins over the index (kept as a fallback).
- **NITPICK:** an invalid `:shipping_provider_timeout` env value crashed the
  caller (`receive ... after`), now falls back to the default; a service's
  `countries` are normalised before the comparison (a provider-built
  `["ua"]` made every service "unsupported"); the admin locality query is
  cut to 64 characters; the unused `:form_params` assign is gone.

## After the Codex review

Codex (`CODEX_REVIEW.md`) reproduced three bugs in the first round of fixes;
this was wrong in the first pass and is corrected here.

- **BUG - HIGH: credentials were still reachable.** `bad_return` inspected
  arbitrary provider output (`{:ok, ctx.credentials}` ended up in the result,
  the log and the cache), and the crash redaction missed values that
  `inspect` escapes (quotes, backslashes, newlines) and values under four
  bytes. A malformed return is now described by shape only, redaction covers
  the escaped form and any non-empty value, and the log line is redacted.
- **BUG - HIGH: checkout accepted another carrier's quote.** I had filed the
  missing provider in `request_hash/1` as a nitpick. It is a money bug: a
  method switched to another provider kept the old provider's stored quote
  (status `:ok`, charged and recorded on the order). The stored entry now
  carries `"provider"` and is stale for any other (and when absent); the
  in-flight persist checks it under the cart lock. The public
  `request_hash/1` format is unchanged.
- **BUG - MEDIUM: JPY was rounded twice.** `Pricing` rounded to cents and the
  cart code then to yen (100.495 -> 100.50 -> 101). `Pricing.final_amount/5`
  takes the places and rounds once.
- The changelog now lists the feature itself.

`Pricing` still cannot give a base currency with more than two decimals
(KWD) full support: core's cart shipping column is `numeric(12,2)`.

## Not changed (on record)

- **IMPROVEMENT - MEDIUM: carrier lookups inside the conversion
  transaction.** `validate_shipping_quote` → `shipping_service/2` /
  `validate_destination` run while the cart row is locked and a pool
  connection is held; a cold cache plus a slow carrier holds both for
  seconds, and a services timeout blocks an order that has a valid stored
  quote. Moving the check out needs a restructure of
  `convert_cart_to_order/2`'s money path; left for its own change.
- **IMPROVEMENT - MEDIUM: an unclassified provider error falls back to the
  method price.** Only seven reasons are business refusals, so a carrier 4xx
  for a shopper-typed address stores a `fallback` quote and checkout
  proceeds at `method.price`. This is the documented "transient failure
  falls back" rule; the real fix is for providers to map their client errors
  to `:invalid_destination`, which is a provider-contract matter.
- **IMPROVEMENT - MEDIUM: no per-provider quote budget** across sessions
  (the per-component throttle bounds one client, not a fleet).
- **IMPROVEMENT - MEDIUM: a 2 s services timeout is never negative-cached**,
  so a hanging carrier costs every snapshot 2 s in the LiveView process.
- **IMPROVEMENT - MEDIUM: the admin service list and "connected" badge go
  stale when the connection setting changes** (only a provider change
  reloads them).
- **IMPROVEMENT - MEDIUM: a method whose provider is no longer installed
  cannot be saved,** while the card says it "keeps its fixed price".
- **NITPICK:** declared value and COD sum
  digital lines too; `shipping_skippable?` ignores provider reach; the
  rate-limit CAS retry writes a stale `now`; `round_to` below 0.01 breaks
  the settle-on-cents rule; checkout computes the snapshot up to 3 times on
  a review mount; `pick_locality` hides "Cancel" by overwriting a complete
  destination; `order_shipping_details` uses fixed DOM ids.

## Checked and correct

Cache keys hash credentials (no leakage across providers, credentials or
methods) and are bounded; isolation uses an unlinked monitored worker with
mailbox draining; token-bucket integer math; `owner: :system` plus the
provider's own integration key for credentials; no `String.to_atom`;
`Decimal` throughout, Pricing order (pay-on-delivery, free-above, fallback,
markup, clamp, step) correct; the request hash is stable across scale and key
order; the quote gate blocks `:needs_destination`, `:missing`, `:stale`,
`:unavailable` and runs after totals are recalculated on the locked cart;
destination and quote writes lock the cart and rebase onto DB metadata;
pay-on-delivery is never read as FREE; position `"checkout"` does not
redirect to `/cart`; `put_content_locale` in every public page; every
mutating or carrier-calling admin event goes through `Authz`
(`manage_settings`); activity rows carry no secrets; credentials never reach
assigns or HTML; the `compat/shop.ex` shim delegates all 12 new functions;
the six gettext catalogues carry the identical 1228 msgids with no empty or
fuzzy entries and matching placeholders.

## Tests

Added: facade tests for redaction, bounding, struct checks, country
normalisation, quote expiry (cached, expired, not stored) and the malformed
timeout; picker tests for a tuple `service_error`, events without a matching
service and the destination throttle; an admin test for pick-by-id.
