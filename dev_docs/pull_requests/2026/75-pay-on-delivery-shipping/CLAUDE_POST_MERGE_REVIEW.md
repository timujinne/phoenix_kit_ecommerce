# PRs #74 and #75: post-merge review

- **PRs:** #74 Add Ukrainian (uk) translations; #75 Add pay-on-delivery
  shipping methods instead of showing them as FREE
- **Authors:** Tymofii Shapovalov (timujinne)
- **Reviewer:** Claude (a separate, post-merge pass; the author-side
  `CLAUDE_REVIEW.md` files in both PR directories are not edited)
- **Merged state reviewed:** `main` at `8e9f417`
- **Verdict:** both PRs are correct on their own. One BUG - MEDIUM exists
  only in their combination and is fixed here.

## Findings

### BUG - MEDIUM: the `uk` catalogue lacks the five #75 strings (fixed)

#74 added `priv/gettext/uk` with every msgid then in `default.pot` (1098).
#75 added five msgids and translated them for de/et/fr/ru only, because
`uk` was not on its base. Each PR was green on its own branch. Merged
together, `uk` has 1098 msgids and `default.pot` has 1103, so a Ukrainian
shopper sees English for:

- `Paid on delivery`
- `Carrier rates, paid on delivery` (also stored on the order's shipping
  line)
- `Paid on delivery at carrier rates`
- `Shipping is not included in this total: you pay the carrier at their
  rates on delivery.`
- the admin form hint (`The customer pays the carrier at their rates on
  delivery. ...`)

`i18n_test.exs` has a "no untranslated message" test per locale, and it
did not fire: it only inspects entries that exist, and a merge that never
ran leaves no entry at all.

**Fix.** `mix gettext.merge priv/gettext --no-fuzzy` added the five
entries to `uk` only, and they are translated in line with the `ru` text
and the terms #74 settled on (покупець, доставка, перевізник). A new test,
"<locale> carries every msgid in the template", compares each translated
catalogue's msgids with `default.pot`. It fails on the pre-fix `uk` file
with the five names above and passes now.

### Checked, no finding

- **Changeset (#75).** The flag is popped from the attrs before `cast/3`,
  so `metadata` is never replaced. A flagged method always stores price 0
  and no `free_above_amount`, on every write path. `:unset` keeps the
  stored flag.
- **Stale cart refresh.** `recalculate_cart_totals!` returns the cart with
  `[:items, :shipping_method]` force-preloaded, so the broadcast from the
  refresh carries a loaded method and `cart_shipping_pay_on_delivery?/1`
  does not fall through to "FREE". A refused refresh (`:cart_not_active`
  rolls back, not raises) leaves the cart as loaded on both pages.
- **Write in `mount`.** The refresh writes in `mount/3`, which runs twice.
  The second run sees a non-stale cart, so it is a no-op. It is not a
  query-per-mount problem.
- **Remaining "FREE" renderings** (`cart_page.ex`, `checkout_page.ex`) are
  all behind a `cart_shipping_pay_on_delivery?/1` or `free?` branch
  checked first.
- **#74 plural forms.** The `%{count}` pin covers every plural entry, and
  `uk` has no fuzzy entries.

### Known limitation, not changed

Billing's plain-text email prints the pay-on-delivery shipping line as
0.00 and its admin order edit drops the `"pay_on_delivery"` key. This is
documented in AGENTS.md and in the code comment, and the fix belongs in
`phoenix_kit_billing`.

## Validation

- `mix precommit` (format, `compile --warnings-as-errors`, `credo --strict`,
  `dialyzer`): clean.
- `PGPOOL=10 mix test`: 1639 tests, 0 failures (276 excluded). That is the
  1632 from the author's round 3 plus the five new per-locale tests and
  two more that landed since.
- The new template-coverage test fails on the pre-fix `uk` catalogue and
  passes after the merge and translation.
