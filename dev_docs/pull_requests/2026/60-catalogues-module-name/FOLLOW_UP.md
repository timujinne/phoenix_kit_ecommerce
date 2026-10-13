# PR #60 follow-up — Name the Catalogues module by its name

## Fixed (pre-existing)

- ~~IMPROVEMENT - MEDIUM: four user-facing strings still said "the
  catalogue".~~ All four read "the Catalogues module":
  `lib/phoenix_kit_ecommerce/web/imports.ex:802`,
  `web/settings.ex:715` and `:1601`, `web/translations.ex:188` and `:1354`.
  `grep "from the catalogue"` over `lib/` finds no rendered string.
- ~~BUG - MEDIUM (i18n): the malformed Estonian stem `kataloogus` survived in
  two msgstrs.~~ `grep -rn kataloogus priv/gettext/` is empty.

## Open

None.
