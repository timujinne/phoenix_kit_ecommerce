# PR #93 — Admin and public API tools: prices, availability, images, catalog search and an assistant cart

**Merged:** `a157b53` · **Reviewed:** 2026-10-17, not yet released (0.5.24 is the last version on Hex)

Scope (203 files, ~16k lines of `lib/`): the admin tools (`API.SetPrices`, `SetAvailability`,
`AttachImages`, `DetachImages`, `GetPrices`, `Batch`, `PricePlan`, `CatalogueWrites`, `Gate`),
the public read API and search index (`Search.*`, `API.Public.*`, `Loader`, `Visibility`,
`SearchReindexWorker`/`SearchRebuildWorker`, V4), the assistant cart and checkout claim
(`API.Cart*`, `Claims`, `ClaimController`, the three cron workers, V5), and the infrastructure
(`ImageDownloader` + `PinnedAdapter`, the settings page, migrations rules, gettext).

Method: four reviewers by area, each reading the current tree against `AGENTS.md`'s invariants;
every finding below was re-read in the code by me before it was accepted. The reviewers
confirmed as clean: the SSRF guard (literal forms, rebinding, redirects, streaming size cap),
the Mint adapter's SNI/certificate check, the claim token (HMAC, digest lookup, single use under
concurrent POSTs, lock order, no token in logs/redirects), the confirmation-gate maths and lock
order of `write_if_unchanged`, every public handler under `with_request_currency`, visibility
through `Loader`, all SQL parameterized, settings events authorized, gettext complete in six
locales, V4/V5 idempotent and prefix-parameterized.

## Findings

### BUG - MEDIUM — deleting one Legacy category never reindexed its products
`Subscriber` answered `:category_deleted` with a subtree job. The delete sets the products'
`category_uuid` and the children's `parent_uuid` to NULL, so by the time the job ran the subtree
was just the dead uuid and no product was found. Rows kept the deleted name and category path
(searchable, filterable by the dead id) until the 03:40 rebuild. **Fixed:** the event enqueues a
rebuild, as the bulk delete does.

### BUG - MEDIUM — a base-currency change left the index on old-base prices
`reprice_products_for_base_change` writes directly and (correctly) broadcasts nothing inside
billing's transaction; the subscriber listened to no currency event. `price`, `compare_at_price`,
the price sort and the price facets stayed in the old base for up to 24 h. **Fixed:** `Subscriber`
subscribes to billing's `{:currencies_changed, _}` (sent after the commit) and enqueues a rebuild;
the rebuild job is unique, so a burst of rate edits is one job.

### BUG - MEDIUM — the pinned downloader kept Req's default retry
No `retry: false`: a 429/503 slept for the origin's `Retry-After`, uncapped, inside callers that
have no task kill (Shopify media sync, `Catalogue.Writer.sync_images`), and the API path's
documented 15 s timeout was not per download. **Fixed:** `retry: false` in `request_opts/2`
(the Shopify clients already do this).

### BUG - MEDIUM (prefixed installs) — `WarehouseSourceKind` queried the catalogue table unprefixed
`from(i in "phoenix_kit_cat_items", …)` has no `@schema_prefix`. **Fixed:** the prefix is taken
from the same `:phoenix_kit, :prefix` compile env core's schemas use. (`web/translations.ex` has the
same pattern for `oban_jobs` and `phoenix_kit_ai_requests`, from before this PR; not touched.)

### BUG - MEDIUM — `fields` made list items violate the advertised output schema
`list_item` required `id`, `title`, `status`, while `fields: ["price"]` returns `{id, price}`
(pinned by a test). Core does not validate output server-side, but a strict MCP client validating
`structuredContent` would reject every such answer. **Fixed:** only `id` is required.

### IMPROVEMENT - MEDIUM — merged assistant carts were never pruned
The "add these items" choice sets the API cart to `merged`, keeping its `api:` session and lines;
the sweep touches `active` and the prune only `abandoned`. Each such buyer left a permanent
orphan cart. **Fixed:** the prune takes `abandoned` and `merged` (the foreign keys cascade lines
and claims).

### IMPROVEMENT - MEDIUM — `set_prices` wrote unstamped amounts with no currency anywhere
The Shopify sync refuses a price while the shop has no base currency; the API did not, and
`get_prices` then answered `price: null` for the same product, so the amount was silently
reinterpreted once a base existed. **Fixed:** a row that changes something is refused
(`validation_failed`) when neither the item nor the shop names a currency.

