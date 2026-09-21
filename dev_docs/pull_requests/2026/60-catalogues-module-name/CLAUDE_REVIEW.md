# Code Review: PR #60 — Name the Catalogues module by its name

**Reviewed:** 2026-09-19
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/60
**Author:** Max Don
**Merge SHA:** 17ee4a9 (squash)
**Status:** Merged

## Summary

`phoenix_kit_catalogue` now calls itself "Catalogues" (`module_name/0` in
`lib/phoenix_kit_catalogue.ex:55`, its tab label, its page headers). This PR
follows that through the shop's side of the boundary: the two "Manage in
Catalogue" buttons (`web/products.ex:371`, `web/categories.ex:349`) and the two
`redirect_to_catalogue/1` flashes (`web/product_form.ex:70`,
`web/category_form.ex:54`), with new translations in en/et/ru/de/fr and the
Estonian declension of `kataloog` corrected in the strings it touched.

**The change is correct as far as it goes.** Checked:

- **The link target did not move with the name.** `phoenix_kit_catalogue`
  still mounts at `/admin/catalogue` (`paths.ex:11`, `@base`), so the four
  call sites' `Routes.path("/admin/catalogue")` / `"/admin/catalogue"` hrefs
  still resolve. A rename that had also moved the URL segment would have
  turned every one of these into a 404, and only the labels were changed here.
- **The label matches what the shopper's admin actually sees in the nav.**
  The catalogue module's own catalogues translate its name as et `Kataloogid`,
  ru `Каталоги`, de `Kataloge`, fr `Catalogues`; this PR's new msgstrs use
  exactly those forms, so the button and the nav entry agree in every locale.
  These are two separate catalogues in two separate repos that must stay in
  sync by hand — worth re-checking on the next rename.
- **Catalogues are in sync.** `mix gettext.extract` on the merge commit
  produced no diff: the `.pot` and all five `.po` files match the source, the
  four references (`categories.ex:349`, `products.ex:371`,
  `category_form.ex:54`, `product_form.ex:70`) are accurate, the four old
  msgids are gone rather than left as duplicates, and no entry was marked
  fuzzy (a plain merge would have reworded these four from the old msgids and
  shipped them as live guesses — see the `--no-fuzzy` rule in AGENTS.md).
- **No `gettext` wrapping crept onto a path, event name or setting key**, and
  nothing about the redirect flow changed — `redirect_to_catalogue/1` is still
  reached only when `ProductSource.current/0` says `:catalogue`, which fails
  closed to Legacy when the catalogue module is not loaded, so the flash can
  never name a module the host does not have.

Two findings, both fixed.

## Findings

### 1. IMPROVEMENT - MEDIUM — the rename stopped four strings short, so the shop still calls the module "the catalogue" in prose

The PR renamed the two buttons and the two flashes. Four other user-facing
strings name the same module and were left saying "the catalogue":

| Where | String |
|---|---|
| `web/imports.ex:802` | "Products and categories now live in **the catalogue**. CSV import is disabled — use **the catalogue's** item form …" |
| `web/settings.ex:626` and `:1430` (one msgid, the warning under the toggle and the refusal flash) | "Not available while the shop reads products from **the catalogue** — …" |
| `web/translations.ex:188` | "Shop translations aren't available while the shop reads products from **the catalogue** — …" |
| `web/translations.ex:1370` | "Sweep did not run — translations aren't available while the shop reads products from **the catalogue**." |

The imports one is the same class of notice as the two flashes the PR did fix —
it is the third "your products live elsewhere now" banner, shown on exactly the
same condition (`@catalogue_source_active?`). An operator who switches the
product source sees "Manage in Catalogues" on the products page and "now live
in the catalogue" on the import page, one screen apart. The point of the rename
was one name, so half of it is the part that is confusing.

**Fixed.** All four now read "the Catalogues module", matching the flashes'
existing phrasing rather than inventing a fifth way to say it, with
translations written in all five locales against the module-name forms above
(`moodulis Kataloogid`, `модуля «Каталоги»`, `Modul „Kataloge“`,
`module Catalogues`). `mix gettext.extract && mix gettext.merge priv/gettext
--no-fuzzy` regenerated the catalogues; the four new msgids carry real
translations, nothing is fuzzy.

Deliberately **not** renamed: `settings.ex:931` ("a catalogue attribute set"),
`shopify_sync.ex:1373`/`1611` ("% of the Shopify catalogue", "Catalogue
coverage") and `vocabulary.ex`'s `"mixed"` storefront wording ("Catalogue",
"Browse Catalogue"). None of those names the module — the first is a domain
object inside it, the Shopify ones are Shopify's own catalogue, and the
vocabulary literals are storefront nouns a shop owner chooses. Renaming those
would make the shop wrong in a new way.

No conformance test was added to pin "the module is never called 'the
catalogue'". A regex over `gettext` literals cannot tell the four cases above
from the five legitimate lowercase ones, so it would fail on the next honest
string; the two updated tests below pin the strings that actually matter.

### 2. BUG - MEDIUM (i18n) — the Estonian declension the PR set out to fix survived in two more strings

The PR description says Estonian's "katalooguses" was "corrected on the way",
and it was — in the two strings the rename touched (`katalooguses` →
`kataloogides`, `katalooguse moodul` → `moodul Kataloogid`). But `kataloogus`
is not an Estonian word at all (the stem is `kataloog`: inessive `kataloogis`,
genitive `kataloogi`), and the same malformed form was still in two further
`et` msgstrs:

- the imports notice — "asuvad nüüd **katalooguses** … **katalooguse** üksuse vormi"
- `settings.ex:931`'s filter help — "põhineb **katalooguse** atribuudikomplektil"

So an Estonian operator kept reading the misspelling on the imports and
settings pages after the PR that claims to have removed it. A wording PR is
exactly when this gets fixed; left alone, the next reader assumes the form is
house style and copies it.

**Fixed.** The imports notice is retranslated as part of finding 1
(`moodulis Kataloogid` / `Kataloogide üksuse vormi`). The filter help is a
`msgstr`-only correction — its msgid did not change — to "põhineb **kataloogi**
atribuudikomplektil". `grep -rn kataloogus priv/gettext/` is now empty.

## Tests

- `test/phoenix_kit_ecommerce/web/settings_translations_test.exs` — the
  `:catalogue`-tagged toggle test asserted the old phrase. It now asserts
  "…from the Catalogues module" **and** `refute`s "reads products from the
  catalogue", so a revert to the old wording fails rather than passing on a
  substring.
- `test/phoenix_kit_ecommerce/shopify/sync_catalogue_test.exs` — the imports
  notice test asserted only "CSV import is disabled", which the rename does not
  touch. It now also asserts "now live in the Catalogues module", so the third
  notice is pinned the way the other two are.

## Gate

`mix precommit` (compile --warnings-as-errors + format + credo --strict +
dialyzer) and `mix test` — see the release commit.
