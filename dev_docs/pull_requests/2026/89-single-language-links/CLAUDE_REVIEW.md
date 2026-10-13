# PR #89 — Build storefront links with no locale segment on a single-language site

**Author:** Tymofii Shapovalov · **Merged:** `b74afd6` · **Reviewed:** 2026-10-13, after it shipped in 0.5.22
(the `PRs 84-88` review stopped one PR short)

Scope: `Shop.url_locale/1`, `Helpers.page_path/3`, the cross-language
redirect policy of the product and category pages, canonical/hreflang
(`SEOHelpers`), the order notification's language, and the 55-test
`single_language_links_test.exs`.

## Findings

### BUG - MEDIUM — `page_path/3` (and the My Orders filter) drop the query string

`Helpers.page_path/3` took `opts` and forwarded them to `Routes.path/2`,
which reads only `:locale`. `UserOrders` passes the status filter and the page
number there (`map_to_keyword/1`), so the `filter` and `change_page` events
patched to the bare `/dashboard/orders`: the status filter and the pagination
of "My Orders" never applied, and a customer with more than one page could not
leave the first. The call shape predates #89 (it was `Routes.path/2` directly),
but #89 rewrote these lines, gave `page_path/3` a keyword argument that looks
like it carries a query, and added the 947-line link test without a single
assertion on a patched URL — a link-shape change with no look at the link.

Fixed: `page_path/3` takes a `query` (map or keyword) and appends
`URI.encode_query/1`; `UserOrders` passes its maps directly, and the
`String.to_existing_atom/1` keyword helper is gone.
`user_orders_query_test.exs` fails on the old code (filter, page) and pins the
encoding and the empty-query case.

## Checked, no change needed

- **`url_locale/1` / `:none`.** `Routes.path(_, locale: :none)` has existed in
  core since 1.7.x, so the `>= 2.43.0` floor holds; only the primary-language
  tests need the 2.62 policy and they are tagged for it.
- **Redirect loops.** The only redirect left is to the SAME language's own
  slug, and the localized lookup resolves that slug directly, so the
  redirect cannot bounce. `publicly_visible?/1` still gates the product
  path; the category path keeps its hidden check before the new branch.
- **Components that read `assigns[:current_locale]`.** `billing_step`,
  `profile_selector` and `review_step` (which holds the cart/shipping/log-in
  links) all receive it; nothing else in `CheckoutPage` calls `page_path/3`.
- **Remaining `Routes.path/1` calls** in the public pages are admin links
  (which core localizes itself) and the notification link, which passes
  `locale:` explicitly.
- **Notification language.** `buyer_language/1` falls back to the primary
  language for an unenabled or missing code, never to the Gettext locale.
- **Canonical/hreflang.** A blank slug counts as untranslated in the
  redirect, the canonical and hreflang through the one
  `Helpers.slug_translated?/2`.

## Not from this PR

`TranslationsTest` "a tick whose enqueues all failed…" fails on a clean
checkout against `phoenix_kit_ai 0.25.5`: an explicit
`ai_translation_endpoint_uuid` is now binding for unattended runs, so a
bogus value answers "Sweep did not run" instead of enqueueing and failing per
language. The page's behavior is the sensible one; the test needs another way
to provoke an all-failed tick. Left open (see `FOLLOW_UP.md`).
