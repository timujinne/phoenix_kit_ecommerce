# Codex Review — PR #6 (ecommerce follow-ups)

Reviewer: Codex (GPT-5), 2026-06-05. Scope: the PR #6 `.ex` diff
(`DialectMapper.resolve_dialect/2 → /1` fix at two call sites; conservative
migration of non-translatable scalar fields in category/product forms to core
`<.input>/<.select>` via an `assign_form/2` helper).

## Findings

- **MED** — `resolve_dialect/1` now requires a PhoenixKit version that exposes
  that arity. The change is correct for the current pinned core and fixes the
  old (broken) `/2` call, but `mix.exs` allows `{:phoenix_kit, "~> 1.7"}`
  broadly; a consumer pinned to an older `1.7.x` that only had
  `resolve_dialect/2` would compile-fail. Consider bumping the minimum
  PhoenixKit version to the release that introduced `resolve_dialect/1`.

- **No issue** with the dual `:changeset` + `:form = to_form(changeset)`
  assign flow. `assign_form/2` updates both assigns from the same changeset on
  initial load, validation, and save errors. `TranslationTabs` still reads
  `@changeset` while the converted core fields read `@form`, so there is no
  desync or breakage of the multilang field names/values.

---

## Round 2 (2026-06-05) — i18n body-string + form-select migration

Codex re-reviewed the added commits (gettext body-string migration with the
generic→core / domain→module hybrid split + et/ru translations; migration of
3 changeset-backed form selects to core `<.select>` via `assign_form/2`).

**Verdict: no issues found.** Codex verified the routed generic labels are
present in core's catalogue while the bare module `gettext` strings are present
in the ecommerce catalogue (no string silently regressed to English, no
misrouted domain string), and that the dual `@changeset`/`@form` flow preserves
selected values for `parent_uuid` / `featured_product_uuid` / `category_uuid`
while TranslationTabs still reads `@changeset`.
