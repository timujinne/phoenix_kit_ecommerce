# PR #93 — second review and follow-up fixes

Reviewed 2026-10-17 against `90b0cd1`, including Claude's review and its fixes.
Scope: admin tool authorization and planning, public search, pinned image
downloads, cart retention, currency/category invalidation, settings auditing,
output schemas and migration conformance. No release or version change.

## BUG - HIGH — catalogue writes bypassed the editor's catalogue permission

Core enforces each tool's single declared permission, `shop.manage_catalog`.
The registered write handlers previously delegated straight to their planners,
so a key owner without `catalogue` could change catalogue records despite being
unable to edit those records in the admin UI.

**Fixed:** all four registered write handlers check `Gate.authorize_catalogue/1`
before invoking the handler, including for a dry run. The check resolves the
key's active owner and current roles with `Scope.for_user(narrow: false)`, like
core's key authorization, and checks `Scope.can?/2`. Missing actors, malformed
identities, revoked permission, disabled catalogue and lookup failures deny
access. Core continues to enforce the shop permission and key scope. The
scope-less public context functions are unchanged.

Tests exercise all four tools through core's real executor, with and without
`dry_run`, and revoke catalogue access after a confirmation is issued. The
executor fixtures now explicitly remove registration's automatic roles and
confirm the user: the first fixture previously became Owner, which made a
permission-revocation test falsely succeed, while a second user was refused by
authentication before permission checks. The test request helper now respects
an authentication plug's halt.

## BUG - MEDIUM — a trickling origin could renew the download timeout forever

Disabling Req retries fixed `Retry-After` stalls, but `PinnedAdapter.await/4`
still passed the full receive timeout to each successive `Mint.HTTP.recv/3`.
An origin sending occasional bytes could occupy an importer or API caller far
beyond the configured timeout without exceeding the body limit.

**Fixed:** one monotonic deadline covers the response headers and body; each
receive gets only the remaining time. Expiry follows the existing timeout
error path and closes the connection. `:infinity` remains supported, and the
separate connection timeout is unchanged. A real loopback origin test sends
bytes every 50 ms and verifies that a 300 ms response budget still expires.

## IMPROVEMENT - MEDIUM — non-finite stored prices aborted search rebuilding

`Document` accepted every Decimal, then compared prices and calculated a
discount. A stored `NaN` could raise; infinity could also enter derived numeric
fields. One such product prevented the entire chunk/rebuild from completing.
The ordinary write validators reject these values, but the derived index must
also tolerate old or externally written data.

**Fixed:** use the existing finite-number reader before indexing either price.
An unusable amount becomes `nil`, with no sale flag or discount. Tests cover
`NaN`, `Infinity` and `-Infinity` in both fields.

## BUG - MEDIUM (test setup) — the catalogue path bridge failed to override dependencies

The documented test-only bridge declared catalogue and entities paths without
`override: true`. Resolving it against a catalogue that declares its own
entities path failed with "Dependencies have diverged". Supplying only the
catalogue variable silently leaves the bridge off, so a superficially green
run can still exclude the entire admin API family.

**Fixed:** both explicit test-only paths override transitive declarations.
Validation uses both variables and checks the excluded families. Temporary
lock changes needed for the local core are removed before committing; the
published dependency requirements are unchanged.

## Rechecked and retained

- Claude's category-deletion rebuild, billing currency subscription, disabled
  image retries, warehouse prefix, optional list fields, merged-cart pruning,
  missing-currency refusal, locked availability planning, partial-settings
  auditing and migration digests remain in place.
- Added a committed-connection race test: an availability call plans to publish
  a priced draft while an editor holds its row and removes its price. After
  the editor commits, the call refuses the row and leaves it a draft.
- Keep the established per-field price confirmation threshold; README now
  explicitly says base and option changes are not combined into a selection
  total. Keep the tested 99-per-line claim merge cap.
- Language enablement still needs a rebuild, as documented; facet output can
  still contain many buckets despite the 5,000-product sampling bound.
- Core rechecks a confirmation fingerprint before invoking a handler, and the
  handler checks its plan again under the item lock. The small interval between
  core's preview and the handler's initial read remains; binding those reads
  would require extending core's handler context.

## Validation

- Default locked Hex build: `PGPOOL=8 mix test --max-cases 6` — **3,832 tests,
  0 failures, 609 excluded** for unavailable optional capabilities.
- API-enabled build: local core `001f82f88`, catalogue from
  `/workspace/decor3dprint/forks/phoenix_kit_catalogue-wt-api-tools`, entities
  from `../phoenix_kit_entities`, with both bridge variables set and a separate
  build directory. API, search, services, workers, checkout controller, API
  settings, warehouse source and migration suites — **1,398 tests, 0 failures,
  4 excluded** (opposite capability families).
- `mix format` and `git diff --check` pass. The original `mix.lock` is restored;
  no dependency upgrades are part of the change.
- `MIX_OS_DEPS_COMPILE_PARTITION_COUNT=1 mix precommit` — **passed**, including
  compilation with warnings as errors, unused-lock checks, Hex audit, format,
  strict Credo and Dialyzer. One file/type-specific Dialyzer suppression covers
  core's known opaque MapSet mismatch between `Scope.for_user/2` and `Scope.can?/2`,
  matching the suppression core uses for its own scope callers.
