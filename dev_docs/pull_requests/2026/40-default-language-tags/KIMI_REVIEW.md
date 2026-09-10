# Code Review: PR #40 — Show product tags only on the default-language storefront

**Reviewed:** 2026-09-08
**Reviewer:** Kimi Code
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/40
**Head SHA:** 96921b4 (squash-merged)
**Status:** Merged

## Summary

The PR gates the tag badges on the public product page behind
`Helpers.tags_visible?/1`, which normalizes both the page language and the
configured default language through
`SlugResolver.normalize_language_public/1` before comparing. The gate is
wired into both mount paths of `CatalogProduct` (`mount_product/5` and the
cross-language `mount_with_product/5`), is derived from the URL locale
rather than any session/user state, so it behaves identically for guests and
logged-in users, and no other consumer of `helpers.ex` is affected. Two real
problems: the comparison still mismatches when the configured default is a
*non-canonical* dialect (e.g. `en-GB`), because page languages are resolved
to the canonical dialect of their base (`en-US`) while the configured
default is taken verbatim; and the test, despite the commit message
describing a base-code setting vs dialect page, configures the default *as a
dialect* — so the suite passes even against the naive `==` implementation
the PR claims to fix.

## Issues Found

### 1. [BUG - MEDIUM] Tags vanish on the default-language page when the default is a non-canonical dialect
**File:** `lib/phoenix_kit_ecommerce/web/helpers.ex:192-197`
**Confidence:** 75/100

The two sides of the comparison are normalized asymmetrically in practice.
The page language comes from `get_language_from_params_or_default/1` →
`DialectMapper.resolve_dialect/1`, which maps the URL's base code to the
*canonical* dialect via `@default_dialects` (`"en"` → `"en-US"`). The
configured default from `Translations.default_language/0` is the code stored
in core's Languages config, verbatim. `normalize_language/1` leaves any
hyphenated code untouched, so a shop whose default language is configured as
`"en-GB"` (a legitimate choice — core's predefined list includes it) gets
`resolve_dialect("en")` = `"en-US"` on the page side versus `"en-GB"` on the
setting side → no match → tags hidden on the shop's *own default-language
storefront*, the exact page where the PR wants them shown. The inline
comment "compare them the way slugs are compared" is also inaccurate:
`SlugResolver` compares against *three* spellings (`language_keys/1`: exact,
canonical dialect, base), which is precisely the robustness this comparison
lacks.

**Fix:** compare bases instead of dialects —
```elixir
DialectMapper.extract_base(language) == DialectMapper.extract_base(Translations.default_language())
```
This drops the `SlugResolver` alias, matches the slug resolver's base-code
semantics honestly, and also shows tags on a same-base secondary dialect
(`en-GB` visitor on an `en-US`-default shop) — acceptable since the tags are
in the default language anyway.

### 2. [IMPROVEMENT - HIGH] The test does not pin the bug the PR fixes
**File:** `test/phoenix_kit_ecommerce/web/catalog_product_tags_test.exs:28-44`
**Confidence:** 85/100

The commit message says the point of the normalization is "a page carries a
dialect (`en-US`) while the setting holds a base code (`en`)". But the setup
configures the default language as `"en-US"` — a dialect. With that setup,
the trivially-broken implementation
`language == Translations.default_language()` passes every assertion in the
file, including the live-view test (`lang()` normalizes the default to
`"en-US"`, and the no-prefix URL resolves `current_language` to the same
value). So the one regression this PR exists to prevent — plain equality
hiding tags everywhere — is unguarded.

**Fix:** set the configured default to the base code `"en"` in
`languages_config` and assert `tags_visible?("en-US")` is true (page dialect
vs base-code setting); optionally also assert `tags_visible?("en")`.

## What looks good

- Both mount paths assign `show_tags?` (`catalog_product.ex:127` and `:341`),
  including the cross-language-redirect path — no path serves an unassigned
  `@show_tags?`.
- The check is URL-derived (`get_language_from_params_or_default/1`), not
  session- or user-derived, so guests and logged-in users are covered
  identically, and it doesn't depend on the process Gettext locale at all —
  sidestepping the `ru-RU`-vs-`ru` catalogue class of bugs documented in
  AGENTS.md.
- `tags_visible?(nil) → false` is a safe fail-closed catch-all.
- Only the storefront template changed; no admin, SEO, or notification code
  was touched, and no new `gettext` strings were added.
- The dialect handling is right for the common configurations: base-code
  default (`"en"`) and canonical-dialect default (`"en-US"`) both match a
  page resolved to `"en-US"`; languages-disabled fallback
  (`Settings.get_content_language() || "en"`) also round-trips correctly.

## Unverified surfaces

- `PhoenixKitEcommerce.Web.SEOHelpers.product_seo/2` — if tags feed
  `<meta name="keywords">` or OG data, non-default pages still emit the
  untranslated list to crawlers (arguably fine, but should be a conscious
  decision).
- `lib/phoenix_kit_ecommerce/product_source/catalogue/view.ex` — it matches
  `tags` in the catalogue-backed storefront path (commit cbed3a4); if that
  view renders tag badges independently of `CatalogProduct`, they remain
  ungated there.
- `lib/phoenix_kit_ecommerce/web/product_detail.ex` (admin) — expected to
  still show tags (correct per the PR's intent); untouched by the diff, so
  almost certainly fine.
