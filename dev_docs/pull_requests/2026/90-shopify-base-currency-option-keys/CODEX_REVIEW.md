# PR #90 — Cart option identity and Shopify sync

**Author:** Max Don · **Commit:** `9b5dbf0` · **Reviewed:** 2026-10-16

Reviewed the merged PR and subsequent dependency/docs changes through
`477ba58`. Scope includes option keys and label snapshots, whole-set values,
Shopify currency gating and job serialization, versioned migrations, and
compatibility deprecations. Draft PR #93 is excluded.

## Findings and fixes

### BUG - MEDIUM — an old label could impersonate a current option key

`SelectedSpecs.keys/2` returned an unrecognized stored label unchanged.
If that label happened to equal a current value key, the product page
treated the old line as the current selection. For example, an older line
storing label `crimson` at 24.00 matched key `crimson`, whose current label
is `Red` and price is 29.00. The page displayed the old price and an
incorrect “Already in cart” notice.

**Fixed:** an unknown label within an option's label-to-key map resolves
to `nil`. Options without that map retain their stored identity, including
catalogue schema options and legacy products. Stored lines are untouched.

### BUG - MEDIUM — product notices could use the wrong cart line's price

The lookup after adding compared raw selections without distinguishing
old labels from new keys. An old `crimson` label and a new `crimson` key
can coexist, so the success flash could show the old line's 24.00 price
after adding the new line at 29.00. Before adding, the first resolved
label match also took priority over an existing keyed line.

**Fixed:** exact matching includes the selection format and the full
selection, including an empty selection. The product page first chooses
the current keyed line, then falls back to resolving an old label line
for the existing-cart notice. The success flash uses only an exact match.

Regression coverage exercises both product-page cases and separately
checks old-label resolution, catalogue schema options, legacy options,
and a keyed line whose live option has disappeared. Removed an unused
default argument in the existing test helper.

### BUG - HIGH — the dependency lock failed the security gate

`mix precommit` reported two advisories against locked Bandit 1.12.5:
`EEF-CVE-2026-105659` (HIGH, HTTP/2 blocked-send deadlines) and
`EEF-CVE-2026-105660` (MEDIUM, HTTP/1 request-target authority validation).
These were reported by the project's `mix hex.audit` check during review.

**Fixed:** refreshed Bandit to 1.13.1 and its Thousand Island dependency
to 1.6.0. No other lock entries or dependency requirements changed.

### IMPROVEMENT - MEDIUM — a pagination test imposed an unreliable runtime ceiling

The full suite observed 1900 ms in a test that required a default 500 ms
pagination sleep to finish within 900 ms. Scheduling delays can increase
elapsed time even when the configured sleep is correct.

**Fixed:** kept the minimum-delay assertion and removed that test's
unrelated maximum-runtime assertion. The separate custom-delay test
continues to check that an explicit delay overrides the default.

## Other checks

- Whole-set attachments offer published values; a set with no published
  values deliberately leaves the product available at its base price,
  as the existing integration test specifies.
- Shopify missing-base-currency refusals are handled by the context,
  variants worker, and admin page. Mixed updates preserve refused price
  changes for later action.
- The job execution guard orders runs by attempt time and job ID;
  the enqueue uniqueness applies across kinds.
- Versioned `up/1` validates its target and avoids lowering a newer marker.
- Documentation builds with the new ExDoc filters. Existing warnings
  reference private/hidden functions outside the filtered namespaces;
  these are not changed here.

## Validation

- `mix test`: **3,109 tests, 0 failures**, with PostgreSQL and the optional
  catalogue dependency available.
- Final focused selection/cart run after the matching cleanup:
  **27 tests, 0 failures**.
- `mix precommit`: compilation with warnings as errors, unused-lock check,
  Hex security audit, formatting check, strict Credo, and Dialyzer pass.
- `mix docs`: builds successfully, with the existing reference warnings
  described above.
