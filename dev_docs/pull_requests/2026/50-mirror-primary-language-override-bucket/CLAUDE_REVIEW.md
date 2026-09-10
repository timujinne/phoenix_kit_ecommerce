# Code Review: PR #50 — fix: mirror primary-language title/body_html sync into the override bucket

**Reviewed:** 2026-09-10
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/50
**Author:** Tymofii Shapovalov (timujinne)
**Merge SHA:** 9f4081f
**Status:** Merged

## Summary

A Shopify sync applied at an item's primary language wrote the new title/
body_html to the `:name`/`:description` column but skipped the matching
`data[primary]["_name"/"_description"]` override bucket key.
`Translations.translated_name/2` / `translated_description/2` unconditionally
prefer the bucket over the column at every locale, including the primary one, so
an item that already carried a primary-language override kept showing the stale
bucket value after every sync ("apply succeeded, nothing changed"). The fix
writes through: a primary-language sync now updates both the column and the
bucket with the same value, chosen over deleting the bucket key because a
mixed writer/reader pair is deployed for a while (a paired catalogue-side reader
fix — making the column authoritative at the primary locale — is intentionally
not part of this PR).

## Verification

- Read `lib/phoenix_kit_ecommerce/catalogue/writer.ex` in full (not just the
  diff hunk) and `writer_test.exs`.
- Checked the "primary language" determination for the dialect-vs-bare-code
  hazard AGENTS.md warns about elsewhere (`put_content_locale/1`) — doesn't
  apply here: `base_locale` and `item_primary_language/1` are explicit,
  programmatically-passed locale strings, not derived from session/LiveView
  locale detection.
- Confirmed a non-primary-locale sync only ever writes the bucket at that
  locale, never touching the primary bucket (`maybe_override_field/5` vs.
  `maybe_put_primary_column/6`'s `base_locale == primary` gate).
- Confirmed write-through cannot clobber a deliberately-different admin
  override: the primary-language bucket key is documented (and behaves, via the
  ordinary catalogue edit form) as a *mirror* of the column, not an independent
  override — the edit form always writes both together, so write-through
  restores an invariant rather than breaking one.
- Confirmed idempotency: re-running with identical `change_fields` re-writes the
  same value to both column and bucket, no accumulation/double-encoding.
- Grepped `catalogue/` and `product_source/catalogue/` for the same
  bucket-vs-column write pattern elsewhere — none found. Checked
  `shopify/collection_sync.ex` (categories): `update_matched_category/3` never
  rewrites `name` on an existing category match at all, so it isn't exposed to
  this class of bug (a separate, pre-existing gap, out of scope here — Shopify
  collection renames don't propagate to existing categories).
- Confirmed the new test directly reproduces the root cause (seeds a stale
  primary-language bucket value before each test), not just a happy path — and
  also covers secondary-locale isolation, no-pre-existing-bucket, and
  sibling-data preservation.
- `mix precommit` and `mix test` clean (part of the combined #49–#53 gate run).

## Issues Found

None. No bugs survived scrutiny.

## What Was Done Well

- The write-through choice (over deleting the bucket key) is explicitly
  reasoned against the real deployment shape (a mixed writer/reader pair for a
  while), not just "seemed simpler" — and is the correct call for that reason.
- The regression test seeds the exact stale-bucket precondition the live defect
  needed, rather than testing the mechanism in isolation from the symptom.

## Gate

`mix precommit` and `mix test` both clean (see combined #49–#53 gate run). No
release was requested for this file in isolation — part of the sweep in
PR #49's review doc and this repo's release notes.
