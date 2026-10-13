# Code Review: PRs #84–#88 (2026-10-13)

**Reviewed:** 2026-10-13
**Reviewer:** Claude (Sonnet 5.5), four parallel read-only reviewers on #84 by
area plus a direct read of #85–#88; every finding was checked against the tree
before a fix was written.
**Scope:** `2108b1c` (#84 quality sweep, 164 files), `2026c03` (#85 og share
image), `22bc033` (#86 Edit editor by record origin), `3b8da89` (#87 return to
the originating page), `96d40bb` (#88 My Cart in the avatar menu) and the
`libs` lock bump.
**Status:** Fixed on `main` in the commit that carries this document, except
where a finding is marked *left open*. Not released: no version bump, no
publish.

## Summary

#85–#88 are small and sound. `Routes.local_path?/1` (used by #87's
`safe_return_to/1`) ships in core 2.43.0, the compound floor, so no floor bump
is needed; a core without the `user_menu` Tab option ignores the key (#88);
`maybe_assign_admin_edit/4` fails closed on an empty permission list (#86).

#84 is a large hardening sweep and mostly delivers what it says: the Shopify
shop-domain check, the guest-account reuse rule, the options lock, the
PubSub-server unification and the gettext catalogues (six `.po` files plus the
`.pot`, 1367 msgids each, no fuzzy entries, placeholders matching) all held up
under review. What was left were seams the sweep did not reach.

## Findings

### BUG - MEDIUM

1. **The storefront fallback reflected the body of a redirect target.**
   `Shopify.StorefrontClient` follows redirects (a `*.myshopify.com` store
   redirects to its primary domain) and returned `{:unexpected_body, body}`
   with the full body, which the sync page renders. Someone with Shopify
   connection access could point the shop at a store that redirects to an
   internal URL and read the answer. *Fixed:* the redirect chain is capped at
   3 and an unexpected body is reported by shape (`{:object, n}`, `{:text,
   bytes}`) only. *Left open:* the redirect target is still not restricted to
   https/public hosts (a blind GET remains possible); that needs the image
   importer's private-network guard moved to a shared module. *Update:* fixed
   after the Codex review; see `FOLLOW_UP.md`.
2. **"Bulk uuids cast" skipped the products and categories pages.** The
   `uuids` of `open_status_modal`/`open_category_modal`/`open_parent_modal`/
   `confirm_bulk_delete` and the `category_uuid`/`parent_uuid` targets went
   straight into `where x.uuid in ^ids`; one hand-made payload raised
   `Ecto.Query.CastError` and a non-list crashed `render`. *Fixed:*
   `Web.Helpers.cast_uuids/1` and `cast_optional_uuid/1`, used by both pages
   and by the translations page (which had its own private copy).
3. **Base-currency repricing wrote the global options from an unlocked read.**
   `reprice_global_options_for_base_change` read the list, then called
   `update_global_options/1` (whole-list replace) — exactly what the #84
   docstring warns against; a CSV auto-add or a second admin in between was
   erased. *Fixed:* new `Options.transform_global_options/1` runs the
   re-pricing against the list as stored under the lock.
4. **Editing a global option in a browser renamed it (pre-existing).** The
   key input is `disabled` while editing, browsers do not submit disabled
   inputs, so the key came back empty and `build_option/1` re-derived it from
   the label, onto another option's key if the label matched. The #84 tests
   submitted a `"key"` no browser sends. *Fixed:* an edit keeps the edited
   option's key; the test submits no key.
5. **The product page forgot the visitor's picked image on any broadcast
   (pre-existing).** `refreshed_image/2` compared the selected signed URL with
   the raw file uuid, which never matched. *Fixed* by comparing against the
   URLs the page can select; covered by a test that fails without the fix.

### IMPROVEMENT - MEDIUM

6. **A truly concurrent double confirm showed "Failed to create order".**
   The loser of a race gets `{:error, :cart_already_converting}`, which
   `CheckoutPage` had no clause for. *Fixed:* handled like `:cart_not_active`
   (go to the order if it exists). No test: the race is not reproducible
   through a LiveView.
7. **Image-migration progress ran four queries per product per open page.**
   Once #84 made the PubSub messages actually arrive, `{:product_migrated, _}`
   called `migration_stats/0` each time. *Fixed:* refreshed at most once per
   second.
8. **A failed `shop_product_source` read was retried and logged on every
   call.** *Fixed:* a failed read is memoised for one interval (stale value,
   else `nil` → Legacy). *Not covered by a test*: the sandbox runs shared, so
   the failing branch is not reachable from a test without disturbing it.
9. **Guest accounts created before #84 are locked out of guest checkout.**
   Reuse now needs an order stamped `metadata["guest_checkout"]` /
   `guest_checkout_email`; earlier orders carry neither, and most guests never
   confirm, so a returning guest gets `:email_already_registered` for an
   account whose password they never knew. *Left open — decision needed:* a V4
   backfill (stamp orders with `source = shop_checkout` whose owner is an
   unconfirmed `guest_checkout` account with a matching billing email), or
   accept it and say so in the release notes. Not done here: it is a
   migration that writes to orders. *Update:* the backfill is withdrawn — the
   evidence it keys on is writable by the account holder (see `FOLLOW_UP.md`).
10. **The media-sync "interrupted" re-check is unreachable from an open
    page.** The Run button is disabled from stale assigns and no message
    follows a killed job, so it stays disabled until reload. *Left open:*
    re-read the progress on a timer while any kind shows running.
11. **`mix phoenix_kit_ecommerce.deduplicate_products` is prefix-unaware and
    updates `phoenix_kit_order_items`, which exists in neither core nor
    billing.** The `undefined_table` is swallowed inside a transaction that
    Postgres has already aborted, so a real run likely never merges anything.
    Pre-existing; *left open*, to be fixed with the task's own review.
12. **Category option edits are still whole-list writes from the socket's
    copy** (`CategoryForm` → `Options.update_category_options`); the lock
    covers only the global list. *Update:* fixed after the Codex review
    (`Options.transform_category_options/2`).
13. **Catalogue counts include soft-deleted rows** (`count_categories/1`,
    `count_items/1`); matches what the admin list shows today. *Left open*
    pending a decision on what the dashboard should count.

### NITPICK

- `format_spec_value/1` rendered literal "Yes"/"No" on the product page.
  *Fixed* (`gettext`; the msgids exist in every catalogue).
- `ProductForm` hand-appended `" *"` to "Base Price" while core's `.input`
  renders the marker for `required` (core 2.43.0 does too). *Fixed.*
- `Translations` kept a private `product_status_label/1` beside
  `StatusLabels.product/1`. *Fixed.*
- Misplaced comments in `legacy.ex` and `translations.ex`, and a stale
  "never persisted" comment in `build_order_attrs`. *Fixed.*
- `StatusLabels.cart/1` has no clause for the transient `"converting"`
  status. *Left:* a new msgid in six catalogues for a state visible for
  milliseconds.
- `bulk_update_*_status` accept any binary status from `phx-value-status`,
  bypassing the changeset's inclusion check. *Left:* admin-only, and the
  category status set is wider than the form's (`deleted` is written by
  other paths).
- `convert_cart_to_order` logs activity inside the context and returns atoms
  without `Errors.message/1` clauses (`:shop_disabled`, `:product_not_available`,
  …) — pre-existing, contradicts AGENTS.md; `add_to_cart/update_cart_item`
  docs omit the new `:invalid_quantity`. *Left.*
- `ImportConfigs` `gated_event` clauses have no fall-through for a payload
  that matches none; admin-only. *Left.*
- No aggregate deadline across `AdminClient.complete_all`'s per-product
  backfills. *Left.*

## Verified clean

Guest-account reuse security (the proof is an order the guest branch itself
stamped, bound to the account's current email; a forged `custom_fields.source`
is not enough); `ShopDomain.validate/1` and `same_host?/2`; `AdminClient`
(no redirect, host-checked next link, page/time caps); the options advisory
lock and `keep_values_added_since`; atom option errors all have
`Errors.message/1` clauses; PubSub unification (no `PubSubHelper` left in
`lib`); workers all on `shop_imports`; upload-name sanitising; the backfill
task's `btrim` parameter; the `<details>` `JS.ignore_attributes(["open"])`
fix; the product-page gallery IDOR guard; og/canonical construction (#85);
`Helpers.ignore_event` as the last clause in every public LiveView.

## Test notes

Baseline before the fixes: 2953 tests, 26 failures (see FOLLOW_UP.md for the
comparison after the fixes).
