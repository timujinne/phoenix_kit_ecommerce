# PR #67: Link the Settings tab at the connected integration's own page

- **Author:** Tymofii Shapovalov
- **Reviewer:** Claude
- **Merged as:** `0c63406`
- **Verdict:** correct as merged for its own case. Two findings addressed
  post-merge (one pre-existing, exposed by the PR's own rationale), one
  recorded and deliberately not changed.

## Summary

The Settings tab of `/admin/shop/shopify-sync` gains a
`#shopify-credentials-panel` with a link to
`/admin/settings/integrations/<connection uuid>`, gated on `@connection`.
Tests pin the uuid in the href, the tab placement, the not-connected case,
and — in the legacy-source module — that the panel does not inherit the
neighbouring panel's `@catalogue_source_active?` gate.

## Checks

- **The route exists and takes this uuid.** Core registers
  `live "/admin/settings/integrations/:uuid", IntegrationForm, :edit`;
  `apply_action(:edit)` loads it through
  `Integrations.get_integration_by_uuid(uuid, :system)`. `@connection` comes
  from `Integrations.list_connections("shopify", owner: :system)`, so the
  uuid is always a system connection's and the owner-scoped load accepts it.
- **No query added to mount.** The link reads the `@connection` the page
  already loads.
- **Gettext.** Three new msgids, merged `--no-fuzzy`, translated in
  de/fr/et/ru. Verified no fuzzy flags were introduced.

## Findings

### BUG - MEDIUM — the "not connected" link was never the Integrations list (pre-existing, fixed)

The PR's rationale says the not-connected warning "goes to the Integrations
LIST". It went to `/admin/settings/integrations/website`, which matches the
`:uuid` route with `uuid = "website"`: `get_integration_by_uuid/2` finds no
row, and the form flashes **"Integration not found"** and redirects to the
list. Every first-time operator following the "Connect it in Integrations
settings" prompt landed on an error. Present since #23 (`97b74e0`).

**Fix:** link `/admin/settings/integrations` directly. Test:
`the connect prompt links the Integrations list for an integrations_system holder`
asserts the href and refutes the `/website` form.

### IMPROVEMENT - MEDIUM — both links shown to viewers core refuses (fixed)

The sync page is reachable with base `"shop"` and mutates under
`shop.run_imports`; core gates `Live.Settings.Integrations` and
`Live.Settings.IntegrationForm` on `integrations_system`
(`PhoenixKitWeb.Users.Auth`), which no `shop.*` key implies. A custom role
holding only shop keys got a prominent "Open integration settings" button
that bounces off an access-denied redirect.

**Fix:** mount assigns `:can_manage_integrations?` from
`Scope.has_module_access?(scope, "integrations_system")` — the same check
core's own admin tab uses (`Dashboard.AdminTabs`), so Owner and `"*"`
superadmins pass. The credentials panel is gated on
`@connection && @can_manage_integrations?`; the not-connected prompt keeps
its text and drops only the link. Hiding the whole panel rather than
rendering an "ask an administrator" variant adds no msgids. Tests: the
positive tests now use a scope with `integrations_system`, and
`?tab=settings offers no integration link without integrations_system` plus
`the connect prompt carries no link without integrations_system` pin the
negative.

### NITPICK — `shopify_connection/0` picks the first of several (not changed)

With two system Shopify connections the page (and so the link) uses
whichever `list_connections/2` returns first. Sync itself already behaves
this way, so the link is at least consistent with the connection the page
syncs against — which the "Connected: <name>" line names. Choosing a
connection is a separate feature, not this PR's scope.

## Validation

- `mix precommit` clean.
- `mix test` — full suite green.
- `:catalogue` suite for `shopify_sync_integration_link_test.exs` run through
  the path bridge (4 tests, 0 failures); `mix.lock` restored afterwards.
