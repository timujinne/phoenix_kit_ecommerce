# PR #106 — follow-up

The inaccessible Billing notification link is fixed. The shop recipient set is
unchanged; each recipient gets the Billing order link when Billing is enabled and
their permissions allow it, otherwise the carts link. Owner and wildcard grants
are included, and recipients are not duplicated across the two batches.

Validation:

- Broader shipping/notification regression run: **635 tests, 0 failures**.
- Full suite: **4,664 tests, 101 excluded**, with one picker-test dispatch error
  corrected during the run; the complete picker-file rerun passed **66 tests,
  0 failures**. All notification and catalogue API tests passed in the full run.
- `mix test --failed` after that correction: **1 test, 0 failures**; no unresolved
  test failures remain.
- `mix precommit`: passed, including compilation with warnings as errors,
  dependency-lock checks, Hex audit, formatting, strict Credo, and Dialyzer.