### IMPROVEMENT - MEDIUM — `set_availability` wrote without re-checking availability
It used `Batch.write/3`, so a product trashed or moved out of the shop catalogue between planning
and writing still got `shop_status` written, and the "publish needs a price" rule was judged on
the planning read only. **Fixed:** it uses `write_if_unchanged/4` with its planner, as `set_prices` does.

### IMPROVEMENT - LOW — the cart settings form lost audit rows on a partial write
`write_api_cart_settings` audited only if every write succeeded; an earlier stored value had no
audit row and the form showed stale values. **Fixed:** each stored value is audited and the form
is reassigned either way.

### IMPROVEMENT - MEDIUM — V4 / V5 SQL not digest-pinned
Only V3 had a digest (rule 1 of the migration chain). **Fixed:** digests for V4
(`search_index_statements/1`) and for V5's claims table (`claims_statements/1`), public and
prefixed. V5's analytics step depends on what is loaded and is deliberately left out.

### NITPICK (docs, fixed) — AGENTS.md said only `set_prices` has a `danger` function (`detach_images` has one too); the `StorefrontCache` moduledoc omitted `write_if_unchanged/4` and `DetachImages`; the `ClaimHTML` moduledoc claimed a change of "either cart" is noticed (only the assistant's lines are bound by `revision`).

## Not changed, on record

| Finding | Severity | Why not |
|---|---|---|
| Write tools need only `shop.manage_catalog`; the UI needs `"catalogue"` as well for a catalogue record | IMPROVEMENT - HIGH (reviewer), medium confidence | `Tool.permission` takes one string and the second key has to be checked against the key's owner inside every handler. That is an authorization-model decision for the maintainer (is an API key's scope the intended limit?); decide it, then document or enforce. |
| Confirmation threshold is per field, not per customer price (base +25 % and an option leaf of 29 % pass) | IMPROVEMENT - MEDIUM | Behaviour change of a deliberate rule; needs a decision (and a doc line) before a change. |
| A confirmed `set_prices` call is only re-checked against its own earlier read | IMPROVEMENT - MEDIUM, low confidence | Small window between core's fingerprint dry run and the handler's read; closing it means re-deriving the fingerprint in the handler. |
| Dotted option/value names collapse entries in `changes` (`"price_modifiers.a.b.c"`) | NITPICK | Response display only; the write is per leaf and correct. |
| A newly enabled language has an empty index until the nightly rebuild | IMPROVEMENT - MEDIUM | Needs a language-change trigger in core's settings; document or follow up. |
| `count`/facets include a just-hidden product until the reindex (window unbounded if the `shop_search` queue is not configured) | IMPROVEMENT - MEDIUM | Documented lag; the product itself is never returned. A boot warning for a missing queue would help. |
| Facet output unbounded (5000 rows folded) | IMPROVEMENT - MEDIUM | Needs a cap + `truncated` flag in the answer shape. |
| Indexer has no per-product isolation (`"NaN"` in `compare_at_price` raises in `Document.build`) | NITPICK | Needs a direct write to item `data`; casts reject it. |
| Claim merge caps a line at 99 (the API's cap) rather than 9999 | NITPICK | Pinned by two tests as intended; changing it is a product decision. |
| Double-clicked claim POST lands on `/cart` with "already used" | NITPICK | Cosmetic; no data effect. |
| Claim of an emptied cart is still issued/shown/redeemed | NITPICK | The buyer sees 0 lines; no harm. |
| http→https upgrade keeps the port (`http://host:80/x`) | NITPICK, pre-existing | Documented behaviour of the importer. |
| Temp file leak when a download task is killed | NITPICK | `phx_img_*` files in the tmp dir; follow-up. |
| `mint` is used directly but not declared in `mix.exs` | NITPICK | Works through req/finch; add with a floor test when next touching deps. |
| Trigram GIN index only built in V4 if `pg_trgm` exists then | NITPICK | V4 cannot be edited; a V6 re-run of the guarded `CREATE INDEX` if it matters. |

## Verification

`mix format`; `mix test` (default build, 791 tests in the touched areas); the API/search/worker/web
suites against a core checkout that carries the API (`PHOENIX_KIT_PATH=../phoenix_kit`,
warehouse bridged): 1884 tests, 0 failures. The `:catalogue` run has three failures in
`writer_variants_test.exs` / `collection_sync_test.exs` (item-update attribution, and one
`catalogue_too_old` from the catalogue the bridge resolves); those files and the code under them
are untouched by this review.
