# PR #4 Review — Add per-module Gettext backend for sidebar tab labels

**Reviewer:** Pincer 🦀
**Date:** 2026-05-09
**Verdict:** Approve

---

## Summary

Wires the e-commerce module to its own Gettext catalogue (`PhoenixKitEcommerce.Gettext`) so sidebar tab labels resolve per-locale. Ten `Tab.new!` registrations carry `gettext_backend: PhoenixKitEcommerce.Gettext`. Catalogues for `en`/`ru`/`et` ship under `priv/gettext/<locale>/LC_MESSAGES/default.po`; `mix.exs` adds `priv` to `package files:` so they reach Hex. Smoke test guards against regression and is auto-excluded when running against a `phoenix_kit` release that pre-dates the `gettext_backend` API (PR #522).

---

## What Works Well

1. **Graceful degradation** — `Code.ensure_loaded?` + `function_exported?` in `test_helper.exs` means the test suite doesn't break for consumers on the published `phoenix_kit` 1.7.105.
2. **Ships catalogues to Hex** — `~w(lib priv ...)` was the right one-line fix; without it the `.po` files would be left out of the tarball and locale lookup would silently fall back to msgid in production.
3. **Idempotent msgid set** — 9 unique msgids for 10 tab sites (`E-Commerce` is reused for `:admin_shop` and `:admin_settings_shop`). No duplication in the catalogue.
4. **Proper backend module** — `use Gettext.Backend, otp_app: :phoenix_kit_ecommerce` matches the Gettext 1.0 split-module convention.

---

## Issues and Observations

### 1. OBSERVATION: Wiring test only iterated `admin_tabs/0`
3 of 10 sites (1 settings, 2 user-dashboard) had no automated check that they actually carried the backend. Fixed in follow-up by iterating all three lists.

### 2. OBSERVATION: All translation assertions went through `Tab.localized_label/1`
A regression in the helper that masked the lookup would let the catalogue ship broken. Follow-up adds a direct `Gettext.gettext(EcommerceGettext, ...)` assertion that doesn't depend on the helper.

### 3. OBSERVATION: `alias PhoenixKitEcommerce` was a no-op
The calling module is already in scope; the alias was dead. Removed.

### 4. OBSERVATION: Manual `.pot` maintenance burden
Labels live as plain strings in `Tab.new!(label: ...)`, so `mix gettext.extract` won't pick them up. PR documents this in the `.pot` header, but it does mean adding a tab requires a manual `.pot`/`.po` update. Not blocking; worth a release-checklist note.

### 5. OBSERVATION: Body strings still use `PhoenixKitWeb.Gettext`
`shop_web.ex` injects the parent app's backend into LiveViews and Controllers. PR description correctly flags this as a separate, larger PR.

---

## Post-Review Status

No blockers. Ready for release. Follow-up commit on `main` extends test coverage and tightens the test module — covered before the next Hex publish.
