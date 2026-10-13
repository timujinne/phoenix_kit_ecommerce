# PR #83: Independent review of Claude's release preparation

- Reviewer: Codex, 2026-10-12
- Reviewed PR: `37d11ec`; dependency refresh: `3eb1583`; Claude's fixes: `634899d`
- Verdict: hold the release for the three bugs below. The gate passes, but
  the claim that no money-path bug remains is not supported.
- Scope: audit of the fixes and release readiness. No source changes,
  version bump, publication, or tag in this review.

## BUG - HIGH: the credential leak is only partly fixed

Locations: `lib/phoenix_kit_ecommerce/shipping.ex:537` and `:676`.

`bad_return/1` inspects arbitrary provider output without redacting it.
`run_safely/2` sanitizes exceptions, but returns normal error results
unchanged. A provider accidentally returning `{:ok, ctx.credentials}`
therefore exposes the credential values in the facade result, the warning
log, and the 30-second negative cache. This is the same failure boundary
the hardening commit intends to protect, and its new list validation also
routes malformed list contents through this inspection.

Even the exception path is incomplete: `crash_text/2` replaces literal
credential values, whereas `KeyError` and `MatchError` inspect their terms.
Credentials containing a quote, newline, or backslash are escaped before
replacement. A synthetic credential containing a quote survived a
`Map.fetch!(ctx.credentials, "missing")` failure without any `[redacted]`
marker. Strings shorter than four bytes are also explicitly skipped.

Reproduction: used the existing `StubProvider`, explicit synthetic
credentials, and `ExUnit.CaptureLog`; asserted the malformed-return key
was present in the result, captured log, and ETS cache. Separately asserted
that the escaped credential survived the exception path. Both observations
passed. No real credentials were used.

Required before release: protect all facade-generated diagnostics before
logging, caching, or returning them. Prefer diagnostics that omit arbitrary
provider terms; retaining formatted exception text requires handling its
escaped representation too. Add regression assertions for both paths,
including the cache and log. Correct the categorical credential claim in
the changelog after the fix.

## BUG - HIGH: checkout accepts a different carrier's quote

Locations: `lib/phoenix_kit_ecommerce/shipping.ex:793`;
`lib/phoenix_kit_ecommerce.ex:4157`, `:4270`, and `:4285`.

The stored quote's request hash covers service, settings, destination,
parcels, values, currency, and country, but no provider identity. An admin
can change a calculated method's provider while keeping the same service
key and settings. Reloading the cart still reports `:ok`, totals use the
old provider's quote, and order conversion succeeds. The order records
the new provider alongside the old provider's quote.

Reproduction: the existing cart fixtures quoted `StubProvider` at 100.
Updated the same method through `Shop.update_shipping_method/2` to the
existing `StrictProvider`, retaining service `branch` and settings. That
provider quotes 20. Reloaded the cart, asserted status `:ok`, and converted
it successfully. The order recorded provider `strict` and quote amount
100. With the fixture's 10% markup, the old quote charges 110 instead of
the new provider's 22. A swap in the other direction can undercharge.

This is a money and fulfillment correctness bug, not a nitpick. The
provider-aware facade cache key does not protect the separately persisted
cart quote. The same comparison also allows an old provider's in-flight
answer to be persisted after the method changes.

Required before release: bind persisted quote freshness and the post-call
staleness check to provider identity, and treat existing entries without
that identity as stale. Preserve the documented public request-hash
contract if introducing a separate cart quote identity. Test both an
already stored quote and a provider change during an in-flight call.

## BUG - MEDIUM: the JPY fix double-rounds marked-up shipping

Locations: `lib/phoenix_kit_ecommerce/shipping/pricing.ex:69` and
`lib/phoenix_kit_ecommerce.ex:4472`.

`Pricing.final_amount/4` still rounds an unstepped result to two decimals.
Claude's change then rounds that result again to the base currency's
decimal places. With JPY, a quote of 100 and a 0.495% markup becomes
100.495, then 100.50, then 101. Rounding the actual marked-up amount
directly to yen gives 100. The fix removes fractional yen but can charge
an extra yen.

Reproduction: created a JPY base currency with `decimal_places: 0` through
billing's API inside the existing sandbox fixture, configured the markup
above and disabled the rounding step, quoted 100, and observed cart
shipping of 101. This is testable in the existing harness; needing a base
currency row is not a reason to omit the regression test.

A supplementary three-decimal base-currency reproduction produced 1.01
from a KWD quote of 1.005 with no markup. However, core's baseline cart
shipping column is itself `numeric(12,2)` (`v135.ex:1200`), so full
three-decimal support has a pre-existing storage limitation as well. That
broader limitation should not be presented as solely introduced by this
commit or as solved by changing this conversion helper.

Required before release: settle the marked-up amount once at the intended
currency precision, retaining explicit step rounding when configured.
Add the JPY regression test and retain ordinary two-decimal coverage.

## IMPROVEMENT - MEDIUM: the release notes omit the feature being released

Location: `CHANGELOG.md:7`.

`Unreleased` contains only the review fixes. It has no `Added` entry for
PR #83's provider contract, calculated rates, destination picker, parcel
configuration, or admin controls. A version bump alone would release this
large feature under a list of minor fixes. Add the feature summary and
provider registration/configuration requirements when preparing the release
entry. Leaving the version at 0.5.20 was appropriate for a review-only
request.

## Assessment of the other deferred items

The transient-error fallback is explicitly documented in `Provider` and
`CartQuote`, including provider-specific errors. Adapters must map business
refusals to the enumerated reasons. Changing that policy deserves a separate
decision; it is not evidence of a regression in Claude's fixes.

The provider contract explicitly requires `services/1` and
`validate_destination/3` to be pure. Calls under the cart lock are still
bounded worker waits, and misbehaving adapters can hold a connection, but
the review's description of carrier network lookups needs that qualification.
A redesign is reasonable follow-up work; it does not justify leaving the
unrelated wrong-provider quote bug.

The per-provider quote budget and uncached short-timeout service failures
remain documented operational limitations. The new per-picker throttle
helps one component and does not establish a global quote budget.

## Validation

- `mix precommit`: passed independently on `634899d`, including warnings
  as errors, formatting, strict Credo, and Dialyzer.
- `mix test --max-cases 6`: **2716 tests, 0 failures**, seed 984128,
  118.1 seconds; integration tests ran.
- Five focused observation tests outside the repository passed and confirmed the two
  credential paths, successful checkout with the wrong carrier's rate,
  JPY double rounding, and the three-decimal limitation. These assertions
  intentionally demonstrate the current defects; passing them does not
  mean the defects are fixed.
- Reproduction scripts: `/tmp/ecommerce_codex_secret_audit_test.exs` and
  `/tmp/ecommerce_codex_cart_audit_test.exs`, run with `mix test` and
  `--only codex_audit --max-cases 1`. Final output:
  `/tmp/ecommerce-codex-audit-final.log`.
- Gate log: `/tmp/ecommerce-codex-precommit.log`; suite log:
  `/tmp/ecommerce-codex-tests.log`. Temporary logs/scripts are local
  evidence and are not part of the package.

I did not rerun the untouched baseline at full concurrency, so Claude's
attribution of those failures specifically to shared Postgres remains his
reported diagnosis. The clean limited-concurrency suite is independently
confirmed. Neither it nor the clean static gate covers the reproduced bugs.
