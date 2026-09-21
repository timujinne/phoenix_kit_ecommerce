# Code Review: PR #61 — Match the catalogue's labels and wording in the shop section

**Reviewed:** 2026-09-20
**Reviewer:** Grok (grok-4.6)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/61
**Author:** Max Don
**Merge SHA:** b1657ce (squash)
**Status:** Merged

## Summary

Two fixes from the owner's review of the catalogue module, applied to the
shop's side of that form:

1. The product form's category prompt read "No category" (as if the list
   were empty). It is now an unset prompt, in every shipped locale. The
   product *page*'s "No category" is unchanged — there it states a fact
   about that product.
2. The shop section that catalogue's item and category forms render was
   wrapped in daisyUI `.fieldset` (which sets `font-size: .75rem`), so
   its labels sat at 12px beside the catalogue's 14px ones. Wrappers
   gone; heading and card match the catalogue (`text-base font-semibold
   text-base-content/80` with a `w-4 h-4` icon, `shadow-lg`); Title Case
   labels that appear in both places are sentence case.

**The layout change is correct.** Checked against the producing code,
not the PR description:

- **The 12px cause is real.** daisyUI 5 `.fieldset` sets `font-size:
  .75rem`. Core's `<.input>` / `<.select>` labels are
  `<label class="label mb-2"><span class="font-semibold">` (see
  `PhoenixKitWeb.Components.Core.Input` and `FormFieldLabel`, which
  exist specifically so a select label is indistinguishable from an
  input one). Nesting those inside `.fieldset` is exactly the "why a
  different font?" the catalogue's
  `dev_docs/guides/ui-conventions.md` forbids. The featured-item
  custom labels now copy that markup byte for byte (`label mb-2` +
  `font-semibold`), not `fieldset-legend`.
- **The heading and card match.** Catalogue section headings are
  `<h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">`
  with a `w-4 h-4` icon; its cards are `shadow-lg`. Both copies of
  `#ext-ecommerce-section` now use that, replacing `card-title text-xl`
  / `shadow-xl`.
- **"No category" on the product page is the right leave-alone.**
  `product_detail.ex` still gettexts `"No category"`: that is an empty
  state about the product, which the catalogue convention keeps as a
  full-stop fact, not an unset prompt.
- **The four sentence-case label msgids that were renamed in place
  (`Product type`, `Compare at price`, `Cost per item`, and the
  matching product-form copies) kept their translations and are not
  fuzzy.** Those do render as claimed.

Two findings, both fixed. One wording slip the PR description claimed
was already done.

## Findings

### 1. BUG - MEDIUM (i18n) — the category visibility options (and four siblings) were still the fuzzy product-form guesses at runtime

**Files:** `priv/gettext/{en,et,ru,de,fr}/LC_MESSAGES/default.po`

AGENTS.md: fuzzy entries are live at runtime, so a merge that guesses
from a nearby msgid ships that guess. Elixir Gettext compiles them;
empty-msgstr completeness does not see them.

#61 lowercased three shop-section msgids:

- `Active — category and items visible`
- `Unlisted — category hidden, items still visible`
- `Hidden — category and items hidden`

and left them `#, …, fuzzy` with the msgstr Gettext had copied from the
shop category form (`Active — Category and products visible`, and the
same Title Case + "products" in every locale). English therefore still
rendered the old string — the msgid change was a no-op for the case
the owner screenshotted. The same block had four more fuzzy leftovers
this PR did not reword but did reship:

| msgid | live msgstr (en) |
|---|---|
| Charge tax on this item | Charge tax on this product |
| Download limit | Download Limit: |
| Featured item (image fallback) | Featured Product (image fallback) |
| Requires shipping | Requires Shipping: |

The colons are the old `fieldset-legend` captions. `Download limit`
and `Requires shipping` sitting next to core labels that have no colon
is the same class of "why does this one look different?" as the font.

**Fixed.** All seven unfuzzied. English msgstrs emptied so they fall
through to the msgid (the catalogue's `en` convention). de/fr "products"
aligned with the non-fuzzy sibling already in this section
(`Auto-detect (first item with an image)` → Artikel / article); et/ru
already used `toode` / `товар` there, matching the catalogue's own
Estonian `Item` → `Toode`, so those stayed. Trailing colons dropped.

`I18nTest` now fails a catalogue that still carries `, fuzzy`, and
asserts the English visibility option is the msgid, not the product-form
guess. `ExtensionTest` renders the category section and
`refute`s `"products visible"`.

### 2. IMPROVEMENT - MEDIUM — the unset prompt dropped the catalogue's em dashes

**File:** `lib/phoenix_kit_ecommerce/web/product_form.ex`

The catalogue convention this PR is matching is explicit:
`"— X not set —"` (`"— Manufacturer not set —"`, `"— Attribute group
not set —"`). The PR body says the prompt now reads
`"— Category not set —"`. The msgid was `"Category not set"` — the
words, not the dashes. Core's `<.select prompt>` interpolates the
string as-is; it does not wrap it.

**Fixed.** Prompt is `gettext("— Category not set —")`, translated in
en/et/ru/de/fr. `FormLvsTest` asserts the dashed form and still
`refute`s `"No category"`.

Deliberately **not** renamed: `category_form.ex`'s
`"No parent (root category)"` (the extra "root category" is load-bearing
and is not an unset-value prompt in the catalogue sense) and
`products.ex`'s bulk-action `"No Category"` (an unassign action, not a
select). The product page's `"No category"` stays, as the PR said.

## Tests

- `test/phoenix_kit_ecommerce/i18n_test.exs` — dashed prompt in every
  shipped locale; English visibility option is the msgid; no `.po`
  carries `fuzzy`.
- `test/phoenix_kit_ecommerce/web/form_lvs_test.exs` — the product form
  renders `"— Category not set —"`.
- `test/phoenix_kit_ecommerce/catalogue/extension_test.exs` — item and
  category sections: sentence-case labels, catalogue heading class, no
  `fieldset`, category options say "items" not "products".

## Not changed

The shop's own admin forms (`ProductForm`, `CategoryForm`, …) still wrap
fields in `.fieldset` and still Title Case many labels (`Base Price`,
`Product Details`, `Tax Settings`). Those pages are not the shop
*section* sitting next to catalogue labels, which is what the owner
screenshotted. Restyling them is a separate sweep.

## Gate

`mix precommit` (compile --warnings-as-errors + format + credo --strict +
dialyzer) and `mix test` — see the release commit.
