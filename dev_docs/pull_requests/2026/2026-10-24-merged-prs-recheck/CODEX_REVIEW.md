# Recent merged PRs — independent recheck

Reviewed 2026-10-24 against `88a98ad` on `main`.

Scope: merged PRs #94, #95, #96, #98, #99, #104, #105, #106, #107, and
#108, plus the review follow-ups `8e6e74f`, `e5c0fee`, and `7073897`.
GitHub's merged PR list confirms there are no merged #97 or #100–#103 in
this interval. Claude's latest `88a98ad` commit changes review documents only.

## Result

No new functional defect found in this recheck; no production code changes.
Individual review records describe the checks for each PR. Rechecked the
existing #106 recipient-specific Billing links and #107 service/destination
identity fixes against the current source and regression coverage.

The merged #108 implementation goes beyond the earlier Codex draft review:
it now catches ordinary exits and throws as well as exceptions. Product-image
priority, empty-image handling, Legacy and catalogue line identity, both
rendering call sites, callback argument order, and fallback-to-icon behavior
match the documented contract.

The existing log-volume nit remains acceptable for this small extension point.
Precisely, warnings are emitted for callback exceptions, throws, and exits;
malformed configuration and non-string/empty return values silently use the
icon. A synchronous callback can still block rendering or terminate its process
with an external exit signal: the documented quick, pure URL-builder contract
matters. Ordinary `exit/1` recovery is not process isolation.

## NITPICK — Claude's review commit includes prohibited attribution

`88a98ad` contains a `Co-Authored-By: Claude Opus 5.5` trailer, contrary to
the repository's explicit no-attribution rule in `AGENTS.md`. This affects
commit hygiene only. Existing pushed history is left intact; this recheck's
commit follows the repository convention.

## Validation

- Locked Hex dependencies: `PGPOOL=12 mix test --max-cases 8`, seed
  `515150`: **4,692 tests, 0 failures, 84 excluded**. This includes the
  catalogue, public API, shipping, notification, and merged item-image tests.
  Exclusions select incompatible core/catalogue variants, unavailable Billing
  order-sync APIs, and the absent analytics dependency.
- `mix format` left source files unchanged.
- `mix precommit`: **passed**, including compilation with warnings as errors,
  lock checks, Hex audit, formatting, strict Credo, and Dialyzer. Dialyzer
  reports 10 unnecessary optional-dependency suppressions, as Claude recorded;
  all reported errors are covered by existing specific suppressions.
- Local Billing at `74fec6a`, using `PHOENIX_KIT_BILLING_PATH`: **89 tests,
  0 failures, no exclusions**, seed `628651`. Ran `order_export_test.exs`,
  `order_tools_test.exs`, `order_tools_executor_test.exs`,
  `item_image_test.exs`, and `web/item_image_pages_test.exs`. This exercises
  the order-sync family excluded by the locked Billing build and reruns both
  #108 test files. Dependency resolution temporarily selected
  `rustler_precompiled` 0.10.1; the original lock and default dependencies
  are restored after this compatibility run. No dependency changes belong
  to this review.
