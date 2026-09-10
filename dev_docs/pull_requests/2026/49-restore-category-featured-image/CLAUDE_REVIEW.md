# Code Review: PR #49 — Restore category featured-item image on the catalogue source

**Reviewed:** 2026-09-10
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/49
**Author:** Tymofii Shapovalov (timujinne)
**Merge SHA:** 8ae2cab
**Status:** Merged

## Summary

Builds directly on **PR #48** (`e1516e2`, merged immediately before this one —
the storefront layout reshuffle, the shared breadcrumb/actions row,
`Helpers.admin_edit_path/3` and the `load_more` sync pagination all originate
there, not here; #48 is outside this review's assigned scope but its own commit
message is reused verbatim in this PR's squashed commit body, which reads as if
#49 introduced that work — it didn't, see the attribution notes below). This
PR's own delta: extends the admin edit links (`shop.manage_catalog`-gated,
carrying `return_to`) to more admin list/detail pages, adds a per-filter clear
button and a house icon on the Shop breadcrumb, and the headline fix — category
featured-item images broke silently after the move to `phoenix_kit_catalogue`
because `category_view/2` never populated the `:featured_product` association
`Category.get_image_url/2`'s fallback reads. `Query.resolve_category_images/1`
now resolves it for a batch of categories in at most two item queries plus one
shared catalogue lookup, and the category form's featured-item picker moved
from a raw UUID field to a details-dropdown of thumbnails, cached per category
in the LiveView process.

## Verification

- Read every touched file with surrounding context, not just the diff hunks.
- Traced `Query.resolve_category_images/1`'s query-count doc claim ("at most two
  item queries plus the one catalogue lookup they share") against the actual code
  and the tests that pin it — holds.
- Verified the image priority chain (category's own `featured_image_uuid` >
  resolved featured item > auto-detect) against `catalogue_view_test.exs` and
  `catalogue_categories_test.exs` — correct, despite several in-PR reversals on
  where the picture comes from.
- Verified `shop.manage_catalog` gating is applied consistently at every new
  edit-link site (`products.ex`, `categories.ex`, `product_detail.ex`,
  `import_show.ex`, `catalog_product.ex`, `catalog_category.ex`) via
  `Helpers.maybe_assign_admin_edit/4`'s default scope.
- Confirmed `return_to`'s handling in `admin_edit_path/3` is same-origin/
  server-derived (`URI.parse(uri).path`, documented as intentional) — not an open
  redirect.
- Confirmed the Shopify sync `load_more` event scoping (`"load_more_rows:" <>
  field_str`) correctly isolates each section, and the field→atom conversion uses
  `String.to_existing_atom/1` with a rescue — safe against atom exhaustion.
- **`mix precommit` (format, `compile --warnings-as-errors`, `credo --strict`,
  dialyzer) failed** on a plain `mix deps.get` (no `PHOENIX_KIT_CATALOGUE_PATH`
  override) — see Issues #1 below.
- **`mix test` failed to even compile** on the same plain checkout — see Issue #2.
- **`mix test` had 4 guaranteed failures** on the same plain checkout — see Issue #3.
- After fixing #1–#3: `mix precommit` clean, `mix test` 1048 tests / 0 failures
  (201 excluded) on a plain checkout; re-ran the affected files with
  `PHOENIX_KIT_CATALOGUE_PATH`/`PHOENIX_KIT_ENTITIES_PATH` set — the 4
  `storefront_admin_edit_test.exs` catalogue-tagged tests pass; the
  `shop_sections_test.exs` DB tests still fail on `undefined_column "slug"`,
  confirmed to be pre-existing schema drift between this workspace's local
  `phoenix_kit_catalogue` checkout and its own migrations (this environment has no
  privilege to create/migrate a fresh test database to verify) — not something this
  PR or this review introduced.

## Issues Found

### 1. [BUG - HIGH] Missing duck-type compile guard breaks `mix precommit` for any consumer without the optional catalogue dependency — FIXED
**File:** lib/phoenix_kit_ecommerce/web/helpers.ex, `catalogue_edit_path/2` (lines 585-586 pre-fix)
**Confidence:** 100/100

**Attribution correction:** `admin_edit_path/3` and `catalogue_edit_path/2` were
actually introduced by **PR #48** (`e1516e2`, the immediate prerequisite this PR
builds on), not by #49 itself — #49 only extends the same helper's edit-link
usage to more admin pages. #48 is outside this review's assigned scope (#49–#53),
but since the bug ships unreleased regardless of which PR introduced it, and
blocks this repo's own `mix precommit` gate, it's fixed here rather than left for
a separate #48 review that wasn't requested.

