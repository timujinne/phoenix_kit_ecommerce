# Code Review: PR #11 — Admin i18n wave: gettext-wrap all admin LiveViews, module backend, ru/et catalogs

**Reviewed:** 2026-07-14
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/11
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** a74547786f90defe2f7d065d37df0d92e208d77f
**Merge SHA:** 8d3236a25fbcd75c92585c31e59f16be3dc59300
**Status:** Merged

## Summary

Ten branch commits (plus an upstream-sync merge) that gettext-wrap the 12
admin LiveViews of the e-commerce module (carts, categories, category
form, dashboard, import show, imports, product detail, product form,
products, settings, shipping method form, shipping methods), switch admin
i18n onto the module-owned `PhoenixKitEcommerce.Gettext` backend, and
extend the ru/et catalogs (483 → ~2,500+ msgids). A prior in-branch
"second-opinion review" pass (`ebaa387`, `a745477`) already fixed several
issues before merge: missing `ngettext` on cart item-count badges,
`Gettext.gettext(PhoenixKitWeb.Gettext, ...)` calls left over from the old
backend, 18 fuzzy-merge-poisoned ru/et msgids (translations bled over from
an unrelated adjacent label), and a Russian plural-form-0 bug (`n=21`
rendering as if `n=1`).

This review targeted what that pass didn't cover: whether the wrapping is
actually *complete* across the 12 touched files (not just whether
`mix gettext.extract --check-up-to-date` passes — that check only
verifies already-`gettext()`-wrapped calls are reflected in the catalog;
it has nothing to say about strings nobody wrapped in the first place).

## Issues Found

### 1. [BUG - MEDIUM] `product_form.ex` — Translations tab and 7 other help strings never wrapped — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/product_form.ex`
**Confidence:** 100/100

The PR's own description claims "two gap-closure rounds and audit-blind-spot
strings in product_form/settings," but a full sweep of the post-merge file
turned up a dozen raw English strings still rendered to non-English admins
regardless of locale — none of these appeared in the `.pot`/`.po` catalogs
at all, so `mix gettext.extract --check-up-to-date` (which the PR's
"Required testing" section cites as a pass criterion) could never have
caught them:

- The entire `<.translation_fields>` field list for products (`Title`,
  `URL Slug`, `Description`, `Full Description (HTML)`, `SEO Title`,
  `SEO Description` labels + 5 placeholders + 1 hint) — the sibling block
  in `category_form.ex` *was* fully wrapped by this same PR, so this reads
  as an oversight rather than a deliberate omission. Ironic given it's the
  UI for editing *product* translations.
- `"Translate product content for different languages...."` help text
  (the `category_form.ex` equivalent of this exact sentence was wrapped).
- `"Select which option values are available for this product."` /
  `"Add custom options for this product."`
- `"Leave as \"Default\" to use global option values..."`
- `"Link images to option values. When a customer selects an option..."`
- `"Drag images to reorder. First image is the featured (main) image."`
- `"Fill in the product specifications based on global and category
  options."`
- `"Price Range:"` label in the price-calculation preview.

**Fix applied:** wrapped all of the above in `gettext/1`, re-ran
`mix gettext.extract && mix gettext.merge priv/gettext`, and translated the
newly-extracted en/ru/et msgids (see Issue 3 for the fuzzy-merge fallout
that surfaced during the merge).

### 2. [BUG - MEDIUM] Additional unwrapped strings in `products.ex`, `imports.ex`, `import_show.ex`, `category_form.ex` — FIXED
**Files:** as listed
**Confidence:** 100/100

Same class of gap, found by diffing rendered template text against the
catalog file-by-file:

- `products.ex`: the products-table empty state — `"No products found"` /
  `"Create your first product to get started"` — was left raw, while the
  *identical* pattern on `categories.ex`, `carts.ex`, and
  `shipping_methods.ex` (all touched by this same PR) was correctly
  wrapped.
- `imports.ex`: the "no options mapped" CSV-import warning banner, and the
  entire confirm-step summary block (`"Import details:"`, `"Format:"`,
  `"Products:"`, `"Download images:"`, `"Skip empty categories:"`,
  plus the two `"Yes"`/`"No"` literals feeding it).
- `import_show.ex`: `"No products tracked for this import. Product
  tracking was added in a later version."`
