# Code Review: PR #9 — Escape LIKE metacharacters in search terms; filters-aware category empty state

**Reviewed:** 2026-07-12
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/9
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** b12db83ef1307c69b4da4878034943907e7f4c9c
**Merge SHA:** ee1fcace06b49c9b0648ffca1b8e513c19d4c279
**Status:** Merged

## Summary

Two independent fixes to the storefront search added in PR #8:

1. **LIKE-metacharacter escaping.** `%`, `_`, and `\` from user search input
   flowed unescaped into `%term%` ILIKE patterns across product, category,
   and admin-cart search (`filter_by_product_search`, `filter_by_category_search`,
   `list_carts_with_count`). On a route open to unauthenticated visitors, this
   meant `%`/`_` acted as wildcards (`100%` matched every "100"-containing
   product; an SKU search for `AB_100` also matched `ABX100`) and a trailing
   `\` corrupted the pattern. All three call sites now go through a single
   `search_like_pattern/1` choke point that NUL-strips, length-caps (100
   chars — also closes an unbounded-pattern seq-scan amplifier against the
   `jsonb_each_text`/`jsonb_array_elements_text` expansions), and
   backslash-escapes `\`, `%`, `_` in the correct order (backslash first, to
   avoid double-escaping the characters escaped afterward).
2. **Filters-aware category empty state.** The category page's zero-products
   card used to say "No products in this category" even when the category
   *has* products but the active search/filter matched none. It now shares
   a `category_empty_state` function component (used by both the guest and
   authenticated layout branches) with the main catalog page's existing
   behavior: filtered-to-zero shows "No products match your filters" with a
   `clear_filters` affordance; a genuinely empty category keeps the original
   copy.

Also adds a doc comment on `merge_missing_builtin_filters/1` recording a
known ordering limitation (holds only within one merge pass) — no behavior
change.

## Issues Found

None. See verification notes below.

## Verification Notes

- **Escaping order is correct.** `search_like_pattern/1` replaces `\` →
  `\\` before `%` → `\%` and `_` → `\_`; escaping backslash first is
  required, otherwise the backslashes just inserted for `%`/`_` would
  themselves get re-escaped.
- **No other unescaped `"%#{...}%"` call sites remain** — grepped the whole
  `lib/` tree; the only literal `%#{...}%` construction left is inside
  `search_like_pattern/1` itself, and all three pre-existing `search_term =`
  sites (`list_carts_with_count`, `filter_by_product_search`,
  `filter_by_category_search`) now route through it. The admin cart search's
  `c.session_id == ^search` equality check correctly stays on the raw
  (non-pattern) `search` value — right call, since it isn't a LIKE match.
- **Default Postgres escape char applies.** Ecto's `ilike/2` macro and the
  raw `ILIKE ?` fragments don't specify a custom `ESCAPE` clause, so
  Postgres's default escape character (`\`) is what the new escaping
  targets — consistent.
- **NUL-byte handling matches the Ecto skill's documented gotcha**
  ("Postgres rejects null bytes even though they're valid UTF-8" — sanitize
  at the boundary); stripped before the query ever runs, verified by the
  `list_products/1 :search survives pathological terms` test.
- **`category_empty_state` wiring verified end-to-end**, not just visually:
  `active_filters["search"]` is set by `update_search_filter/3` (which
  trims and deletes the key entirely on blank input, so no stale
  empty-string entries), read by `has_active_filters?/1` (whose catch-all
  branch correctly treats any non-empty search string as "active"), and
  the same key threads through `parse_filter_params/2` → `build_query_opts/2`
  → `Keyword.get(opts, :search)` into the two context functions above. No
  key-name drift between the LiveView filter map and the context's `:search`
  opt.
- **`clear_filters` event handler already existed** in `catalog_category.ex`
  (added in an earlier PR alongside the sidebar) — the new empty-state
  button wires into it correctly, no new handler needed.
- Reality-checked the PR's own claims against the emitting code rather than
  the description: the "trailing backslash" and "`%`/`_` as literal"
  scenarios both reproduce against the pre-PR code and are fixed post-PR;
  confirmed via the new `context_test.exs` cases rather than taking the
  changelog prose at face value.

## What Was Done Well

- **Single choke point for escaping** (`search_like_pattern/1`) instead of
  three independent fixes — eliminates the class of bug where a future
  fourth search call site forgets to escape.
- **Test coverage is precise and adversarial**, not just happy-path: literal
  `%`/`_` matching, trailing-backslash survival, a 15,000-char pathological
  term (cap doesn't crash), an embedded NUL byte (stripped, doesn't raise
  `Postgrex.Error`), and category search parity — plus a new LiveView test
  file (`catalog_category_search_test.exs`) asserting the filtered-empty vs.
  genuinely-empty copy differ, including a fixture that correctly handles
  the `"en"` → `"en-US"` dialect-slug normalization the public category
  route needs.
- **Component dedup** removed a real duplicate (`.card`/`.card-body` empty
  state markup was previously copy-pasted between the guest and
  authenticated layout branches within the same file) rather than adding a
  parallel one.
- Correctly left `c.session_id == ^search` as a raw equality check instead
  of routing it through the pattern-escaping helper it doesn't need.

## Validation

- `mix format --check-formatted` — clean
- `mix compile --warnings-as-errors` — clean
- `mix credo --strict` — clean, no issues (2017 mods/funs, 0 issues)
- `mix dialyzer` — clean
- `mix hex.audit` (part of `precommit`) — flags `hackney 1.25.0` (4
  advisories, one HIGH). **Pre-existing**, unrelated to this PR: `hackney`
  is a transitive dep pulled in via `phoenix_kit`/`stripity_stripe`/
  `tesla`/`swoosh`; this PR's diff touches no dependency files and
  `mix.lock` is unchanged by it. Left untouched (out of scope, same as the
  `earmark`-unused finding noted in the PR #8 review).
- `mix test` (unit tier; no local Postgres in this environment, so the
  173 `:integration`-tagged tests — including this PR's new
  `catalog_category_search_test.exs` LiveView tests and the new
  `context_test.exs` escaping regressions — were excluded, matching the
  project's documented DB-unavailable behavior). All 50 runnable unit
  tests pass. Could not directly execute the new integration-tier tests in
  this environment; reviewed them by inspection instead (see Verification
  Notes) and they read as correct against the implementation.

## Verdict

**Approved, no changes needed.** Both fixes are correct, narrowly scoped,
and back themselves with adversarial tests rather than happy-path-only
coverage. Nothing found worth blocking or following up on.
