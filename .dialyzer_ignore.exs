[
  # Gettext.Backend expands into code that constructs %Expo.PluralForms{}
  # literals inline; that struct is @opaque in Expo, so dialyzer flags the
  # generated call to Gettext.Plural.plural/2 as a call_without_opaque
  # mismatch. Known upstream false positive (gettext >= 0.26) — the plural
  # forms work correctly. (Surfaced once et/ru plural translations were added,
  # which is when the backend emits the plural code path. Mirrors the same
  # ignore in phoenix_kit_staff / phoenix_kit_billing / phoenix_kit_catalogue
  # / phoenix_kit_projects.)
  {"lib/phoenix_kit_ecommerce/gettext.ex", :call_without_opaque},
  # Scope.for_user/2 constructs cached_permissions as a MapSet; Dialyzer
  # infers its concrete internals and cannot reconcile them with the opaque
  # MapSet in Scope.can?/2's Scope.t() contract. Core suppresses the same
  # mismatch in its own Scope.for_user callers. Keep the live permission check.
  {"lib/phoenix_kit_ecommerce/api/gate.ex", :call_without_opaque},
  # `PhoenixKit.API.Tool` ships with the core that carries the shop API; a
  # released core older than that has no `Tool.new/1`, and the public tools are
  # simply not offered there. `@compile {:no_warn_undefined, ...}` silences the
  # compiler's xref but not dialyzer. Drop this line once the minimum core
  # requirement in mix.exs carries `PhoenixKit.API.Tool`. Each entry below names
  # the one missing function, so a new unknown call in the same file is still
  # reported.
  {"lib/phoenix_kit_ecommerce/api/public_tools.ex",
   "Function PhoenixKit.API.Tool.new/1 does not exist."},
  # The cart store names `PhoenixKit.API.RateLimit` too (same reason).
  {"lib/phoenix_kit_ecommerce/api/cart_store.ex",
   "Function PhoenixKit.API.RateLimit.check_cart_rows/1 does not exist."},
  # `PhoenixKitWebAnalytics.Config` is an optional dependency: the claim-path
  # exclusion step of the migration reads its default list when it is loaded.
  {"lib/phoenix_kit_ecommerce/migrations.ex",
   "Function PhoenixKitWebAnalytics.Config.default_exclusions/0 does not exist."},
  # The claim page marks itself with `PhoenixKitWebAnalytics.Plug.skip/1` when
  # that optional dependency is loaded.
  {"lib/phoenix_kit_ecommerce/web/claim_controller.ex",
   "Function PhoenixKitWebAnalytics.Plug.skip/1 does not exist."},
  # The admin API's e-commerce tools call core's tool registry and API config
  # (`PhoenixKit.API.Tool`, `PhoenixKit.API.Config`, used by settings.ex) and the
  # catalogue's admin API (`PhoenixKitCatalogue.API.resolve_refs/2`,
  # `Catalogue.update_items/2`), which no released core or catalogue ships yet.
  # Dialyzer reports a missing module as `unknown_function` and a missing
  # function of a loaded module (`Catalogue.update_items/2`) as `call_to_missing`.
  # Each entry names the one missing function, so a new unknown call in the same
  # file is still reported. Remove these entries when a released core and
  # catalogue ship the API; dialyzer then reports them as unnecessary skips.
  {"lib/phoenix_kit_ecommerce/api.ex", "Function PhoenixKit.API.Tool.new!/1 does not exist."},
  {"lib/phoenix_kit_ecommerce/api.ex",
   "Function PhoenixKit.API.Tool.__struct__/0 does not exist."},
  {"lib/phoenix_kit_ecommerce/api/refs.ex",
   "Function PhoenixKitCatalogue.API.resolve_refs/2 does not exist."},
  {"lib/phoenix_kit_ecommerce/api/catalogue_writes.ex",
   "Call to missing or private function PhoenixKitCatalogue.Catalogue.update_items/2."},
  {"lib/phoenix_kit_ecommerce/api/settings.ex",
   "Function PhoenixKit.API.Config.admin_enabled?/0 does not exist."},
  {"lib/phoenix_kit_ecommerce/api/catalogue_writes.ex",
   "Call to missing or private function PhoenixKitCatalogue.Catalogue.broadcast_item_batch_change/3."},
  {"lib/phoenix_kit_ecommerce/api/batch.ex",
   "Function PhoenixKit.API.FlowConfig.confirm_batch_over/0 does not exist."}
]
