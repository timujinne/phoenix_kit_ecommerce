# Follow-up: PRs #84–#88 review (2026-10-13)

Resolutions for `CLAUDE_REVIEW.md`. Numbers are the review's.

| # | Finding | Resolution |
|---|---------|------------|
| 1 | Storefront fallback reflects a redirect target's body | Fixed: 3-redirect cap, body reported by shape. The https/public-host restriction, left open at first, is fixed after `CODEX_REVIEW.md` #1 (see below) |
| 2 | Bulk uuids not cast on products/categories | Fixed: `Helpers.cast_uuids/1`, `cast_optional_uuid/1`; `bulk_payload_hardening_test.exs` |
| 3 | Reprice from an unlocked read | Fixed: `Options.transform_global_options/1`; `transform_global_options_test.exs` |
| 4 | Editing an option renames it | Fixed: `keep_editing_key/2`; test submits no key |
| 5 | Picked image lost on broadcast | Fixed: `selectable_image_urls/1`; test fails without the fix |
| 6 | Concurrent double confirm | Fixed (no test: race not reproducible in a LiveView test) |
| 7 | Migration stats query volume | Fixed: 1 s debounce; test added |
| 8 | Failed product-source read retried | Fixed; no test (shared sandbox cannot make the read fail) |
| 9 | Pre-#84 guest accounts locked out | Open — owner decision. The V4 backfill proposed in `CLAUDE_REVIEW.md` is WITHDRAWN (see below) |
| 10 | Media-sync "interrupted" re-check unreachable | Open |
| 11 | `deduplicate_products` prefix-unaware, bogus order_items table | Open (pre-existing) |
| 12 | Category option edits whole-list | Fixed after `CODEX_REVIEW.md` #4: `Options.transform_category_options/2` (see below) |
| 13 | Catalogue counts include soft-deleted | Open — decision on dashboard semantics |

## Gate

`mix precommit` clean (format, `compile --warnings-as-errors`, credo
--strict, dialyzer). The `:catalogue`-tagged suite was not run.

## Full suite: 20 failures that are not from these changes

`mix test` gives 2965 tests, 20 failures — the same 20 on a clean checkout of
`main` (verified with the changes stashed): `LegacyFormsReturnToTest`,
`AdminEditOriginTest`, `StorefrontAdminEditTest`, one `ShopifySyncTest`, one
`ShopifySyncMediaPanelTest`, one `TranslationsTest`.

Cause, for the ones checked: the `libs` bump moved core to 2.62.x, where a
single-language site emits no locale segment (core 2.62.0 changelog), and the
test site is single-language. Tests that assert `/en/admin/...` get
`/admin/...`. `ShopifySyncMediaPanelTest` fails on a `push_patch` to a path the
test router does not define, and `TranslationsTest` on a "Sweep ran" flash
that now reads "Sweep did not run — AI translation isn't available" (the
installed `phoenix_kit_ai`). The fix belongs in `test/test_helper.exs`
(enable a second language, or assert the clean paths); not done here because
it touches every path assertion and the other agent is still working in this
tree.

## After the Codex review (`CODEX_REVIEW.md`, commit `d25a9be`)

| Codex # | Resolution |
|---|---|
| 1. Storefront redirects reach private HTTP | **Fixed.** `StorefrontClient` sets `redirect: false` and walks the chain itself: at most 3 hops; every hop https, port 443, no userinfo; a host other than the validated shop host must resolve only to public addresses (`ImageDownloader.public_address/1`, strict — it does not read `shop_image_import_allow_private_networks`) and the connection is pinned to the checked address (`pinned_request/2`, so no DNS-rebinding window). Refusals are `{:redirect_refused, reason}` / `:too_many_redirects`, with operator messages in the Shopify sync page. Tests: the `redirects` block in `storefront_client_test.exs`. Codex's reproduction now fails by design, since it asserts the old behaviour. |
| 2. Historical guests lose repeat checkout | **Open, owner decision.** Real, and a regression for those customers. Not changed here. |
| 3. The proposed backfill reopens account reuse | **Accepted; the proposal is withdrawn.** `source` and a shop order are both writable by the account holder, so they cannot be promoted into the proof #84 relies on. Any recovery has to rest on email ownership (a verification or sign-in-link step) rather than on historical metadata. No migration was written. |
| 4. Category option edit renames the key | **Fixed**, same as the global list (`keep_editing_key/2` in `CategoryForm`). Also closes the category lost-update item (#12): save, delete and reorder, `Options.add_category_option/2` / `remove_category_option/2`, and the base-currency repricing of category options now run through `Options.transform_category_options/2`, which locks the category row and hands the function the list as stored. A reorder keeps an option the dragged list did not name (it used to drop it). Tests: `category_options_hardening_test.exs`; the key test fails without the fix. |
| 5. #86's legacy link lands on a form that redirects | **Not changed; documented limitation.** The #86 commit already states the mixed state is defensive/transitional: reads go through one source's facade, and `create_product/1`/`update_product/2` (and the category pair) refuse writes under the catalogue source on purpose, so the legacy forms redirect rather than open a form that cannot save. Making legacy records editable under the catalogue source means changing those write guards, which is a product decision rather than a link fix. Codex's reproduction builds the state by switching the source under an existing legacy record. |

Codex's validation notes agree with this file: precommit clean, the same 20
suite failures, and `--only catalogue` 328 tests with 2 failures — the
locale-prefix expectation and the media-panel `push_patch`, both the
core 2.62 single-language change. The remaining suite repair (`test_helper`)
is still open.