`admin_edit_path/3` calls `PhoenixKitCatalogue.Paths.item_edit/1`/`category_edit/1`
only after its own `Code.ensure_loaded?(PhoenixKitCatalogue.Paths)` runtime guard —
correct at runtime — but the module never got the
`@compile {:no_warn_undefined, ...}` tag that every other duck-typed catalogue call
site in this codebase carries (`view.ex`, `query.ex`, `writer.ex`, `sync.ex`, …).
On a checkout that doesn't declare the optional `phoenix_kit_catalogue` dependency
(the default, documented case — AGENTS.md's "No catalogue version floor"),
`mix compile --warnings-as-errors` — and therefore `mix precommit`, this repo's own
committing gate — failed outright with two `PhoenixKitCatalogue.Paths.*/1 is
undefined` warnings-as-errors. This is not a hypothetical: it reproduced on this
exact checkout with a plain `mix deps.get`.

Fixed: added `@compile {:no_warn_undefined, PhoenixKitCatalogue.Paths}` to
`Web.Helpers`, matching the established convention, plus a matching
`.dialyzer_ignore.exs` entry for the two resulting `unknown_function` dialyzer
warnings (same shape as every other duck-typed file's entry).

### 2. [BUG - HIGH] A test file's `%PhoenixKitCatalogue.Schemas.Category{}` struct literal breaks `mix test` compilation entirely, for the whole suite, without the optional dependency — FIXED
**File:** test/phoenix_kit_ecommerce/catalogue/shop_sections_test.exs:118 (pre-fix)
**Confidence:** 100/100

`shop_sections_test.exs` is `@moduletag :catalogue`, correctly excluded from
*running* whenever `phoenix_kit_catalogue` isn't loaded — but `mix test` compiles
every test file before applying tag exclusions, and one test built a
`%PhoenixKitCatalogue.Schemas.Category{uuid: nil}` struct via literal syntax, which
needs the struct's fields resolvable at COMPILE time. Without the optional
dependency this is a hard `CompileError`, not a skip — and a `CompileError` in one
test file aborts the entire `mix test` run, not just that file's tests. This
reproduced on a plain checkout: `mix test` failed to run *at all*, breaking
AGENTS.md's own stated guarantee ("the suite is two-tiered: unit tests … always
run"). None of this PR's own catalogue integration tests exercise this path
(`shop_status_column_catalogue_integration_test.exs` explicitly documents this
exact hazard and uses `struct!/2` instead — this file just didn't follow it).

Fixed: switched to `struct!(PhoenixKitCatalogue.Schemas.Category, uuid: nil)`,
matching the documented convention.

### 3. [BUG - MEDIUM] Four tests assert catalogue-only behavior without a `:catalogue` tag — guaranteed failures on a plain checkout — FIXED
**File:** test/phoenix_kit_ecommerce/web/storefront_admin_edit_test.exs (4 tests)
**Confidence:** 100/100

**Attribution:** 2 of the 4 tests ("...opens the catalogue category/item editor")
were added by **PR #48** (see the attribution note on Issue #1); the other 2
("the products/categories list edits in the catalogue…") were added by #49
itself. Fixed together since both PRs ship unreleased in the same batch.

"with the catalogue source on, the link opens the catalogue category/item editor"
(category page + product page describe blocks) and "the products/categories list
edits in the catalogue…" (admin list/detail describe block) all call
`Helpers.admin_edit_path/3` directly and assert the catalogue-editor path
(`/admin/catalogue/items/.../edit`). That branch is only taken when
`Code.ensure_loaded?(PhoenixKitCatalogue.Paths)` is true — false on any checkout
without the optional dependency, where the function correctly falls back to the
legacy path. None of the four tests (nor the module) carried `@tag :catalogue` /
`@moduletag :catalogue`, so `mix test` on a plain checkout failed all four,
deterministically, every run.

Fixed: added `@tag :catalogue` to each of the four tests. `mix test` now passes
cleanly on a plain checkout (201 tests correctly excluded, up from 197); re-run
with the local catalogue path dep confirms all four pass for real.

## What Was Done Well

- The image priority chain and its query-count discipline are exactly as
  documented, and the two-query batch resolution genuinely avoids the
  per-category/per-keystroke N+1 an earlier version of this PR had (per its own
  commit history) — the fix is real, not just claimed.
- `return_to` reuses `:url_path`'s own path-only convention rather than inventing a
  new one, and is validated by both catalogue forms before use.
- Permission gating on every new edit-link site is uniform and was checked, not
  assumed, against the underlying helper's default scope.
- The `load_more` per-section pagination change is a direct, well-reasoned fix for
  a real problem (client-side bulk selection cannot survive a window-pager
  replacing rows) and is covered by tests that assert the invariant that actually
  matters (loading past the end settles on what remains) rather than the brittle
  window-paging shape it replaced.

## Gate

`mix precommit` and `mix test` both clean after the three fixes above (see
Verification). Fixes for #1–#3 are committed alongside this review as part of the
#49–#53 review sweep.
