# PR #107 — shipping service selection

Reviewed 2026-10-22 against `e5c0fee`, including the earlier review fix for a
second service-list request after an outage.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/107

## BUG - HIGH — an implicit default loses the service its destination belongs to

Selecting a destination without clicking a service radio left `shipping_service`
absent. If the admin then removed the default branch service, the effective
service changed to a locker but the old branch point remained usable. The request
was merely stale rather than `needs_destination`; another quote could price and
order the new service with the previous service's point. Changing only the default
also silently switched a destination to another still-allowed service.

Fixed by recording the service in effect whenever a nonempty calculated-shipping
destination is saved, under the existing cart lock. An explicitly chosen service
is preserved; a removed choice is replaced with the current effective service.
The existing stale-choice handling can then reject an old destination and retain
only its locality. No carrier lookup or new metadata field is introduced.

Regression tests reproduce removal of an implicit default, a default-only change,
and checkout refusal until a new destination is supplied. A LiveView test starts
with a default-service destination, removes that service, verifies that the picker
asks again, and selects a new locker point successfully.

Existing destinations saved before this fix without a service cannot reveal which
historical default they belonged to. They require a one-time destination
confirmation instead of silently adopting the current default. An additional test
models an unstamped legacy destination and verifies that confirming it restores
normal quoting. Historical records are not rewritten.

## BUG - MEDIUM — method switching ignores a different default

`same_shipping_services?/2` compared only provider and allowed services. The
configuration reader explicitly supports a stored default that differs from the
first allowed service. Two methods with identical lists but different defaults
therefore retained a legacy cart's destination even though its effective service
changed. The previous single-service comparison did include the default.

Fixed by including `config.service` in the comparison. A regression test models
a legacy destination without a recorded choice and verifies that switching to
another default clears it and requires a new destination.

## Other checks

Traced service selection through provider contexts, city/point lookups, rate
requests, quote hashes, totals, checkout blocking, and order snapshots. Checked
legacy single-service configuration, stale-choice recovery, service availability,
country-specific choices, the earlier outage fix, and malformed public events.
The documented bounded provider service lookup under the cart lock is unchanged.

## Validation fixes

- The malformed picker-event test used form encoding, which converts numeric
  `42` to the valid search string `"42"`. Its next input cancelled a real lookup
  during a database read, intermittently destroying the shared SQL sandbox
  connection. Send JSON events to the component instead and assert that no
  locality search starts. This retains malformed numeric/map/nil payload types.
- The admin-origin test unconditionally unregistered `PhoenixKitCatalogue`, even
  when it was already discovered before that test. Later API tests could no
  longer grant the `catalogue` permission. Its cleanup now preserves the prior
  registration state.
- The test helper computed `replay_exclude` but never passed it to ExUnit. It now
  applies that existing compatibility exclusion and removes the unused variable
  warning. No supported test family is disabled.

## Validation

See `FOLLOW_UP.md` for the final gate and suite results.

## Recheck — 2026-10-24

Rechecked against `88a98ad`. Destination saves still remember the effective
service, stale selections still require a new destination, and method switching
compares the default as well as the provider and allowed services. Checked
request hashes, provider lookup contexts, order snapshots, and the earlier
outage fix that avoids a second failed service listing. No new finding.
The current full suite and gate results are in
[the merged-PR recheck](../2026-10-24-merged-prs-recheck/CODEX_REVIEW.md).
