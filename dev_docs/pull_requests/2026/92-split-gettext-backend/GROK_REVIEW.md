# PR #92 — Split the Gettext backend by locale and domain

**Author:** Max Don · **Merged:** `17cdd19` · **Reviewed:** 2026-10-15

One-file change: `use Gettext.Backend` gains `split_module_by: [:locale, :domain]`.
The six catalogues are ~7.6k lines each (~45k total) and previously compiled
as one module. Gettext 1.0.2 (the lock; `~> 1.0` in `mix.exs`, and the option
has existed since 0.19) builds one module per locale and domain and compiles
those in parallel. The public backend stays `PhoenixKitEcommerce.Gettext`.

## Findings

No BUG-level findings.

### NITPICK — nothing pinned the split, so dropping it would stay green

`Gettext.Compiler` puts the per-locale clauses on
`PhoenixKitEcommerce.Gettext.T_<locale>_default` and leaves `lgettext` /
`lngettext` on the parent, including the catch-all that calls
`handle_missing_translation/5`. Lookups in `i18n_test.exs` would still pass
if the option were removed, and the serial compile would return.

A beam-file listing is not enough: an incremental compile leaves the old
`T_*` files in `ebin`.

**Fixed:** `test/phoenix_kit_ecommerce/gettext_backend_test.exs` reads the
parent beam's abstract code and requires a dispatch to each of the six
`T_<locale>_default` modules, then checks "My Cart" in every shipped locale,
the Ukrainian plural forms at 1, 2, 5, 11 and 21 (three forms, and 21 shares
an index with 1), and the msgid fallback for an unshipped locale and domain.

### NITPICK — `:domain` does not split anything today

Each locale ships only `default.po`, so `[:locale, :domain]` and `[:locale]`
produce the same six modules. A second domain would get its own module
without another edit. Left as is.

## Checked, no change needed

- **Dispatch.** After a forced recompile the ebin contains exactly
  `T_{de,en,et,fr,ru,uk}_default` plus the parent. The parent's `lgettext/5`
  clause for each locale calls `T_<locale>_default.<locale>_default_lgettext/3`.
  The missing-translation catch-all stays on the parent, so an unknown locale
  or domain returns the msgid instead of raising `FunctionClauseError`.
- **Plurals.** The plural function is a `defp` inside the split module; the
  public clause that the parent calls lives beside it. Ukrainian (three
  forms, including n=11 vs n=21) resolves. German and French n=0 were
  already pinned in `i18n_test.exs` and still go through this dispatch.
- **Locales.** Directory names are `en`, `et`, `ru`, `de`, `fr`, `uk` —
  all legal module segments. `split_module_name/3` concatenates the locale
  into the module atom, so a future `pt-BR` directory would not be.
- **Consumers.** Call sites use `Gettext` with `backend: PhoenixKitEcommerce.Gettext`
  or `Gettext.(d|dn)?gettext/put_locale/get_locale` on that module. Nothing
  in `lib/` or `test/` called the generated `*_lgettext` functions.
- **Recompile.** `@external_resource` for every `.po`, and `__mix_recompile__?/0`,
  are emitted on the parent before the split branch, so a catalogue edit
  still recompiles the backend.
- **Requirement.** `{:gettext, "~> 1.0"}` cannot resolve a gettext that lacks
  `split_module_by`. No floor bump.
