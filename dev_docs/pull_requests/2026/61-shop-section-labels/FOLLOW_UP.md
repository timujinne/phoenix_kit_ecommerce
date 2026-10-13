# PR #61 follow-up — Match the catalogue's labels and wording in the shop section

## Fixed (pre-existing)

- ~~BUG - MEDIUM (i18n): seven shop-section msgids were live fuzzy guesses.~~
  No `.po` under `priv/gettext/` carries a `fuzzy` flag, and
  `test/phoenix_kit_ecommerce/i18n_test.exs` fails a catalogue that does
  (`fuzzy_msgid/1`, `:336`) and pins the English visibility option (`:84`).
  `test/phoenix_kit_ecommerce/catalogue/extension_test.exs:276` refutes
  "products visible".
- ~~IMPROVEMENT - MEDIUM: the unset prompt dropped the em dashes.~~
  `lib/phoenix_kit_ecommerce/web/product_form.ex:965` is
  `gettext("— Category not set —")`.

## Not changed by the reviewer (design notes, not defects)

- The shop's own admin forms (`ProductForm`, `CategoryForm`, …) still use
  `.fieldset` wrappers and Title Case labels. The review scoped this PR to the
  section rendered inside catalogue's forms and called the rest a separate
  sweep.

## Open

None.
