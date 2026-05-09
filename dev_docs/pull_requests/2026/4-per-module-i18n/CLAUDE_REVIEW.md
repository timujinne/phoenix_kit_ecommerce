# Code Review: PR #4 — Add per-module Gettext backend for sidebar tab labels

**Author:** timujinne (Tymofii Shapovalov)
**Merged:** 2026-05-09
**Merge commit:** `8359049`
**Reviewer:** Claude Opus 4.7
**Review date:** 2026-05-09

---

## Summary

Introduces `PhoenixKitEcommerce.Gettext` as a dedicated Gettext backend so the e-commerce module's sidebar tab labels can be translated independently of the parent application's catalogue. Ten `Tab.new!` registrations across `admin_tabs/0`, `settings_tabs/0`, and `user_dashboard_tabs/0` declare `gettext_backend: PhoenixKitEcommerce.Gettext`. Catalogues ship for `en`, `ru`, `et`. Behaviour gracefully degrades on `phoenix_kit` releases that pre-date the `gettext_backend` Tab API (PR BeamLabEU/phoenix_kit#522).

**Files changed:**

| File | +/- | Purpose |
|---|---|---|
| `lib/phoenix_kit_ecommerce/gettext.ex` | +13 / 0 | New `Gettext.Backend` module |
| `lib/phoenix_kit_ecommerce.ex` | +20 / -10 | Add `gettext_backend:` to all 10 `Tab.new!` sites |
| `mix.exs` | +6 / -3 | `:gettext` dep + extra_application, `priv` in package files, version bump |
| `priv/gettext/default.pot` | +49 / 0 | 9 msgids (manually maintained) |
| `priv/gettext/{en,ru,et}/LC_MESSAGES/default.po` | +144 / 0 | Catalogues |
| `test/test_helper.exs` | +22 / 0 | Conditional ExUnit start (skip i18n tests when API absent) |
| `test/phoenix_kit_ecommerce/i18n_test.exs` | +68 / 0 | 4 smoke assertions |
| `mix.lock` | +20 / -17 | Add `:gettext` and `:expo` |
| `CHANGELOG.md` | +5 / 0 | 0.1.4 entry |

---

## Change-by-Change Analysis

---

### 1. `lib/phoenix_kit_ecommerce/gettext.ex` — New backend module

**Verdict: Correct and minimal.**

```elixir
defmodule PhoenixKitEcommerce.Gettext do
  use Gettext.Backend, otp_app: :phoenix_kit_ecommerce
end
```

Uses the Gettext 1.0 split-module convention (`Gettext.Backend` defines the catalogue lookup; consumers `use Gettext, backend: PhoenixKitEcommerce.Gettext` to get the macros). The `otp_app:` option points the backend at this package's `priv/gettext` tree, isolating its catalogue from the parent app's. No other configuration needed.

The `@moduledoc` correctly notes that the parent application is responsible for setting the per-request locale — this module is lookup-only. Good separation of concerns.

---

### 2. `lib/phoenix_kit_ecommerce.ex` — `gettext_backend:` on every `Tab.new!`

**Verdict: Correct, mechanical, complete.**

All 10 sites updated:
- 7 in `admin_tabs/0` (`:admin_shop`, `:admin_shop_dashboard`, `:admin_shop_products`, `:admin_shop_categories`, `:admin_shop_shipping`, `:admin_shop_carts`, `:admin_shop_imports`)
- 1 in `settings_tabs/0` (`:admin_settings_shop`)
- 2 in `user_dashboard_tabs/0` (`:dashboard_shop`, `:dashboard_cart`)

The repetition (`gettext_backend: PhoenixKitEcommerce.Gettext` ten times) is a minor smell, but factoring it into a helper or module attribute would only obscure the data. A grep for `gettext_backend:` returns exactly 10 hits — easy to audit. Leave it.

`gettext_domain` is not set explicitly anywhere; `Tab.localized_label/1` is presumably defaulting to `"default"`, which matches the catalogue's `default.po` filename. The follow-up test now asserts `tab.gettext_domain == "default"` to lock this in.

---

### 3. `mix.exs` — Dependency, application, and package wiring

**Verdict: All three changes are necessary and correct.**

```elixir
def application do
  [extra_applications: [:logger, :gettext]]
end

defp deps do
  [
    # ...
    {:gettext, "~> 1.0"},
    # ...
  ]
end

defp package do
  [
    # ...
    files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
  ]
end
```

- **`:gettext` in `extra_applications`** — required so the gettext app is started before this module loads its backend. Without it, `Gettext.put_locale/2` calls before the supervision tree finishes booting could fail.
- **`{:gettext, "~> 1.0"}`** — resolves to gettext 1.0.2 in `mix.lock`. `~> 1.0` is the right floor: `Gettext.Backend` exists in 0.26+ but the 1.0 release stabilises the split-module API and removes deprecated paths. The constraint also avoids accidentally pulling 0.x in mixed dep trees.
- **`priv` in `files:`** — without this, the `.po` files would be omitted from the Hex tarball and consumers would fall back to raw msgids. This is the single most consequential change in the PR for end users; easy to miss in review.

**Note on blast radius:** including `priv` in `files:` ships *all* of `priv/`. Currently that's only `gettext/`. If migrations are ever added under `priv/repo/migrations/`, they'll be auto-shipped — desirable for an Ecto-using package, but worth being aware of.

---

### 4. `priv/gettext/default.pot` and locale catalogues

**Verdict: Catalogues are clean. Manual maintenance is the only gotcha.**

The `.pot` template is hand-written, not generated, because labels live as plain strings in `Tab.new!(label: ...)` rather than inside a `dgettext` macro call — `mix gettext.extract` would find nothing. The `.pot` header documents this and instructs maintainers to run `mix gettext.merge priv/gettext` after adding a new msgid.

This is a reasonable trade-off: the alternative (annotating each label with a `gettext_noop` or similar macro just to make the extractor see it) would add ceremony for a small msgid set. But it does mean **adding a tab is a two-step change** — Tab registration + `.pot`/`.po` update. Worth a release-checklist note.

Spot-check on translations:
- `ru`: "Электронная коммерция", "Панель управления", "Товары", "Категории", "Доставка", "Корзины", "CSV-импорт", "Магазин", "Моя корзина" — all native and idiomatic.
- `et`: "E-kaubandus", "Töölaud", "Tooted", "Kategooriad", "Tarne", "Ostukorvid", "CSV-import", "Pood", "Minu ostukorv" — checked against standard Estonian e-commerce terminology, all reasonable.
- `en`: 1:1 with msgid (correct — English is the source language).

Plural-Forms headers are present in `ru` and `et` even though the current msgid set has no plural forms. That's defensive and correct: adding a plural-using msgid later won't require a header backfill.

---

### 5. `test/test_helper.exs` — Conditional ExUnit setup

**Verdict: Right pattern for the version-skew problem.**

```elixir
if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
     function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1) do
  ExUnit.start()
else
  Logger.info("...")
  ExUnit.start(exclude: [:requires_phoenix_kit_i18n_api])
end
```

The two-step guard is necessary: `function_exported?` returns `false` for unloaded modules, so without `Code.ensure_loaded?` you'd get a false negative on cold starts. The `and` short-circuits cleanly — if `Tab` doesn't load (e.g., on an even older `phoenix_kit` that lacks the module entirely), the second clause never executes.

The `Logger.info` diagnostic is a minor style choice. `IO.puts` would be more visible during interactive `mix test` runs (Logger respects level filtering), but `Logger.info` matches the convention of using configured log infrastructure. Either is defensible.

The `@moduletag :requires_phoenix_kit_i18n_api` on `i18n_test.exs` correctly pairs with the `exclude:` option here. Once `phoenix_kit` ships #522, the conditional flips and tests run automatically.

---

### 6. `test/phoenix_kit_ecommerce/i18n_test.exs` — Smoke test

**Verdict: Right approach, originally incomplete in two ways. Both addressed in follow-up.**

The original test had three concerns worth flagging:

**Concern 1: Wiring assertion only iterated `admin_tabs/0`.**

```elixir
for tab <- PhoenixKitEcommerce.admin_tabs() do
  assert tab.gettext_backend == EcommerceGettext, ...
  assert tab.gettext_domain == "default"
end
```

This covered 7 of the 10 `gettext_backend:` sites. The single `:admin_settings_shop` tab in `settings_tabs/0` and the two `:dashboard_shop`/`:dashboard_cart` tabs in `user_dashboard_tabs/0` were unverified. If a future edit dropped `gettext_backend:` from a settings or user-dashboard tab, the test would still pass. **Follow-up extends the iteration to all three lists** and adds `length(tabs) == 10` as a sanity guard (so adding an 11th `Tab.new!` without updating the count flags the change).

**Concern 2: All translation assertions went through `Tab.localized_label/1`.**

```elixir
parent = Enum.find(PhoenixKitEcommerce.admin_tabs(), &(&1.id == :admin_shop))
assert Tab.localized_label(parent) == "Электронная коммерция"
```

If `Tab.localized_label/1` ever regressed in a way that fell back to `tab.label` silently (e.g., a `try/rescue` swallowing a backend lookup error), the catalogue could ship broken and the test wouldn't notice — both the actual and expected would resolve to the raw msgid for any locale where translation is missing. **Follow-up adds two assertions that hit the backend directly** (`Gettext.gettext(EcommerceGettext, "E-Commerce") == "Электронная коммерция"`), so catalogue regressions surface even if `Tab.localized_label/1` is broken.

**Concern 3: `alias PhoenixKitEcommerce` is a no-op.**

The calling module is already in scope under its own name. Aliasing it adds nothing and reads as if the test file is testing a module other than itself. **Follow-up removes the redundant alias** and extracts the repeated `Enum.find(...)` lookup into a small `admin_shop_tab/0` helper.

**What stayed the same:**
- `async: false` is correct — the test mutates process-local locale state on a backend that other tests in the same suite could share.
- The `setup`/`on_exit` locale-restore is idiomatic and prevents cross-test bleed.
- The unknown-locale fallback test (`"zz"`) confirms Gettext returns the msgid rather than raising. Good defensive guard.

---

### 7. `CHANGELOG.md` — 0.1.4 entry

**Verdict: Clear, includes the cross-repo dependency note.**

```markdown
## 0.1.4 - 2026-05-08

### Added
- Per-module Gettext backend (`PhoenixKitEcommerce.Gettext`) with `en`/`ru`/`et`
  catalogues for all admin sidebar tab labels. Requires `phoenix_kit` release
  that ships the `gettext_backend` Tab API ([BeamLabEU/phoenix_kit#522]); on
  older releases tabs render raw English (graceful degradation).
```

The graceful-degradation note is the right thing to surface in the CHANGELOG so consumers know what they get on older `phoenix_kit` versions.

---

## Issues Summary

| Severity | Location | Issue | Status |
|---|---|---|---|
| Low | `i18n_test.exs` | Wiring test only iterated `admin_tabs/0`; 3 of 10 sites unverified. | Fixed in follow-up |
| Low | `i18n_test.exs` | All translation assertions routed through `Tab.localized_label/1`; catalogue regression could be masked. | Fixed in follow-up (added direct backend assertion) |
| Trivial | `i18n_test.exs` | `alias PhoenixKitEcommerce` was a no-op. | Fixed in follow-up |
| Info | Workflow | Adding a tab requires a manual `.pot`/`.po` update because labels aren't extractable. Worth a release-checklist note. | Documented |
| Info | `shop_web.ex` | Body strings still use `PhoenixKitWeb.Gettext`. | Out of scope (per PR description) |

---

## Out-of-Scope Note Confirmed

The PR description correctly identifies that `lib/phoenix_kit_ecommerce/web/shop_web.ex` lines 12 and 59 inject `PhoenixKitWeb.Gettext` (the parent app's backend) into LiveViews and controllers via `__using__`. This means `gettext("Edit")`, `gettext("Delete")`, `gettext("My Orders")`, and the ~25 other body-string `gettext()` calls scattered across `web/` resolve against the parent's catalogue, not this module's.

Migrating that surface area would require:
1. Switching the `__using__` injection to `PhoenixKitEcommerce.Gettext`.
2. Auditing every HEEX template and LiveView for `gettext()` calls.
3. Extracting and translating those msgids into `priv/gettext/<locale>/LC_MESSAGES/default.po` (probably hundreds of msgids).
4. Verifying no consumer relies on translations being looked up against the parent's catalogue.

That's a separate, larger PR. Deferring is the right call.

---

## Overall Assessment

A well-scoped infrastructure PR. The wiring is correct, the catalogues are complete, the Hex packaging change is the load-bearing detail that's easy to miss in review, and the test-helper guard handles the cross-repo version skew with `phoenix_kit` cleanly. The original test coverage had two narrow gaps (wiring iteration, indirect-only assertions) that a follow-up addresses without changing any production code.

**Action items for follow-up:**
1. Once `phoenix_kit` ships PR #522 in a Hex release, bump the dep constraint and remove the `Code.ensure_loaded?` guard in `test_helper.exs` — the conditional becomes dead code at that point.
2. Plan a separate PR to migrate `shop_web.ex` body strings off `PhoenixKitWeb.Gettext`.
3. Add a one-liner to the release checklist: "after adding a Tab, update `priv/gettext/default.pot` and run `mix gettext.merge priv/gettext`".