- `category_form.ex`: `data-confirm="Remove this option?"` on the
  delete-option button (the sibling `data-confirm` on the same page's
  bulk-delete modal was wrapped; this one wasn't).

**Fix applied:** wrapped all of the above, matching each file's existing
`gettext`/`if ... do: gettext(...)` idioms.

### 3. [NITPICK] Fuzzy-merge poison reintroduced by `mix gettext.merge`, cleaned up as part of Fix 1/2
**Files:** `priv/gettext/{en,ru,et}/LC_MESSAGES/default.po`

Extracting and merging the newly-wrapped strings from Issues 1–2 caused
gettext's fuzzy-matcher to pre-fill 12 of the new msgids with the *wrong*
existing translation (e.g. `"No products found"` → pre-filled with
`"Категории не найдены"` / `"Kategooriaid ei leitud"`, i.e. "categories",
not "products"; `"Price Range:"` pre-filled from the pre-existing
colon-less `"Price Range"` entry; `"Translate product content..."` from
the category-form sentence it was fuzzy-matched against). This is exactly
the fuzzy-poison class the in-branch second-opinion review (`a745477`)
already fixed once for the strings that existed at merge time — it
recurs mechanically any time new similar-but-not-identical strings are
merged, so it isn't a regression in this PR's own work, just a mechanical
side effect of adding the Issue 1/2 fixes on top of it.

**Fix applied:** hand-verified and corrected all 14 newly-empty and 12
newly-fuzzy en/ru/et entries (26 strings × 3 locales), matching the
project's existing convention (en `msgstr` = `msgid`; ru/et translated
with correct noun agreement, colons preserved where the msgid has one).
Zero `fuzzy` flags and zero empty `msgstr`/`msgstr[N]` remain in any
locale after the fix (verified via a full-file scan, not just spot
checks).

### 4. [BUG - MEDIUM] Two list-header counts use plain `gettext` instead of `ngettext`, producing wrong grammar at `count == 1` — FIXED
**Files:** `lib/phoenix_kit_ecommerce/web/carts.ex:99`, `lib/phoenix_kit_ecommerce/web/shipping_methods.ex:82-84`
**Confidence:** 100/100

The in-branch review commit `ebaa387` ("Apply review fixes: ngettext for
cart item counts...") added `ngettext` for the cart *item*-count badges
and the categories/products page-header counts
(`"1 category"`/`"%{count} categories"`, `"1 product"`/`"%{count}
products"` — both correctly pluralized with 3 Russian forms). But the
*page-header* counts on the Carts and Shipping Methods list pages were
left as plain `gettext("%{count} carts total", count: @total)` and
`gettext("%{count} methods configured", count: length(@methods))` — a
single, non-plural msgid each.

Confirmed by reading the pre-fix `.po` files directly: the ru `msgstr` for
both hard-coded the genitive-plural noun form regardless of count —
`"%{count} корзин всего"` (genitive plural, correct only for `n=0,
5-20, 25-30, ...`) and `"%{count} методов настроено"` (same pattern). At
`count = 1` these render as **"1 корзин всего"** and **"1 методов
настроено"** — grammatically wrong, exactly the class of bug `a745477`'s
"Russian plural form-0" fix already addressed elsewhere in this same PR,
just not here.

**Fix applied:** converted both to `ngettext("1 cart total", "%{count}
carts total", @total, count: @total)` and `ngettext("1 method
configured", "%{count} methods configured", length(@methods), count:
length(@methods))`, matching the categories/products pattern. Added
correct 3-form ru plural translations (`корзина`/`корзины`/`корзин`,
`метод`/`метода`/`методов`) and 2-form et translations
(`ostukorv`/`ostukorvi`, `meetod`/`meetodit`).

## What Was Done Well

- **The `data-bulk-text-template={gettext("%{count} selected", count:
  "%{count}")}` idiom** in `products.ex` (self-substituting the
  interpolation placeholder to produce a translated JS-hook template
  string) isn't a bug — it's the exact pattern `phoenix_kit` core itself
  uses for the same purpose (`bulk_select.ex`'s `reorder_selected_label`),
  confirmed by reading core's source and its explaining comment. Flagged
  it as suspicious initially, verified it against the upstream convention
  before writing it up.
- **Backend unification** (`Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")`
  → `gettext("Delete")` in `imports.ex`/`settings.ex`) correctly removes
  the last stragglers pointing at the wrong Gettext backend.
- **`ngettext` used correctly everywhere it was used** — cart item-count
  badges, category/product header counts, and the new digital-product
  "download expiry in N days" string all thread `count:` through properly.
- The in-branch second-opinion review already caught and fixed the
  Russian plural-form-0 bug class and 18 fuzzy-merge-poisoned entries
  before merge — this review found the same *class* of issue recurring in
  places that pass didn't touch (Issues 3–4), not a fresh mistake.

## Validation

- `mix compile --force --warnings-as-errors` — clean, before and after fixes.
- `mix gettext.extract --check-up-to-date` — passes, before and after
  fixes (as noted above, this check cannot detect never-wrapped strings —
  Issues 1–2 were found by manually diffing rendered template text
  against the catalog, file by file, not by this gate).
- `mix format` — applied to all touched `.ex`/`.po`/`.pot` files.
- Post-fix catalog scan: 0 `fuzzy` flags, 0 empty `msgstr`/`msgstr[N]`
  across all three locales (en/ru/et).
- `mix precommit` — kicked off in the background for this review; see
  follow-up note if it surfaces anything beyond what's captured here.

## Verdict

**Approved with fixes applied.** The PR's core mechanical work (gettext-
wrapping ~500 msgids across 12 LiveViews, backend unification, fuzzy-poison
cleanup) is sound and the in-branch review pass already caught the
highest-value bugs (plural form-0, backend stragglers, fuzzy poison at
merge time). This review found the same two bug classes — incomplete
wrapping coverage and missing `ngettext` on count strings — recurring in
files/strings the first pass didn't reach, all fixed in this pass with
translations added for all three locales.
