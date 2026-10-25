# PR #107 — follow-up

Resolved findings:

- Saving a nonempty calculated-shipping destination records its effective
  service, including the implicit default.
- A removed service's old destination is rejected; another allowed default does
  not reinterpret the old point. A legacy destination with no recorded service
  requires confirmation once.
- Switching methods compares provider, default, and allowed services before
  carrying the destination and choice forward.
- Malformed picker payload tests preserve JSON types and verify that no lookup
  starts. Catalogue test cleanup preserves pre-existing module registration.
- The test helper now applies its existing replay-capability exclusion.

Validation:

- `mix test test/phoenix_kit_ecommerce/notifications_test.exs
  test/phoenix_kit_ecommerce/shipping/service_choice_test.exs
  test/phoenix_kit_ecommerce/web/shipping_picker_test.exs
  test/phoenix_kit_ecommerce/shipping`: **635 tests, 0 failures**.
- Full suite (`PGPOOL=12 mix test --max-cases 8 --seed 748984`): **4,664 tests,
  1 failure, 101 excluded**. The sole failure was the JSON test dispatch call
  requiring an explicit component target; it was corrected during the run.
  No production-code or catalogue-registration failures remained.
- Complete final picker-file rerun with the same seed: **66 tests, 0 failures**.
  This includes the corrected malformed-input test and the new destination
  regressions. The full suite's exclusions select the test families appropriate
  to this dependency build, including optional APIs and compatibility variants.
- Final `mix test --failed`: **1 test, 0 failures**; no unresolved test failures
  remain.
- `mix precommit`: passed, including compilation with warnings as errors,
  dependency-lock checks, Hex audit, formatting, strict Credo, and Dialyzer.
- No version bump, dependency change, or release.
